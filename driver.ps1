# dsh-computer-use-fast — resident Windows input/screen driver.
#
# Protocol: one JSON request per line on stdin, one JSON response per line on stdout.
#   -> {"id":1,"action":"click","x":100,"y":200}
#   <- {"id":1,"ok":true,"result":{}}
#   <- {"id":1,"ok":false,"error":"Point (99999, 1) is outside the virtual desktop"}
#
# The P/Invoke surface is compiled once at startup, so after warm-up each request
# costs the action itself plus a line of JSON — not a process launch.
#
# This file performs input and screen capture only. It has no network code,
# registry access or clipboard access. OCR uses a temporary file. Optional
# saved captures are created exclusively by the Node host after approval.

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Drawing

if (-not ('DshCu.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DshCu
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public InputUnion U; }

        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
        }

        public const uint INPUT_KEYBOARD = 1;
        public const uint KEYEVENTF_KEYUP = 2;
        public const uint KEYEVENTF_UNICODE = 4;
        public const uint KEYEVENTF_EXTENDEDKEY = 1;

        public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const uint MOUSEEVENTF_LEFTUP = 0x0004;
        public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
        public const uint MOUSEEVENTF_WHEEL = 0x0800;

        public const int SM_XVIRTUALSCREEN = 76;
        public const int SM_YVIRTUALSCREEN = 77;
        public const int SM_CXVIRTUALSCREEN = 78;
        public const int SM_CYVIRTUALSCREEN = 79;
        public const int SM_CXSCREEN = 0;
        public const int SM_CYSCREEN = 1;

        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extra);
        [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        // Background (no cursor, no focus) primitives.
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        // Window placement: lets the agent put its target beside the user's
        // window instead of on top of it, so both can work at once.
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_SHOWWINDOW = 0x0040;
        public const int SW_SHOWNOACTIVATE = 4;

        /// <summary>Restore (without activating) and place a window, leaving z-order and focus alone.</summary>
        public static bool PlaceWindow(IntPtr hWnd, int x, int y, int width, int height)
        {
            if (IsIconic(hWnd)) ShowWindow(hWnd, SW_SHOWNOACTIVATE);
            return SetWindowPos(hWnd, IntPtr.Zero, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        // Taking the foreground: Windows only lets the thread that currently owns the
        // foreground hand it away, so we temporarily attach our input queue to that
        // thread. The ALT nudge covers the remaining cases where SetForegroundWindow
        // is still ignored (the classic foreground-lock workaround).
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

        public const int SW_RESTORE = 9;
        public const int SW_SHOW = 5;
        public const byte VK_MENU = 0x12;
        // KEYEVENTF_KEYUP is already declared earlier in this class; reuse that one.

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

        public delegate bool EnumProc(IntPtr h, IntPtr p);

        /// <summary>Type arbitrary Unicode text; newline and tab become real keys.</summary>
        public static void TypeUnicode(string text)
        {
            var inputs = new List<INPUT>();
            foreach (char c in text)
            {
                if (c == '\r') continue;
                if (c == '\n' || c == '\t')
                {
                    ushort vk = c == '\n' ? (ushort)0x0D : (ushort)0x09;
                    inputs.Add(Key(vk, 0, false));
                    inputs.Add(Key(vk, 0, true));
                    continue;
                }
                inputs.Add(Key(0, c, false));
                inputs.Add(Key(0, c, true));
            }
            Flush(inputs);
        }

        public static void KeyChord(ushort[] keys, bool[] extended)
        {
            var inputs = new List<INPUT>();
            for (int i = 0; i < keys.Length; i++) inputs.Add(Key(keys[i], 0, false, extended[i]));
            for (int i = keys.Length - 1; i >= 0; i--) inputs.Add(Key(keys[i], 0, true, extended[i]));
            Flush(inputs);
        }

        private static INPUT Key(ushort vk, ushort scan, bool up, bool extended = false)
        {
            uint flags = 0;
            if (up) flags |= KEYEVENTF_KEYUP;
            if (vk == 0) flags |= KEYEVENTF_UNICODE;
            if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
            return new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } } };
        }

        private static void Flush(List<INPUT> inputs)
        {
            if (inputs.Count > 0) SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
        }

        public static void MouseButton(uint down, uint up, int clicks, int delayMs)
        {
            for (int i = 0; i < clicks; i++)
            {
                mouse_event(down, 0, 0, 0, UIntPtr.Zero);
                if (delayMs > 0) System.Threading.Thread.Sleep(delayMs);
                mouse_event(up, 0, 0, 0, UIntPtr.Zero);
                if (delayMs > 0 && i + 1 < clicks) System.Threading.Thread.Sleep(delayMs);
            }
        }

        public static void Drag(int fromX, int fromY, int toX, int toY, int durationMs, uint down, uint up)
        {
            SetCursorPos(fromX, fromY);
            System.Threading.Thread.Sleep(20);
            mouse_event(down, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(20);
            int steps = durationMs <= 0 ? 1 : Math.Max(2, Math.Min(60, durationMs / 10));
            for (int i = 1; i <= steps; i++)
            {
                int x = fromX + (int)Math.Round((toX - fromX) * (double)i / steps);
                int y = fromY + (int)Math.Round((toY - fromY) * (double)i / steps);
                SetCursorPos(x, y);
                System.Threading.Thread.Sleep(Math.Max(1, durationMs / steps));
            }
            System.Threading.Thread.Sleep(20);
            mouse_event(up, 0, 0, 0, UIntPtr.Zero);
        }

        public static string[] ListWindows()
        {
            var list = new List<string>();
            IntPtr foreground = GetForegroundWindow();
            EnumWindows(delegate(IntPtr h, IntPtr p)
            {
                if (!IsWindowVisible(h)) return true;
                int len = GetWindowTextLengthW(h);
                if (len <= 0) return true;
                var sb = new StringBuilder(len + 2);
                GetWindowTextW(h, sb, sb.Capacity);
                RECT r;
                if (!GetWindowRect(h, out r)) return true;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                string title = sb.ToString().Replace('\u0001', ' ').Replace('\r', ' ').Replace('\n', ' ');
                list.Add(string.Join("\u0001", new string[] {
                    h.ToInt64().ToString(), pid.ToString(),
                    r.Left.ToString(), r.Top.ToString(),
                    (r.Right - r.Left).ToString(), (r.Bottom - r.Top).ToString(),
                    IsIconic(h) ? "1" : "0", (h == foreground) ? "1" : "0", title
                }));
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        public static string ForegroundTitle()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            int len = GetWindowTextLengthW(h);
            var sb = new StringBuilder(len + 2);
            GetWindowTextW(h, sb, sb.Capacity);
            return sb.ToString();
        }

        /// <summary>Milliseconds since the last keyboard or mouse input anywhere on this desktop.</summary>
        public static uint IdleMs()
        {
            var info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info)) return 0;
            return unchecked((uint)Environment.TickCount) - info.dwTime;
        }

        /// <summary>Foreground window identity as "handle|pid", or empty when there is none.</summary>
        public static string ForegroundIdentity()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return h.ToInt64().ToString() + "|" + pid.ToString();
        }

        /// <summary>Per-monitor-v2 first, then shcore, then the legacy system-DPI call.</summary>
        public static string EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "per-monitor-v2"; } catch { }
            try { if (SetProcessDpiAwareness(2) == 0) return "per-monitor"; } catch { }
            try { if (SetProcessDPIAware()) return "system"; } catch { }
            return "none";
        }
    }
}
'@
}

$script:DpiMode = [DshCu.Native]::EnableDpiAwareness()

