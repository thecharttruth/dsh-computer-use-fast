# dsh-computer-use-fast

Native Windows computer use for DeepSeek Harness: one Cordis plugin row that gives the
agent a screen, a pointer, a keyboard, cheap window metadata, and a **background control
path** that does not touch your cursor — with an explicit coordinate contract, a focus
guard, and an idle gate.

Written against this deployment: DSH `0.1.5-rc.1`, `@deepseek-ai/dsh-tools@0.1.5-rc.1`,
Windows, Node 22+.

## Why it is fast

Every other Windows computer-use plugin for DSH spawns a fresh `powershell.exe` per
action, which costs roughly 300-600 ms of process startup and `Add-Type` compilation
before anything happens. This one keeps **one resident driver** for the whole session and
talks to it over newline-delimited JSON, so an action costs a JSON line plus the action.

Measured on a 2560x1440 desktop (`node test/driver-bench.mjs`):

| Operation | Warm latency |
|---|---|
| `computer_cursor` / geometry round trip | **0.5-0.7 ms** |
| `computer_windows` (20 rows) | **~2 ms** |
| `computer_uia_list` (typical window) | **~20 ms** |
| screenshot 2560x1440 -> 1920x1080 png | ~122 ms |
| screenshot -> jpeg q80 | ~100 ms |
| offscreen `PrintWindow` capture | ~115 ms |
| cold start (once per session, warmed at plugin load) | ~500 ms |

Two further speed features:

- `computer_batch` runs up to 24 input steps in one tool call, so a form fill does not
  pay a model round trip per field.
- `computer_windows`, `computer_cursor` and `computer_uia_list` give grounding without a
  screenshot at all.

## Tools

| Tool | Moves cursor? | Approval | Purpose |
|---|---|---|---|
| `computer_screenshot` | no | read | Capture the desktop, the foreground window, or — with `handle` — any window offscreen via PrintWindow, with origin and scale. |
| `computer_windows` | no | read | Visible top-level windows: handle, pid, title, rectangle, minimized, foreground. |
| `computer_cursor` | no | read | Pointer, virtual desktop, foreground title, user idle time, pinned target. |
| `computer_idle` | no | read | Idle time and the current gate verdict, for pacing a run. |
| `computer_uia_list` | **no** | read | UI Automation tree: names, types, ids, rectangles, values, supported patterns. |
| `computer_pin` | no | ask | Claim a window as the input target; later actions are refused if it loses focus. |
| `computer_release` | no | read | Drop the pin. |
| `computer_uia_act` | **no** | ask | Invoke / set_value / select / toggle / expand / collapse / scroll_into_view / focus an element. |
| `computer_bg_click` | **no** | ask | Post a click to a window by handle. |
| `computer_bg_key` | **no** | ask | Post text or a chord to a window by handle. |
| `computer_click` | yes | ask | Foreground click at a desktop coordinate (`clicks` 1-3). |
| `computer_move` | yes | ask | Move the pointer. |
| `computer_drag` | yes | ask | Press, move smoothly, release. |
| `computer_scroll` | yes | ask | Wheel scroll, optionally after moving to a coordinate. |
| `computer_type` | yes | ask | Type Unicode text into the focused control. |
| `computer_key` | yes | ask | Press a key or chord, e.g. `["CTRL","L"]`. |
| `computer_focus` | yes | ask | Bring a window forward (and pin it). |
| `computer_focus_force` | yes | ask | Full foreground-transfer sequence — AttachThreadInput, BringWindowToTop, an ALT nudge to clear the foreground lock, then verify and retry — for when `computer_focus` is refused. |
| `computer_render_check` | no | read | Capture a window offscreen and report whether it is painting content or is blank, with pixel statistics and a verdict. |
| `computer_ocr` | **no** | read | Read the **text** displayed in a window without focusing it: offscreen PrintWindow capture, then the built-in Windows OCR engine. For panels that expose no UI Automation tree - grids, charts, statistics readouts that are pixels only. |
| `computer_wait` | no | read | Sleep briefly. |
| `computer_batch` | yes | ask once | 1-24 foreground input steps back to back. |

## Working while the user works

Two independent mechanisms, usable separately or together.

**Tier 1 — cooperation (foreground input, bounded).** Every coordinate the agent sends is
a physical desktop pixel, and the driver enforces all of this regardless of configuration:
coordinates must be integers inside the virtual desktop, clicks are 1-3, scroll is
±50, keys come from an allow-list, the Windows key / CTRL+ALT+DELETE / PRINTSCREEN are
refused, and text is capped at 20000 characters.

On top of that:

- **Focus pin.** Pin a window and every foreground input action first verifies that the
  *same* window is still foreground, that it still exists, and that it still belongs to
  the same process. If you take the desktop back, the action is **refused** with a clear
  explanation instead of typing into your window. A batch aborts at the offending step.
