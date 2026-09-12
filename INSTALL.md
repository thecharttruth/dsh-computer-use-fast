# Installing `dsh-computer-use-fast`

## The easy way: just ask the harness

Open a DeepSeek Harness session and say:

> **Install this plugin for me: https://github.com/thehcarttruth/dsh-computer-use-fast**

The agent runs the install for you. Under the hood that is one command, shown below if you prefer to type it.

## The command it runs

```sh
dsh plugin --profile web add github:thehcarttruth/dsh-computer-use-fast
```

`dsh plugin` forwards its arguments to **pnpm** inside the profile directory, so any pnpm spec works -
a GitHub shorthand, a tarball URL, or a local path.

Then **restart the profile** (`dsh --profile web`). Tool plugins register at startup, so the new
`computer_ocr` tool will not exist until the process restarts.

## After installing

The package ships a `cordis.patch.yml`, and `package.json` points at it:

```json
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
```

That is what adds the plugin row to the profile, with sensible defaults. To change behaviour, override
its config in the **profile's** `cordis.patch.yml` (`$DSH_HOME/profiles/<name>/cordis.patch.yml`) rather
than editing the installed package - a non-insert patch replaces the row's entire config object, so
restate every key you want to keep.

## Configuration reference

| Key | Default | Meaning |
|---|---|---|
| `approvalMode` | `mutating` | `mutating` asks before click/type/key/drag/scroll/move/focus/batch; `always` asks before every tool including screenshots; `never` never asks |
| `focusGuard` | `true` | refuse input when the target window is not foreground |
| `minUserIdleMs` | `0` | cursor-moving actions wait until keyboard/mouse have been quiet this long. **Set to ~3000 to keep the agent from taking the pointer out from under a human who is working.** `0` disables the wait |
| `maxScreenshotWidth` / `Height` | 1920 / 1200 | capture cap |
| `screenshotFormat` / `jpegQuality` | `png` / `80` | capture encoding |
| `requestTimeoutMs` | 15000 | per-driver-call timeout |
| `driverWarmup` | `true` | pre-start the resident driver |

Note on `approvalMode`: if the session approval policy is `never`, an `ask` decision is auto-rejected,
so mutating tools do nothing. Use `approvalMode: never` only when you deliberately want unattended control.

## Requirements

- **Windows.** The driver is PowerShell + Win32 (`SendInput`, UI Automation, PrintWindow).
- **Node >= 22.**
- **Windows PowerShell 5.1** (`powershell.exe`) - the driver host.
- OCR uses the **built-in Windows OCR engine** (`Windows.Media.Ocr`) - no extra install. One
  language pack must be present (`en-US` is typical).
- A `@deepseek-ai/dsh-tools` peer dependency, provided by the harness.