# The window the agent claimed as its target. While a pin is held, every input
# action verifies that this window is still foreground, so a user who takes
# over the desktop causes a refusal instead of keystrokes landing in their
# window. $null means no pin: input goes to whatever is foreground.
$script:Pinned = $null
$script:PinnedPid = $null

function Get-IdleMs { [int][DshCu.Native]::IdleMs() }

function Get-PinState {
  if ($null -eq $script:Pinned) { return $null }
  $handle = [IntPtr]([int64]$script:Pinned)
  $title = ''
  if ([DshCu.Native]::IsWindow($handle)) {
    $len = [DshCu.Native]::GetWindowTextLengthW($handle)
    if ($len -gt 0) {
      $sb = New-Object System.Text.StringBuilder($len + 2)
      [void][DshCu.Native]::GetWindowTextW($handle, $sb, $sb.Capacity)
      $title = $sb.ToString()
    }
  }
  @{ handle = [int64]$script:Pinned; pid = $script:PinnedPid; title = $title; alive = [bool][DshCu.Native]::IsWindow($handle) }
}

function Assert-Target($minIdleMs) {
  if ($null -ne $minIdleMs -and [int]$minIdleMs -gt 0) {
    $idle = Get-IdleMs
    if ($idle -lt [int]$minIdleMs) {
      throw "the user is active: last input was $idle ms ago and $minIdleMs ms of quiet is required. Wait, or let the user finish before acting."
    }
  }
  if ($null -eq $script:Pinned) { return }
  $pinnedHandle = [int64]$script:Pinned
  $pinned = [IntPtr]$pinnedHandle
  if (-not [DshCu.Native]::IsWindow($pinned)) {
    $script:Pinned = $null
    $script:PinnedPid = $null
    throw "the pinned target window (handle $pinnedHandle) no longer exists; re-observe with computer_windows and pin a new target"
  }
  if ([DshCu.Native]::GetForegroundWindow() -ne $pinned) {
    throw "the pinned target window (handle $pinnedHandle) is not foreground, so the user has taken over. Refusing to send input into another window; re-focus the target with computer_focus, or release the pin with computer_release to act on whatever is foreground."
  }
}

function Get-VirtualScreen {
  $x = [DshCu.Native]::GetSystemMetrics([DshCu.Native]::SM_XVIRTUALSCREEN)
  $y = [DshCu.Native]::GetSystemMetrics([DshCu.Native]::SM_YVIRTUALSCREEN)
  $w = [DshCu.Native]::GetSystemMetrics([DshCu.Native]::SM_CXVIRTUALSCREEN)
  $h = [DshCu.Native]::GetSystemMetrics([DshCu.Native]::SM_CYVIRTUALSCREEN)
  @{ x = $x; y = $y; width = $w; height = $h }
}

function Assert-Point($x, $y) {
  foreach ($v in @($x, $y)) {
    if ($null -eq $v) { throw 'x and y are required integers' }
    if (($v -as [double]) -ne [math]::Truncate([double]$v)) { throw "Coordinate $v is not an integer" }
  }
  $s = Get-VirtualScreen
  if ($x -lt $s.x -or $x -ge ($s.x + $s.width) -or $y -lt $s.y -or $y -ge ($s.y + $s.height)) {
    throw "Point ($x, $y) is outside the virtual desktop ($($s.x), $($s.y), $($s.width)x$($s.height))"
  }
}

function Get-ButtonFlags([string]$button) {
  switch ($button) {
    'left'   { @([DshCu.Native]::MOUSEEVENTF_LEFTDOWN, [DshCu.Native]::MOUSEEVENTF_LEFTUP) }
    'right'  { @([DshCu.Native]::MOUSEEVENTF_RIGHTDOWN, [DshCu.Native]::MOUSEEVENTF_RIGHTUP) }
    'middle' { @([DshCu.Native]::MOUSEEVENTF_MIDDLEDOWN, [DshCu.Native]::MOUSEEVENTF_MIDDLEUP) }
    default  { throw "Unsupported mouse button: $button" }
  }
}

$script:KeyMap = @{
  'BACKSPACE' = 0x08; 'TAB' = 0x09; 'ENTER' = 0x0D; 'RETURN' = 0x0D; 'SHIFT' = 0x10; 'CTRL' = 0x11; 'CONTROL' = 0x11
  'ALT' = 0x12; 'PAUSE' = 0x13; 'CAPSLOCK' = 0x14; 'ESC' = 0x1B; 'ESCAPE' = 0x1B; 'SPACE' = 0x20
  'PAGEUP' = 0x21; 'PAGEDOWN' = 0x22; 'END' = 0x23; 'HOME' = 0x24; 'LEFT' = 0x25; 'UP' = 0x26; 'RIGHT' = 0x27; 'DOWN' = 0x28
  'PRINTSCREEN' = 0x2C; 'INSERT' = 0x2D; 'DELETE' = 0x2E; 'DEL' = 0x2E
  'NUMLOCK' = 0x90; 'SCROLLLOCK' = 0x91
  'SEMICOLON' = 0xBA; 'EQUALS' = 0xBB; 'COMMA' = 0xBC; 'MINUS' = 0xBD; 'PERIOD' = 0xBE; 'SLASH' = 0xBF
  'BACKTICK' = 0xC0; 'GRAVE' = 0xC0; 'LBRACKET' = 0xDB; 'BACKSLASH' = 0xDC; 'RBRACKET' = 0xDD; 'QUOTE' = 0xDE
}

$script:ExtendedKeys = @('LEFT', 'UP', 'RIGHT', 'DOWN', 'HOME', 'END', 'PAGEUP', 'PAGEDOWN', 'INSERT', 'DELETE', 'DEL', 'PRINTSCREEN', 'NUMLOCK', 'SCROLLLOCK')

function Get-KeyCode([string]$key) {
  $k = $key.Trim().ToUpperInvariant()
  if ($k -match '^F([1-9]|1[0-9]|2[0-4])$') { return @{ vk = (0x70 + ([int]$Matches[1] - 1)); extended = $false } }
  if ($k.Length -eq 1 -and $k -match '^[A-Z0-9]$') { return @{ vk = [int][char]$k; extended = $false } }
  if ($script:KeyMap.ContainsKey($k)) { return @{ vk = $script:KeyMap[$k]; extended = ($script:ExtendedKeys -contains $k) } }
  throw "Unsupported key: $key"
}

function Assert-SafeChord([string[]]$keys) {
  $norm = @($keys | ForEach-Object { $_.Trim().ToUpperInvariant() })
  foreach ($k in $norm) { if ($k -match '^(WIN|LWIN|RWIN|META|SUPER|CMD|WINDOWS)$') { throw "The Windows key cannot be sent ($k)" } }
  if (($norm -contains 'CTRL' -or $norm -contains 'CONTROL') -and $norm -contains 'ALT' -and ($norm -contains 'DELETE' -or $norm -contains 'DEL')) {
    throw 'CTRL+ALT+DELETE cannot be sent'
  }
  if ($norm -contains 'PRINTSCREEN') { throw 'PRINTSCREEN cannot be sent' }
}