- **Idle gate.** With `minUserIdleMs` above 0, foreground input is refused until the
  keyboard and mouse have been untouched for that long, so the agent waits for you rather
  than fighting you. `computer_idle` reports the current value and verdict.
- **Panic.** Stopping the session in the DSH GUI aborts the in-flight tool call; the
  driver forwards the abort into the pending request.

**Tier 2 — background control (no cursor, no focus).** For the apps that accept it, these
tools act on a specific window handle through UI Automation patterns or posted window
messages:

- `computer_uia_list` reads the accessibility tree: element names, control types,
  automation ids, screen rectangles, current values and supported patterns.
- `computer_uia_act` then drives an element by pattern — `set_value` writes a text field,
  `invoke` presses a button — with **no cursor movement and no focus change**.
- `computer_bg_click` / `computer_bg_key` post mouse and keyboard messages to the handle
  for controls with no usable pattern.
- `computer_screenshot handle=` renders the window offscreen with `PrintWindow`, so an
  occluded window can be observed while it stays behind your work.
- `computer_ocr` reads text out of a window the same non-invasive way: an offscreen capture feeds the
  **built-in Windows OCR engine** (`Windows.Media.Ocr`), and the recognised lines come back as plain text.
  Use it for values that exist only as pixels - a statistics panel, a chart axis, a grid that UI Automation
  cannot see. Nothing moves the cursor and nothing takes focus, so it is safe while the human is typing.
  It returns unstructured lines, so extract the numbers you need rather than expecting columns.

Honest limits, reported to the model rather than hidden:

- Posted messages are **asynchronous and unverified**. Classic Win32/WPF/WinForms controls
  usually respond; Electron/Chromium apps, UWP and games frequently ignore posted input.
  Every such tool says so in its result and tells the agent to confirm the effect.
- `PrintWindow` can return a blank frame for GPU-composited apps; the driver samples the
  bitmap, refuses to pass off an all-one-colour capture, and says why. Use
  `computer_render_check` when you need to tell a genuinely blank window apart from a refused
  capture — it returns a verdict and pixel statistics instead of collapsing both into one error.
- `computer_focus` makes a single `SetForegroundWindow` call, which Windows silently ignores when
  another window owns the foreground. Use `computer_focus_force`, which attaches to the foreground
  thread, raises the target, nudges ALT to clear the foreground lock, then verifies and retries.
- UI Automation trees are sparse in some apps (Chrome exposes mostly unnamed panes unless
  accessibility is fully enabled). `computer_uia_list` reports that honestly.
- `computer_uia_act` never writes into a password field, and refuses an element that
  belongs to a different window than the one requested.
- Background tools deliberately **skip the idle gate** — not disturbing you is their whole
  point — but they still honour the pin.

## Diagnosing a blank or unfocused window

Two failures look alike from the outside and previously had no direct test.

**A window is not foreground.** Every point-addressed UI Automation action then resolves an element
in whatever window *is* foreground — the classic symptom of "I clicked the right coordinates and got
an element from the wrong application". `computer_focus` is often silently refused because Windows
only lets the thread that currently owns the foreground hand it away. `computer_focus_force` runs
the whole transfer: attach to the foreground thread, `BringWindowToTop`, `SetForegroundWindow`,
`SetActiveWindow`, an ALT press/release nudge to clear the foreground lock, then verify the result
and retry. It reports how many attempts it needed, or that something is holding the lock.

**A window is painting nothing.** `computer_screenshot handle=` cannot distinguish "the application
drew nothing" from "Windows refused the offscreen capture" — both surface as the same error.
`computer_render_check` captures anyway and returns:

- a verdict: `rendered`, `blank-white`, `blank-black`, `blank-uniform`, `blank-near-uniform`, or
  `capture-refused`;
- pixel statistics: distinct colours, mean and standard deviation of luminance, and the fraction of
  near-white and near-black samples;
- whether the window currently holds the foreground;
- optionally the PNG itself via `save_path`.

Read it like this:

| Verdict | Likely meaning |
|---|---|
| `rendered` | The window has content; proceed with `computer_screenshot` or `computer_uia_list`. |
| `blank-white` / `blank-black` | The application built its window but not its content — commonly resource dictionaries failed to load (a missing theme or image assembly in the install). |
| `blank-uniform` / `blank-near-uniform` | Nothing meaningful was painted; likely GPU-composited and occluded, or still initialising. |
| `capture-refused` | The capture failed at the Windows level; focus the window and capture with `computer_screenshot target=active` instead. |

## The coordinate contract

`computer_screenshot` reports `origin_x`, `origin_y` and `scale`, and its text block states
the transform:

```
desktop = origin + image_coordinate / scale
```

That mapping is computed from the dimensions the attachment store actually returns, so it
stays correct even when the store normalizes the image. Getting this wrong is the most
common source of mis-clicks in hand-rolled computer-use tools.

## Install

```powershell
dsh plugin --profile web add "link:C:/path/to/dsh-computer-use-fast"
```

Then restart DSH (a new bundle layer is picked up at boot) and verify:

```powershell
dsh --profile web --dump-config    # look for the computer-use-fast row
```

Remove it again with:

```powershell
dsh plugin --profile web remove dsh-computer-use-fast
```

## Configuration

Edit the row in the profile's `cordis.patch.yml` (hot-reloaded where the profile sets
`patchReload: live`), or override it in a preset. A non-insert patch replaces the row's
whole config object, so restate every key you want to keep.

| Key | Default | Meaning |
|---|---|---|
| `approvalMode` | `mutating` | `mutating` asks before input actions only, `always` asks for every tool, `never` never asks. |
| `focusGuard` | `true` | `computer_focus` pins the target by default. |
| `minUserIdleMs` | `0` | Foreground input is refused until the user has been idle this long; 0 disables the gate. |
| `maxScreenshotWidth` | `1920` | Capture is scaled down to fit; 320-10000. |
| `maxScreenshotHeight` | `1200` | As above. |
| `screenshotFormat` | `png` | `png` (lossless) or `jpeg` (~5x smaller). |
| `jpegQuality` | `80` | 10-100. |
| `requestTimeoutMs` | `15000` | Per-action driver timeout; a timeout kills and respawns the driver. |
| `driverWarmup` | `true` | Start the driver at plugin load so the first action is warm. |

> **Interaction with the session approval policy.** If the session policy is `never`,
> every `ask` is auto-rejected, so mutating tools do nothing. Either switch the session
> policy back to `ask`, or set `approvalMode: never` and accept unattended control.

## Security posture

- **No network, ever.** Neither `index.js` nor `driver.ps1` contains a URL, HTTP client,
  socket, telemetry, or update check. Nothing about your desktop leaves the machine — in
  particular there is no "vision model fallback" that uploads screenshots.
- **No files written.** The driver writes nothing to disk: screenshots travel as bytes
  over the pipe; no temp files, caches, or logs.
- **No clipboard access.** Typing uses `SendInput` with `KEYEVENTF_UNICODE`; the
  background path uses `WM_CHAR`. Delete and re-type rather than paste.
- **No keyboard hooks.** Input is injected, never observed; the plugin cannot see what you
  type. The idle gate reads the system-wide idle counter, not key content.
- **No registry, service, scheduled task, or persistence code.** No `eval`, no
  `new Function`, no shell interpolation — the driver is invoked with a fixed argv array
  and input travels as JSON over stdin.
- **Bounded by construction** in both layers, as listed under Tier 1.
- **Fail closed on approval** with `approvalMode` at `mutating` or `always`.
- **Readable.** ~1,700 lines of plain source in two files, one dependency (`defineTool`),
  no build step, no bundled or minified code, no native binaries beyond the Windows system
  DLLs PowerShell binds to.

Known limits: input to elevated (UAC) windows is refused by Windows UIPI; `computer_focus`
can be refused when another process owns the foreground; `computer_uia_act focus` changes
keyboard focus inside the target window.

## Development

```powershell
node test/driver-bench.mjs   # driver protocol, latency, rejection matrix, UIA + offscreen reads
node test/smoke.mjs          # registration, approval gate, tier 1 pin/idle, tier 2 reads, validation
node test/tier2-e2e.mjs      # optional: opens Notepad and proves background input end to end
```

The first two are read-only against your desktop — they never click, type, or move the
pointer anywhere it was not already. The third opens a Notepad window, so run it when you
are not mid-sentence elsewhere; it closes the window afterwards.


## Licence and contributing

**MIT.** Do whatever you want with it: use it, modify it, fork it, ship it commercially, redistribute it.
There are no restrictions and no warranty. See `LICENSE`.

Contributions are welcome - open an issue or a pull request at
<https://github.com/thecharttruth/dsh-computer-use-fast>.

## Provenance and attribution

This package is distributed as part of the **DeepSeek Harness** plugin ecosystem and depends on
`@deepseek-ai/dsh-tools`. It is built on the `dsh-computer-use-fast` component that ships with the
harness, with these additions by this repository:

- the `computer_ocr` tool (offscreen capture + built-in Windows OCR)
- packaging for standalone distribution (metadata, `INSTALL.md`, licence)
- documentation of the idle-gate cooperation semantics

If you are the upstream author and would like attribution changed or the redistribution removed,
please open an issue and it will be actioned.