function Invoke-Screenshot($req) {
  $s = Get-VirtualScreen
  $x = $s.x; $y = $s.y; $w = $s.width; $h = $s.height
  $target = if ($req.target) { [string]$req.target } else { 'screen' }
  $source = $null
  $offscreen = $false
  if ($null -ne $req.handle) {
    # PrintWindow renders a window into a bitmap without touching the cursor or
    # the foreground, so an occluded window can be observed while the user keeps
    # working on top of it.
    $hWnd = [IntPtr]([int64]$req.handle)
    if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $($req.handle) is not a live window" }
    $r = New-Object DshCu.RECT
    if (-not [DshCu.Native]::GetWindowRect($hWnd, [ref]$r)) { throw "could not read the bounds of window $($req.handle)" }
    $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "window $($req.handle) has empty bounds" }
    $source = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($source)
    $hdc = $g.GetHdc()
    try { $offscreen = [DshCu.Native]::PrintWindow($hWnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
    if (-not $offscreen) { $source.Dispose(); throw "PrintWindow refused window $($req.handle)" }
    if (Test-BlankBitmap $source) {
      $source.Dispose()
      throw "window $($req.handle) rendered blank through PrintWindow (some GPU-composited applications refuse offscreen rendering); bring it to the foreground and capture with target 'active', or use the UIA tools"
    }
  } elseif ($target -eq 'active' -or $target -eq 'window') {
    $hWnd = [DshCu.Native]::GetForegroundWindow()
    if ($hWnd -eq [IntPtr]::Zero) { throw 'There is no foreground window to capture' }
    $r = New-Object DshCu.RECT
    if (-not [DshCu.Native]::GetWindowRect($hWnd, [ref]$r)) { throw 'Could not read the foreground window bounds' }
    $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw 'The foreground window has empty bounds' }
  }
  if ($w -le 0 -or $h -le 0) { throw 'The requested capture region is empty' }

  if ($null -eq $source) {
    $source = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($source)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)), [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()
  }

  $maxW = if ($req.maxWidth) { [int]$req.maxWidth } else { 1920 }
  $maxH = if ($req.maxHeight) { [int]$req.maxHeight } else { 1200 }
  $scale = [Math]::Min(1.0, [Math]::Min($maxW / $w, $maxH / $h))
  $outW = [Math]::Max(1, [int][Math]::Floor($w * $scale))
  $outH = [Math]::Max(1, [int][Math]::Floor($h * $scale))

  $result = $source
  if ($outW -ne $w -or $outH -ne $h) {
    $scaled = New-Object System.Drawing.Bitmap($outW, $outH)
    $sg = [System.Drawing.Graphics]::FromImage($scaled)
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $sg.DrawImage($source, 0, 0, $outW, $outH)
    $sg.Dispose()
    $result = $scaled
  }

  $ms = New-Object System.IO.MemoryStream
  $format = if ($req.format) { ([string]$req.format).ToLowerInvariant() } else { 'png' }
  if ($format -eq 'jpeg' -or $format -eq 'jpg') {
    $quality = if ($req.quality) { [int]$req.quality } else { 80 }
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
    $result.Save($ms, $codec, $params)
    $mediaType = 'image/jpeg'
  } else {
    $result.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $mediaType = 'image/png'
  }
  $bytes = $ms.ToArray()
  $ms.Dispose()
  $result.Dispose()
  $source.Dispose()

  @{
    base64    = [Convert]::ToBase64String($bytes)
    mediaType = $mediaType
    width     = $outW
    height    = $outH
    originX   = $x
    originY   = $y
    scale     = [Math]::Round($scale, 6)
    bytes     = $bytes.Length
    offscreen = $offscreen
  }
}

function Test-BlankBitmap($bmp) {
  # Sample a grid of pixels; a PrintWindow result that is entirely one colour is
  # treated as a refused offscreen render rather than a real capture.
  $first = $null
  $stepX = [Math]::Max(1, [int]($bmp.Width / 16))
  $stepY = [Math]::Max(1, [int]($bmp.Height / 16))
  for ($px = 0; $px -lt $bmp.Width; $px += $stepX) {
    for ($py = 0; $py -lt $bmp.Height; $py += $stepY) {
      $c = $bmp.GetPixel($px, $py).ToArgb()
      if ($null -eq $first) { $first = $c } elseif ($c -ne $first) { return $false }
    }
  }
  return $true
}

function Invoke-Windows($req) {
  $rows = [DshCu.Native]::ListWindows()
  $limit = if ($req.limit) { [int]$req.limit } else { 60 }
  if ($limit -lt 1) { $limit = 1 }
  if ($limit -gt 200) { $limit = 200 }
  $filter = if ($req.filter) { ([string]$req.filter).ToLowerInvariant() } else { $null }
  $out = New-Object System.Collections.ArrayList
  foreach ($row in $rows) {
    $parts = $row.Split([char]1)
    $title = $parts[8]
    if ($filter -and -not $title.ToLowerInvariant().Contains($filter)) { continue }
    [void]$out.Add(@{
      handle     = [int64]$parts[0]
      pid        = [int]$parts[1]
      x          = [int]$parts[2]
      y          = [int]$parts[3]
      width      = [int]$parts[4]
      height     = [int]$parts[5]
      minimized  = ($parts[6] -eq '1')
      foreground = ($parts[7] -eq '1')
      title      = $title
    })
  }
  @{ count = $out.Count; windows = @($out | Sort-Object -Property @{ Expression = { $_.width * $_.height } } -Descending | Select-Object -First $limit) }
}

#region Tier 2 — background control (no cursor movement, no focus stealing)

# Background actions deliberately skip the idle gate: not disturbing the user is
# the whole point. They do honour the pin, so a claimed target still bounds them.
function Assert-BackgroundTarget($handle) {
  if ($null -eq $handle) { throw 'handle is required' }
  $hWnd = [IntPtr]([int64]$handle)
  if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $handle is not a live window" }
  if ($null -ne $script:Pinned -and [int64]$handle -ne [int64]$script:Pinned) {
    throw "this action targets window $handle, but input is pinned to window $($script:Pinned). Pin that window instead (computer_pin) or release the pin (computer_release)."
  }
  return $hWnd
}

$script:UiaLoaded = $false
function Initialize-Uia {
  if ($script:UiaLoaded) { return }
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName WindowsBase
  $script:UiaLoaded = $true
}

function Limit-Text($value, $max) {
  if ($null -eq $value) { return '' }
  $s = ([string]$value) -replace '\s+', ' '
  if ($s.Length -gt $max) { return $s.Substring(0, $max) }
  return $s
}

function Get-UiaRoot($hWnd) {
  Initialize-Uia
  $element = [System.Windows.Automation.AutomationElement]::FromHandle($hWnd)
  if ($null -eq $element) { throw "UI Automation cannot see window $($hWnd)" }
  return $element
}

function Get-UiaPatternObject($element, $pattern) {
  try { return $element.GetCurrentPattern($pattern) } catch { return $null }
}

function Get-UiaPatternNames($element) {
  $names = New-Object System.Collections.ArrayList
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.InvokePattern]::Pattern))) { [void]$names.Add('invoke') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.ValuePattern]::Pattern))) { [void]$names.Add('set_value') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.SelectionItemPattern]::Pattern))) { [void]$names.Add('select') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.TogglePattern]::Pattern))) { [void]$names.Add('toggle') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern))) { [void]$names.Add('expand_collapse') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.ScrollItemPattern]::Pattern))) { [void]$names.Add('scroll_into_view') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.ScrollPattern]::Pattern))) { [void]$names.Add('scroll') }
  if ($null -ne (Get-UiaPatternObject $element ([System.Windows.Automation.RangeValuePattern]::Pattern))) { [void]$names.Add('set_range') }
  return @($names)
}

function Get-UiaBounds($rect) {
  # AutomationElement.BoundingRectangle is Rect.Empty (infinite coordinates) for
  # elements with no geometry, which would explode an [int] cast.
  $empty = @{ x = 0; y = 0; width = 0; height = 0; hasBounds = $false }
  if ($null -eq $rect) { return $empty }
  if ($rect.IsEmpty) { return $empty }
  foreach ($value in @($rect.X, $rect.Y, $rect.Width, $rect.Height)) {
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $empty }
  }
  @{
    x         = [int][Math]::Round($rect.X)
    y         = [int][Math]::Round($rect.Y)
    width     = [int][Math]::Max(0, [Math]::Round($rect.Width))
    height    = [int][Math]::Max(0, [Math]::Round($rect.Height))
    hasBounds = $true
  }
}

function ConvertTo-UiaRow($element, $index, $depth, [switch]$Fast) {
  $row = @{
    index = $index; depth = $depth; name = ''; type = 'Unknown'; automationId = ''; className = ''
    x = 0; y = 0; width = 0; height = 0; enabled = $false; offscreen = $false; password = $false
    value = $null; patterns = @(); error = $null
  }
  try {
    $current = $element.Current
    $bounds = Get-UiaBounds $current.BoundingRectangle
    # Pattern probing is cross-process and not cheap, so it is limited to
    # addressable elements (a name or automation id); nameless layout containers
    # report no patterns rather than costing several COM round trips each.
    # $Fast skips probing entirely for bulk passes such as scroll paging.
    $addressable = ($current.Name -ne '' -or $current.AutomationId -ne '')
    $patterns = if ($addressable -and -not $Fast) { Get-UiaPatternNames $element } else { @() }
    $value = $null
    if ($addressable -and -not $Fast -and ($patterns -contains 'set_value') -and -not $current.IsPassword) {
      $valuePattern = Get-UiaPatternObject $element ([System.Windows.Automation.ValuePattern]::Pattern)
      if ($null -ne $valuePattern) { $value = Limit-Text $valuePattern.Current.Value 120 }
    }
    $row.name = Limit-Text $current.Name 120
    $row.type = ($current.ControlType.ProgrammaticName -replace '^ControlType\.', '')
    $row.automationId = Limit-Text $current.AutomationId 60
    $row.className = Limit-Text $current.ClassName 60
    $row.x = $bounds.x
    $row.y = $bounds.y
    $row.width = $bounds.width
    $row.height = $bounds.height
    $row.enabled = [bool]$current.IsEnabled
    $row.offscreen = [bool]$current.IsOffscreen
    $row.password = [bool]$current.IsPassword
    $row.value = $value
    $row.patterns = @($patterns)
  } catch {
    # One unreadable element must not abort the whole walk.
    $row.error = $_.Exception.Message
  }
  $row
}

function Invoke-Ocr($req) {
  # Offscreen-capture a window (PrintWindow) then read its text with the Windows
  # built-in OCR engine (Windows.Media.Ocr). No cursor movement and no focus
  # change, so it is safe to run while the user is working on the machine.
  if ($null -eq $req.handle) { throw 'handle is required' }

  Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
  $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  if ($null -eq $asTaskGeneric) { throw 'WindowsRuntime AsTask bridge unavailable' }

  $storageFileT = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
  $bitmapT      = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
  $ocrT         = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]

  function Await-OcrOp($op, $type) {
    $asTask = $asTaskGeneric.MakeGenericMethod($type)
    $task = $asTask.Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    return $task.Result
  }

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-ocr-" + [Guid]::NewGuid().ToString('N') + ".png")
  try {
    $capture = Invoke-Screenshot @{ handle = $req.handle; format = 'png'; maxWidth = 4000; maxHeight = 4000 }
    $b64 = $capture.base64
    if ($null -eq $b64) { throw 'offscreen capture returned no image' }
    [System.IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($b64))

    $file    = Await-OcrOp ($storageFileT::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream  = Await-OcrOp ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-OcrOp ($bitmapT::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap  = Await-OcrOp ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = $ocrT::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) { throw 'no OCR engine for the user profile languages' }
    $result = Await-OcrOp ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

    $lines = @()
    foreach ($line in $result.Lines) { $lines += $line.Text }
    @{ handle = [int64]$req.handle; lineCount = $lines.Count; text = ($lines -join "`n") }
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
}
function Invoke-UiaList($req) {
  $hWnd = Assert-BackgroundTarget $req.handle
  $root = Get-UiaRoot $hWnd
  $maxDepth = if ($req.maxDepth) { [int]$req.maxDepth } else { 6 }
  if ($maxDepth -lt 1) { $maxDepth = 1 }
  if ($maxDepth -gt 20) { $maxDepth = 20 }
  $maxNodes = if ($req.maxNodes) { [int]$req.maxNodes } else { 300 }
  if ($maxNodes -lt 1) { $maxNodes = 1 }
  if ($maxNodes -gt 1000) { $maxNodes = 1000 }

  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $rows = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push(@{ element = $root; depth = 0 })
  $index = 0
  while ($stack.Count -gt 0 -and $rows.Count -lt $maxNodes) {
    $node = $stack.Pop()
    [void]$rows.Add((ConvertTo-UiaRow $node.element $index $node.depth))
    $index++
    if ($node.depth -ge $maxDepth) { continue }
    $children = New-Object System.Collections.ArrayList
    $child = $walker.GetFirstChild($node.element)
    while ($null -ne $child) {
      [void]$children.Add($child)
      $child = $walker.GetNextSibling($child)
    }
    for ($i = $children.Count - 1; $i -ge 0; $i--) {
      $stack.Push(@{ element = $children[$i]; depth = $node.depth + 1 })
    }
  }
  @{ handle = [int64]$req.handle; count = $rows.Count; truncated = ($stack.Count -gt 0); elements = @($rows) }
}

function Invoke-UiaAct($req) {
  $hWnd = Assert-BackgroundTarget $req.handle
  $root = Get-UiaRoot $hWnd
  # Named uiaAction, not action: `action` already carries the driver opcode.
  $action = [string]$req.uiaAction
  if ($action.Length -eq 0) { throw 'uiaAction is required' }

  $element = $null
  if ($null -ne $req.x -and $null -ne $req.y) {
    Assert-Point $req.x $req.y
    Initialize-Uia
    $point = New-Object System.Windows.Point([double]$req.x, [double]$req.y)
    $element = [System.Windows.Automation.AutomationElement]::FromPoint($point)
  } elseif ($null -ne $req.name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, [string]$req.name)
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
  } else {
    throw 'provide x and y (screen coordinates), or a name to match inside the window'
  }
  if ($null -eq $element) { throw 'no UI Automation element matched the request' }

  # Find the owning top-level window: stop at the first ancestor that exposes a
  # native handle. Walking to the UIA root lands on the desktop pane, which owns
  # every window and would refuse every legitimate element.
  $top = $element
  while ($true) {
    if ($top.Current.NativeWindowHandle -ne 0) { break }
    $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($top)
    if ($null -eq $parent) { break }
    $top = $parent
  }
  $topHandle = $top.Current.NativeWindowHandle
  if ($topHandle -eq 0) { throw 'the element does not belong to a top-level window' }
  if ([int64]$topHandle -ne [int64]$req.handle) {
    # Menus, popups and dialogs are separate top-level windows owned by the same
    # process. Those are part of the window the caller asked for; anything from
    # another application is still refused.
    $requestedPid = [uint32]0
    $topPid = [uint32]0
    [void][DshCu.Native]::GetWindowThreadProcessId([IntPtr]([int64]$req.handle), [ref]$requestedPid)
    [void][DshCu.Native]::GetWindowThreadProcessId([IntPtr]([int64]$topHandle), [ref]$topPid)
    if ([int]$requestedPid -eq 0 -or [int]$topPid -ne [int]$requestedPid) {
      throw "the element belongs to window $topHandle (pid $topPid), not the requested window $($req.handle) (pid $requestedPid)"
    }
  }

  $current = $element.Current
  $label = "$(Limit-Text $current.Name 60) [$(($current.ControlType.ProgrammaticName -replace '^ControlType\.', ''))]"
  switch ($action) {
    'invoke' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.InvokePattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the invoke pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.Invoke()
      @{ action = 'invoke'; usedPattern = 'invoke'; element = $label }
    }
    'set_value' {
      if ($current.IsPassword) { throw "$label is a password field; refusing to write into it" }
      if ($null -eq $req.value) { throw 'value is required for set_value' }
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.ValuePattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the value pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      if ($pattern.Current.IsReadOnly) { throw "$label is read-only" }
      $pattern.SetValue([string]$req.value)
      @{ action = 'set_value'; usedPattern = 'set_value'; element = $label; characters = ([string]$req.value).Length }
    }
    'select' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.SelectionItemPattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the selection item pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.Select()
      @{ action = 'select'; usedPattern = 'select'; element = $label }
    }
    'toggle' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.TogglePattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the toggle pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.Toggle()
      @{ action = 'toggle'; usedPattern = 'toggle'; element = $label }
    }
    'expand' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the expand/collapse pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.Expand()
      @{ action = 'expand'; usedPattern = 'expand_collapse'; element = $label }
    }
    'collapse' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the expand/collapse pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.Collapse()
      @{ action = 'collapse'; usedPattern = 'expand_collapse'; element = $label }
    }
    'scroll_into_view' {
      $pattern = Get-UiaPatternObject $element ([System.Windows.Automation.ScrollItemPattern]::Pattern)
      if ($null -eq $pattern) { throw "$label does not support the scroll item pattern (available: $((Get-UiaPatternNames $element) -join ', '))" }
      $pattern.ScrollIntoView()
      @{ action = 'scroll_into_view'; usedPattern = 'scroll_into_view'; element = $label }
    }
    'focus' {
      $element.SetFocus()
      @{ action = 'focus'; usedPattern = 'none'; element = $label }
    }
    'scroll_down' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Vertical' 'LargeIncrement'; @{ action = 'scroll_down'; usedPattern = 'scroll'; element = $label } }
    'scroll_up' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Vertical' 'SmallDecrement'; @{ action = 'scroll_up'; usedPattern = 'scroll'; element = $label } }
    'scroll_page_down' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Vertical' 'LargeIncrement'; @{ action = 'scroll_page_down'; usedPattern = 'scroll'; element = $label } }
    'scroll_page_up' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Vertical' 'LargeDecrement'; @{ action = 'scroll_page_up'; usedPattern = 'scroll'; element = $label } }
    'scroll_right' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Horizontal' 'LargeIncrement'; @{ action = 'scroll_right'; usedPattern = 'scroll'; element = $label } }
    'scroll_left' { Assert-UiaScroll $element $label; Invoke-UiaScrollStep $element 'Horizontal' 'LargeDecrement'; @{ action = 'scroll_left'; usedPattern = 'scroll'; element = $label } }
    default { throw "Unsupported UIA action: $action (use invoke, set_value, select, toggle, expand, collapse, scroll_into_view, focus, scroll_up, scroll_down, scroll_page_up, scroll_page_down, scroll_left or scroll_right)" }
  }
}

function Invoke-BgClick($req) {
  $hWnd = Assert-BackgroundTarget $req.handle
  $client = New-Object DshCu.RECT
  if (-not [DshCu.Native]::GetClientRect($hWnd, [ref]$client)) { throw "could not read the client area of window $($req.handle)" }
  if ($null -eq $req.x -or $null -eq $req.y) { throw 'x and y are required' }
  $cx = [int]$req.x
  $cy = [int]$req.y
  if ($req.client -ne $true) {
    Assert-Point $cx $cy
    $point = New-Object DshCu.POINT
    $point.X = $cx
    $point.Y = $cy
    if (-not [DshCu.Native]::ScreenToClient($hWnd, [ref]$point)) { throw 'could not convert the screen point into client coordinates' }
    $cx = $point.X
    $cy = $point.Y
  }
  $width = $client.Right - $client.Left
  $height = $client.Bottom - $client.Top
  if ($cx -lt $client.Left -or $cx -ge $client.Right -or $cy -lt $client.Top -or $cy -ge $client.Bottom) {
    throw "point ($cx, $cy) is outside the client area of window $($req.handle) (${width}x${height})"
  }
  $button = if ($req.button) { [string]$req.button } else { 'left' }
  $map = @{ left = @(0x0201, 0x0202, 1); right = @(0x0204, 0x0205, 2); middle = @(0x0207, 0x0208, 16) }
  if (-not $map.ContainsKey($button)) { throw "Unsupported mouse button: $button" }
  $flags = $map[$button]
  $lParam = [IntPtr][int]((($cy -shl 16) -bor ($cx -band 0xFFFF)))
  [void][DshCu.Native]::PostMessageW($hWnd, 0x0200, [IntPtr]::Zero, $lParam)
  Start-Sleep -Milliseconds 10
  [void][DshCu.Native]::PostMessageW($hWnd, $flags[0], [IntPtr]$flags[2], $lParam)
  Start-Sleep -Milliseconds 20
  [void][DshCu.Native]::PostMessageW($hWnd, $flags[1], [IntPtr]::Zero, $lParam)
  @{ button = $button; clientX = $cx; clientY = $cy; delivered = 'posted' }
}

function Invoke-BgKey($req) {
  $hWnd = Assert-BackgroundTarget $req.handle
  if ($null -ne $req.text) {
    $text = [string]$req.text
    if ($text.Length -eq 0) { throw 'text must not be empty' }
    if ($text.Length -gt 20000) { throw 'text exceeds the 20000 character limit' }
    foreach ($character in $text.ToCharArray()) {
      $code = [int][char]$character
      if ($code -eq 13) { continue }
      if ($code -eq 10 -or $code -eq 9) {
        $vk = if ($code -eq 10) { 0x0D } else { 0x09 }
        [void][DshCu.Native]::PostMessageW($hWnd, 0x0100, [IntPtr]$vk, [IntPtr]0)
        [void][DshCu.Native]::PostMessageW($hWnd, 0x0101, [IntPtr]$vk, [IntPtr]0)
        continue
      }
      [void][DshCu.Native]::PostMessageW($hWnd, 0x0102, [IntPtr]$code, [IntPtr]0)
    }
    return @{ mode = 'text'; characters = $text.Length; delivered = 'posted' }
  }
  $keys = @($req.keys)
  if ($keys.Count -lt 1 -or $keys.Count -gt 4) { throw 'keys must contain 1 to 4 entries' }
  Assert-SafeChord $keys
  $codes = @($keys | ForEach-Object { Get-KeyCode ([string]$_) })
  foreach ($code in $codes) { [void][DshCu.Native]::PostMessageW($hWnd, 0x0100, [IntPtr][int]$code.vk, [IntPtr]0) }
  for ($i = $codes.Count - 1; $i -ge 0; $i--) { [void][DshCu.Native]::PostMessageW($hWnd, 0x0101, [IntPtr][int]$codes[$i].vk, [IntPtr]0) }
  @{ mode = 'chord'; keys = @($keys | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }); delivered = 'posted' }
}

#endregion

function Get-ScrollPattern($element) {
  # The element under a point is often a child; the scrollable thing is an ancestor.
  $node = $element
  for ($i = 0; $i -lt 8 -and $null -ne $node; $i++) {
    $sp = Get-UiaPatternObject $node ([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($null -ne $sp) { return $sp }
    $node = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
  }
  return $null
}

function Assert-UiaScroll($element, $label) {
  if ($null -eq (Get-ScrollPattern $element)) { throw "$label has no scrollable ancestor, so there is nothing to scroll" }
}

function Invoke-UiaScrollStep($element, $direction, $amountName) {
  $sp = Get-ScrollPattern $element
  $amount = [System.Windows.Automation.ScrollAmount]::$amountName
  $none = [System.Windows.Automation.ScrollAmount]::NoAmount
  if ($direction -eq 'Vertical') { $sp.Scroll($amount, $none) } else { $sp.Scroll($none, $amount) }
}

function Get-UiaSnapshot($root, $maxNodes, [switch]$Fast) {
  # Full unfiltered inventory of a subtree, keyed so a scrolled re-read can be merged.
  $rows = New-Object System.Collections.ArrayList
  $scrollables = New-Object System.Collections.ArrayList
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $stack = New-Object System.Collections.Stack
  $stack.Push(@{ element = $root; depth = 0 })
  while ($stack.Count -gt 0 -and $rows.Count -lt $maxNodes) {
    $node = $stack.Pop()
    $element = $node.element
    [void]$rows.Add((ConvertTo-UiaRow $element $rows.Count $node.depth -Fast:$Fast))
    if (-not $Fast) {
      $sp = Get-UiaPatternObject $element ([System.Windows.Automation.ScrollPattern]::Pattern)
      if ($null -ne $sp) {
        try {
          if ($sp.Current.VerticallyScrollable -or $sp.Current.HorizontallyScrollable) {
            $rect = $element.Current.BoundingRectangle
            $area = 0
            if (-not $rect.IsEmpty) { $area = [int]($rect.Width * $rect.Height) }
            [void]$scrollables.Add(@{ element = $element; pattern = $sp; area = $area })
          }
        } catch { }
      }
    }
    $children = New-Object System.Collections.ArrayList
    $child = $walker.GetFirstChild($element)
    while ($null -ne $child) {
      [void]$children.Add($child)
      $child = $walker.GetNextSibling($child)
    }
    for ($i = $children.Count - 1; $i -ge 0; $i--) {
      $stack.Push(@{ element = $children[$i]; depth = $node.depth + 1 })
    }
  }
  @{ rows = @($rows); scrollables = @($scrollables) }
}

function Get-RowKey($row) {
  "$($row.type)|$($row.automationId)|$($row.name)|$($row.x),$($row.y)"
}

function Invoke-UiaScan($req) {
  # Reads EVERYTHING in a window: the whole tree, then pages through each
  # scrollable container and merges what scrolling reveals, so settings that
  # live below the fold are not missed.
  $hWnd = Assert-BackgroundTarget $req.handle
  $root = Get-UiaRoot $hWnd
  $maxNodes = if ($req.maxNodes) { [int]$req.maxNodes } else { 1500 }
  if ($maxNodes -lt 50) { $maxNodes = 50 }
  if ($maxNodes -gt 5000) { $maxNodes = 5000 }
  $maxPages = if ($null -ne $req.maxPages) { [int]$req.maxPages } else { 20 }
  if ($maxPages -lt 0) { $maxPages = 0 }
  if ($maxPages -gt 100) { $maxPages = 100 }

  $first = Get-UiaSnapshot $root $maxNodes
  $merged = [ordered]@{}
  foreach ($row in $first.rows) { $merged[(Get-RowKey $row)] = $row }

  # Page the LARGEST scrollable containers first, on a shared page budget, and
  # read each page cheaply (no pattern probing) — probing every page is what
  # made an unbounded scan take minutes.
  $ordered = @($first.scrollables | Sort-Object -Property @{ Expression = { $_.area } } -Descending)
  $containerLimit = [Math]::Min($ordered.Count, 6)
  $pageBudget = $maxPages
  $pagesScrolled = 0
  for ($c = 0; $c -lt $containerLimit -and $pageBudget -gt 0; $c++) {
    $entry = $ordered[$c]
    $sp = $entry.pattern
    try {
      $vertical = $sp.Current.VerticallyScrollable
      if ($vertical) { $sp.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 0) }
      for ($page = 0; $page -lt 4 -and $pageBudget -gt 0; $page++) {
        $before = $merged.Count
        Start-Sleep -Milliseconds 200
        foreach ($row in (Get-UiaSnapshot $entry.element $maxNodes -Fast).rows) { $merged[(Get-RowKey $row)] = $row }
        if ($merged.Count -eq $before) { break }
        if (-not $vertical) { break }
        try { $sp.Scroll([System.Windows.Automation.ScrollAmount]::LargeIncrement, [System.Windows.Automation.ScrollAmount]::NoScroll) } catch { break }
        $pagesScrolled++
        $pageBudget--
      }
      if ($vertical) { $sp.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 0) }
    } catch { }
  }

  $rows = @($merged.Values)
  @{
    handle          = [int64]$req.handle
    count           = $rows.Count
    scrollContainers = $ordered.Count
    pagesScrolled   = $pagesScrolled
    complete        = ($rows.Count -lt $maxNodes)
    elements        = $rows
  }
}

function Invoke-Arrange($req) {
  # Places windows by absolute desktop rectangle without activating them, so the
  # caller can reserve screen space for the human instead of covering it.
  $results = New-Object System.Collections.ArrayList
  foreach ($item in @($req.windows)) {
    $handle = [int64]$item.handle
    $hWnd = [IntPtr]$handle
    if (-not [DshCu.Native]::IsWindow($hWnd)) {
      [void]$results.Add(@{ handle = $handle; ok = $false; error = 'not a live window' })
      continue
    }
    $x = [int]$item.x
    $y = [int]$item.y
    $w = [int]$item.width
    $h = [int]$item.height
    if ($w -lt 64 -or $h -lt 64) {
      [void]$results.Add(@{ handle = $handle; ok = $false; error = 'width and height must be at least 64' })
      continue
    }
    $ok = [DshCu.Native]::PlaceWindow($hWnd, $x, $y, $w, $h)
    $rect = New-Object DshCu.RECT
    [void][DshCu.Native]::GetWindowRect($hWnd, [ref]$rect)
    [void]$results.Add(@{
      handle = $handle
      ok     = [bool]$ok
      x      = $rect.Left
      y      = $rect.Top
      width  = $rect.Right - $rect.Left
      height = $rect.Bottom - $rect.Top
    })
  }
  @{ count = $results.Count; windows = @($results) }
}

function Invoke-FocusForce($req) {
  # SetForegroundWindow is silently ignored unless the calling thread already owns the
  # foreground. Borrow that right by attaching to the foreground thread, raise the
  # window, then nudge ALT (which clears the foreground lock) and verify the result.
  if ($null -eq $req.handle) { throw 'handle is required' }
  $hWnd = [IntPtr]([int64]$req.handle)
  if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $($req.handle) is not a live window" }
  if (-not [DshCu.Native]::IsWindowVisible($hWnd)) { throw "window $($req.handle) is not visible, so it cannot take the foreground" }

  $maxAttempts = if ($req.attempts) { [int]$req.attempts } else { 3 }
  if ($maxAttempts -lt 1) { $maxAttempts = 1 }
  if ($maxAttempts -gt 10) { $maxAttempts = 10 }

  $used = 0
  for ($used = 1; $used -le $maxAttempts; $used++) {
    if ([DshCu.Native]::GetForegroundWindow() -eq $hWnd) { break }
    if ([DshCu.Native]::IsIconic($hWnd)) { [void][DshCu.Native]::ShowWindow($hWnd, [DshCu.Native]::SW_RESTORE) }
    [void][DshCu.Native]::ShowWindow($hWnd, [DshCu.Native]::SW_SHOW)

    $fg = [DshCu.Native]::GetForegroundWindow()
    $fgPid = [uint32]0
    $targetPid = [uint32]0
    $ourThread = [DshCu.Native]::GetCurrentThreadId()
    $fgThread = if ($fg -ne [IntPtr]::Zero) { [DshCu.Native]::GetWindowThreadProcessId($fg, [ref]$fgPid) } else { 0 }
    $targetThread = [DshCu.Native]::GetWindowThreadProcessId($hWnd, [ref]$targetPid)

    $attachedFg = $false
    $attachedTarget = $false
    try {
      if ($fgThread -ne 0 -and $fgThread -ne $ourThread) {
        $attachedFg = [DshCu.Native]::AttachThreadInput($ourThread, $fgThread, $true)
      }
      if ($targetThread -ne 0 -and $targetThread -ne $ourThread -and $targetThread -ne $fgThread) {
        $attachedTarget = [DshCu.Native]::AttachThreadInput($ourThread, $targetThread, $true)
      }
      [void][DshCu.Native]::BringWindowToTop($hWnd)
      [void][DshCu.Native]::SetForegroundWindow($hWnd)
      [void][DshCu.Native]::SetActiveWindow($hWnd)
    } finally {
      if ($attachedTarget) { [void][DshCu.Native]::AttachThreadInput($ourThread, $targetThread, $false) }
      if ($attachedFg) { [void][DshCu.Native]::AttachThreadInput($ourThread, $fgThread, $false) }
    }

    if ([DshCu.Native]::GetForegroundWindow() -eq $hWnd) { break }

    # ALT press/release releases the foreground lock for the next SetForegroundWindow.
    [DshCu.Native]::keybd_event([DshCu.Native]::VK_MENU, 0, 0, [UIntPtr]::Zero)
    [void][DshCu.Native]::SetForegroundWindow($hWnd)
    [DshCu.Native]::keybd_event([DshCu.Native]::VK_MENU, 0, [DshCu.Native]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)

    if ([DshCu.Native]::GetForegroundWindow() -eq $hWnd) { break }
    Start-Sleep -Milliseconds 120
  }

  $focused = ([DshCu.Native]::GetForegroundWindow() -eq $hWnd)
  if ($req.pin -eq $true -and $focused) {
    $procId = [uint32]0
    [void][DshCu.Native]::GetWindowThreadProcessId($hWnd, [ref]$procId)
    $script:Pinned = [int64]$req.handle
    $script:PinnedPid = [int]$procId
  }
  @{
    focused    = $focused
    attempts   = $used
    foreground = [DshCu.Native]::ForegroundTitle()
    pinned     = Get-PinState
  }
}

function Invoke-RenderCheck($req) {
  # Tell "this window is painting a blank surface" apart from "PrintWindow refused",
  # which computer_screenshot currently reports as the same error. Returns pixel
  # statistics and a verdict so a caller can decide without eyeballing an image.
  if ($null -eq $req.handle) { throw 'handle is required' }
  $hWnd = [IntPtr]([int64]$req.handle)
  if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $($req.handle) is not a live window" }
  $r = New-Object DshCu.RECT
  if (-not [DshCu.Native]::GetWindowRect($hWnd, [ref]$r)) { throw "could not read the bounds of window $($req.handle)" }
  $w = [int]($r.Right - $r.Left)
  $h = [int]($r.Bottom - $r.Top)
  if ($w -le 0 -or $h -le 0) { throw "window $($req.handle) has no drawable area (${w}x${h})" }
  $capW = [Math]::Min($w, 1200)
  $capH = [Math]::Min($h, 900)

  $bmp = New-Object System.Drawing.Bitmap($capW, $capH)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $method = 'PrintWindow(PW_RENDERFULLCONTENT)'
  try { $ok = [DshCu.Native]::PrintWindow($hWnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
  if (-not $ok) {
    # Some GPU-composited windows refuse the full-content flag but honour plain flags.
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc2 = $g2.GetHdc()
    try { $ok = [DshCu.Native]::PrintWindow($hWnd, $hdc2, 0) } finally { $g2.ReleaseHdc($hdc2); $g2.Dispose() }
    $method = 'PrintWindow(flags=0)'
  }

  $colors = New-Object 'System.Collections.Generic.HashSet[int]'
  $white = 0; $black = 0; $total = 0; $sum = 0.0; $sumSq = 0.0
  $stepX = [Math]::Max(1, [int]($capW / 40))
  $stepY = [Math]::Max(1, [int]($capH / 40))
  for ($px = 0; $px -lt $capW; $px += $stepX) {
    for ($py = 0; $py -lt $capH; $py += $stepY) {
      $c = $bmp.GetPixel($px, $py)
      $total++
      $lum = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
      $sum += $lum
      $sumSq += $lum * $lum
      [void]$colors.Add((($c.R -shr 3) -shl 10) -bor (($c.G -shr 3) -shl 5) -bor ($c.B -shr 3))
      if ($c.R -ge 245 -and $c.G -ge 245 -and $c.B -ge 245) { $white++ }
      if ($c.R -le 10 -and $c.G -le 10 -and $c.B -le 10) { $black++ }
    }
  }
  $mean = if ($total -gt 0) { $sum / $total } else { 0 }
  $variance = if ($total -gt 0) { [Math]::Max(0, ($sumSq / $total) - ($mean * $mean)) } else { 0 }
  $std = [Math]::Sqrt($variance)
  $whiteFrac = if ($total -gt 0) { $white / $total } else { 0 }
  $blackFrac = if ($total -gt 0) { $black / $total } else { 0 }

  $verdict = 'rendered'
  if (-not $ok) { $verdict = 'capture-refused' }
  elseif ($colors.Count -le 2) { $verdict = 'blank-uniform' }
  elseif ($whiteFrac -ge 0.97) { $verdict = 'blank-white' }
  elseif ($blackFrac -ge 0.97) { $verdict = 'blank-black' }
  elseif ($std -lt 2.5) { $verdict = 'blank-near-uniform' }

  $pngBase64 = $null
  if ($req.includeImage -eq $true) {
    $stream = New-Object System.IO.MemoryStream
    try {
      $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
      $pngBase64 = [Convert]::ToBase64String($stream.ToArray())
    } finally {
      $stream.Dispose()
    }
  }
  $bmp.Dispose()

  @{
    handle        = [int64]$req.handle
    focus         = ([DshCu.Native]::GetForegroundWindow() -eq $hWnd)
    width         = $capW
    height        = $capH
    captured      = [bool]$ok
    method        = $method
    verdict       = $verdict
    uniqueColors  = $colors.Count
    meanLuma      = [Math]::Round($mean, 2)
    stdLuma       = [Math]::Round($std, 2)
    whiteFraction = [Math]::Round($whiteFrac, 4)
    blackFraction = [Math]::Round($blackFrac, 4)
    pngBase64     = $pngBase64
  }
}

function Invoke-Action($req) {
  $action = [string]$req.action
  switch ($action) {
    'hello' {
      $s = Get-VirtualScreen
      @{ driver = 'dsh-computer-use-fast'; version = 2; dpi = $script:DpiMode; screen = $s; pid = $PID; idleMs = Get-IdleMs; pinned = Get-PinState }
    }
    'screen' {
      $s = Get-VirtualScreen
      $p = New-Object DshCu.POINT
      [void][DshCu.Native]::GetCursorPos([ref]$p)
      @{ screen = $s; cursor = @{ x = $p.X; y = $p.Y }; foreground = [DshCu.Native]::ForegroundTitle(); idleMs = Get-IdleMs; pinned = Get-PinState }
    }
    'idle' {
      $s = Get-VirtualScreen
      $p = New-Object DshCu.POINT
      [void][DshCu.Native]::GetCursorPos([ref]$p)
      @{
        idleMs     = Get-IdleMs
        cursor     = @{ x = $p.X; y = $p.Y }
        foreground = [DshCu.Native]::ForegroundTitle()
        screen     = $s
        pinned     = Get-PinState
      }
    }
    'cursor' {
      $p = New-Object DshCu.POINT
      [void][DshCu.Native]::GetCursorPos([ref]$p)
      @{ x = $p.X; y = $p.Y }
    }
    'pin' {
      if ($null -eq $req.handle) { throw 'handle is required' }
      $hWnd = [IntPtr]([int64]$req.handle)
      if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $($req.handle) is not a live window" }
      if (-not [DshCu.Native]::IsWindowVisible($hWnd)) { throw "window $($req.handle) is not visible, so it cannot be a target" }
      if ($req.focus -eq $true -and [DshCu.Native]::GetForegroundWindow() -ne $hWnd) {
        if ([DshCu.Native]::IsIconic($hWnd)) { [void][DshCu.Native]::ShowWindow($hWnd, 9) }
        [void][DshCu.Native]::SetForegroundWindow($hWnd)
      }
      $procId = [uint32]0
      [void][DshCu.Native]::GetWindowThreadProcessId($hWnd, [ref]$procId)
      $script:Pinned = [int64]$req.handle
      $script:PinnedPid = [int]$procId
      @{ pinned = Get-PinState; foreground = ([DshCu.Native]::GetForegroundWindow() -eq $hWnd) }
    }
    'focus-force' {
      Invoke-FocusForce $req
    }
    'render-check' {
      Invoke-RenderCheck $req
    }
    'unpin' {
      $previous = Get-PinState
      $script:Pinned = $null
      $script:PinnedPid = $null
      @{ released = $previous }
    }
    'move' {
      Assert-Target $req.minIdleMs
      Assert-Point $req.x $req.y
      [void][DshCu.Native]::SetCursorPos([int]$req.x, [int]$req.y)
      @{}
    }
    'click' {
      Assert-Target $req.minIdleMs
      Assert-Point $req.x $req.y
      $clicks = if ($req.clicks) { [int]$req.clicks } else { 1 }
      if ($clicks -lt 1 -or $clicks -gt 3) { throw 'clicks must be 1, 2 or 3' }
      $button = if ($req.button) { [string]$req.button } else { 'left' }
      $flags = Get-ButtonFlags $button
      [void][DshCu.Native]::SetCursorPos([int]$req.x, [int]$req.y)
      [DshCu.Native]::MouseButton($flags[0], $flags[1], $clicks, 30)
      @{ x = [int]$req.x; y = [int]$req.y; button = $button; clicks = $clicks }
    }
    'drag' {
      Assert-Target $req.minIdleMs
      Assert-Point $req.fromX $req.fromY
      Assert-Point $req.toX $req.toY
      $duration = if ($req.durationMs) { [int]$req.durationMs } else { 250 }
      if ($duration -lt 0 -or $duration -gt 5000) { throw 'durationMs must be between 0 and 5000' }
      $button = if ($req.button) { [string]$req.button } else { 'left' }
      $flags = Get-ButtonFlags $button
      [DshCu.Native]::Drag([int]$req.fromX, [int]$req.fromY, [int]$req.toX, [int]$req.toY, $duration, $flags[0], $flags[1])
      @{ fromX = [int]$req.fromX; fromY = [int]$req.fromY; toX = [int]$req.toX; toY = [int]$req.toY }
    }
    'scroll' {
      Assert-Target $req.minIdleMs
      $amount = [int]$req.amount
      if ($amount -eq 0) { throw 'amount must not be zero' }
      if ([Math]::Abs($amount) -gt 50) { throw 'amount must be between -50 and 50' }
      if ($null -ne $req.x -and $null -ne $req.y) {
        Assert-Point $req.x $req.y
        [void][DshCu.Native]::SetCursorPos([int]$req.x, [int]$req.y)
      }
      [DshCu.Native]::mouse_event([DshCu.Native]::MOUSEEVENTF_WHEEL, 0, 0, ($amount * 120), [UIntPtr]::Zero)
      @{ amount = $amount }
    }
    'type' {
      Assert-Target $req.minIdleMs
      $text = [string]$req.text
      if ($text.Length -eq 0) { throw 'text must not be empty' }
      if ($text.Length -gt 20000) { throw 'text exceeds the 20000 character limit' }
      [DshCu.Native]::TypeUnicode($text)
      @{ characters = $text.Length }
    }
    'key' {
      Assert-Target $req.minIdleMs
      $keys = @($req.keys)
      if ($keys.Count -lt 1 -or $keys.Count -gt 4) { throw 'keys must contain 1 to 4 entries' }
      Assert-SafeChord $keys
      $codes = @($keys | ForEach-Object { Get-KeyCode ([string]$_) })
      $vks = [uint16[]]@($codes | ForEach-Object { [uint16]$_.vk })
      $ext = [bool[]]@($codes | ForEach-Object { [bool]$_.extended })
      [DshCu.Native]::KeyChord($vks, $ext)
      @{ keys = @($keys | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }) }
    }
    'windows' { Invoke-Windows $req }
    'ocr' { Invoke-Ocr $req }
    'arrange' { Invoke-Arrange $req }
    'uiaScan' { Invoke-UiaScan $req }
    'focus' {
      if ($null -eq $req.handle) { throw 'handle is required' }
      $hWnd = [IntPtr]([int64]$req.handle)
      if (-not [DshCu.Native]::IsWindow($hWnd)) { throw "handle $($req.handle) is not a live window" }
      if ([DshCu.Native]::IsIconic($hWnd)) { [void][DshCu.Native]::ShowWindow($hWnd, 9) }
      $ok = [DshCu.Native]::SetForegroundWindow($hWnd)
      if ($req.pin -ne $false) {
        $procId = [uint32]0
        [void][DshCu.Native]::GetWindowThreadProcessId($hWnd, [ref]$procId)
        $script:Pinned = [int64]$req.handle
        $script:PinnedPid = [int]$procId
      }
      @{ focused = [bool]$ok; foreground = [DshCu.Native]::ForegroundTitle(); pinned = Get-PinState }
    }
    'screenshot' { Invoke-Screenshot $req }
    'uiaList' { Invoke-UiaList $req }
    'uiaAct' { Invoke-UiaAct $req }
    'bgClick' { Invoke-BgClick $req }
    'bgKey' { Invoke-BgKey $req }
    'exit' { $script:Stop = $true; @{} }
    default { throw "Unsupported action: $action" }
  }
}

function Write-Response($payload) {
  [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 8))
  [Console]::Out.Flush()
}

$script:Stop = $false
while (-not $script:Stop) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if ($line.Length -eq 0) { continue }
  $id = $null
  try {
    $req = $line | ConvertFrom-Json
    $id = $req.id
    $result = Invoke-Action $req
    Write-Response @{ id = $id; ok = $true; result = $result }
  } catch {
    Write-Response @{ id = $id; ok = $false; error = $_.Exception.Message }
  }
}
