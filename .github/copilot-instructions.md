# Copilot Instructions for OpenClaw-WSL

## Project Overview

OpenClaw-WSL is a portable PowerShell automation system that installs and manages [OpenClaw](https://github.com/pjasicek/OpenClaw) within Windows Subsystem for Linux (WSL). The system is designed to be fully portable—copy the folder to any PC and it works.

## Architecture

### Module System
All functionality is organized into PowerShell modules in `modules/`:

| Module | Purpose |
|--------|---------|
| `Core.psm1` | Logging, input validation, admin checks, retry utilities |
| `WSLManager.psm1` | WSL distribution management (create, import, export, run commands) |
| `MenuSystem.psm1` | Interactive console menu components |
| `LinuxConfig.psm1` | Linux user/package configuration inside WSL |
| `IsolationConfig.psm1` | Filesystem and network isolation settings |
| `SoftwareInstall.psm1` | Node.js, npm, and OpenClaw installation |
| `LauncherGenerator.psm1` | Creates launch scripts in `.local/scripts/` |
| `PathUtils.psm1` | Path resolution between Windows and WSL |
| `PathRelocation.psm1` | Detects and repairs WSL registration when folder is moved |
| `ProfileManager.psm1` | Manages reading and switching between AI model profiles |
| `SettingsManager.psm1` | User-configurable settings with defaults and override persistence |
| `CommandPresets.psm1` | Loads and executes command presets in multiple execution modes |
| `Logger.psm1` | File-based logging with rotation |

### Entry Points
- `Start.ps1` — Main menu entry point (for terminal)
- `Start.bat` — Double-click launcher that auto-elevates to admin
- `scripts/internal/Install-OpenClaw.ps1` — Full installation workflow
- `scripts/internal/Uninstall-OpenClaw.ps1` — Uninstallation workflow

### Launcher Behavior
The launcher (`launch-openclaw.ps1`) opens OpenClaw in a **separate WSL terminal window**. The WSL terminal window shows all OpenClaw output natively—do not try to capture or stream WSL output in PowerShell. The launcher's role is simply to:
1. Open the browser with the dashboard URL
2. Display the gateway password
3. Launch WSL in a new window with the gateway command
4. Exit immediately (non-blocking)

### Data Layout
All user/local data lives in `.local/` (gitignored):
```
.local/
├── wsl/           # WSL virtual disk (ext4.vhdx)
├── data/          # Shared folder mounted in WSL
├── scripts/       # Generated launch scripts
├── logs/          # Log files
└── state.json     # Installation state
```

### Configuration
`config/defaults.json` contains default settings for:
- WSL distribution name (`openclaw`)
- Linux username (`openclaw`)
- Required Linux packages
- Node.js version
- Logging configuration

## Code Conventions

### PowerShell Style
- All modules require PowerShell 5.1+ (`#Requires -Version 5.1`)
- Use `[CmdletBinding()]` on all functions
- Export functions explicitly with `Export-ModuleMember`
- Use `Write-LogMessage` for dual console/file logging, not `Write-Host` for status messages
- Input validation uses `Read-ValidatedInput`, `Read-Choice`, `Read-YesNo` from Core.psm1

### WSL Command Execution
Use direct invocation, not `Start-Process`, for interactive commands:
```powershell
# Correct
& wsl.exe -d $distro -u $user -- bash -lc "command"

# Avoid (breaks TTY)
Start-Process -FilePath "wsl.exe" -ArgumentList ... -NoNewWindow -Wait
```

### Error Handling
- Wrap unreliable operations with `Invoke-WithRetry` from Core.psm1
- Check `$LASTEXITCODE` after external commands
- Use safe string handling for WSL output (may return error objects instead of strings)

### Menu System Pattern
Menus use a declarative options array:
```powershell
$menuOptions = @(
    @{ Text = "Option 1"; Description = "..."; Action = "Action1" },
    @{ Text = "Option 2"; Description = "..."; Action = "Action2"; Disabled = $true }
)
$selection = Show-SelectMenu -Title "Title" -Options $menuOptions
```

### Batch File Pitfalls
When writing `.bat` files that call PowerShell:
- **No caret line continuation** — `^` inside `-Command` strings passes literal `^` to PowerShell, causing syntax errors. Keep commands on a single line.
- **Quote escaping** — Use single quotes inside the PowerShell command, double quotes outside: `powershell -Command "Get-Item '%VAR%'"`
- **Variable expansion** — Batch `%VAR%` expands before PowerShell sees it; use `!VAR!` with `setlocal EnableDelayedExpansion` for dynamic values.

### PowerShell String Escaping in Generated Scripts
When generating PowerShell scripts that execute bash commands with complex regex/sed:
- **Avoid complex regex in bash one-liners** — PowerShell's backtick escaping combined with bash quoting creates escaping nightmares
- **Use jq instead of grep/sed for JSON** — `jq -r '.path.to.field'` is cleaner than `grep | sed` chains
- **Example of problematic pattern**:
  ```powershell
  # BAD - escaping hell
  $token = & wsl -- bash -lc "grep -o '`"token`": *`"[^`"]*`"' file.json | sed 's/.*`"token`": *`\"`([^`\"]*`)\"`/\1/'"
  
  # GOOD - use jq
  $token = & wsl -- bash -lc "jq -r '.gateway.auth.token' file.json"
  ```

### Here-String Variable Expansion Rules (`@"..."@`)
The `@"..."@` expandable here-string expands ALL `$variable` references regardless of surrounding quotes inside the template. Embedded single quotes, double quotes, or bash quoting have NO effect on PowerShell expansion — only the backtick escape (`` ` ``) prevents it:

| Here-string content | Output | Why |
|---|---|---|
| `$HOME` | `C:\Users\...` (Windows path!) | Expanded by PS at generation time |
| `` `$HOME `` | `$HOME` | Backtick prevents expansion |
| `'$HOME'` | `'C:\Users\...'` | Single quotes are just literal chars in here-strings |
| `` '$HOME' `` | ERROR — never write this | The backtick escapes the `'`, not the `$` |
| `` '`$HOME' `` | `'$HOME'` | Backtick escapes the `$`, quotes are literal |
| `$?` | `True` or `False` | PS auto-variable, expanded |
| `` `$? `` | `$?` | Escaped — safe for bash |

**Critical rule**: In `@"..."@`, EVERY `$` that should appear literally in the output MUST be escaped with `` ` ``, even if it's "inside" single quotes, bash command strings, or heredocs. The here-string parser does not understand any quoting layer — it only respects `` ` ``.

### Passing Bash Variables Through PowerShell to WSL
When passing commands to `wsl.exe -- bash -lc`, bash variables (`$HOME`, `$?`, `$PATH`) must survive PowerShell's string processing:

```powershell
# In a regular PS script (not inside a here-string template):

# CORRECT: Single-quoted PS string — no expansion, bash receives $HOME literally
$cmd = 'echo $HOME'
& wsl.exe -d openclaw -- bash -lc $cmd

# CORRECT: Piping content via stdin avoids all quoting issues
$content = @"
process.on('uncaughtException', (err) => {
  console.log(err.message);
});
"@
$content | & wsl.exe -d openclaw -- bash -c 'cat > ~/myfile.js'

# WRONG: Double-quoted PS string — $HOME expands to Windows path
$cmd = "echo $HOME"  # becomes "echo C:\Users\..."
```

```powershell
# Inside a @"..."@ here-string template (e.g., LauncherGenerator.psm1):

# To produce a PS single-quoted string in the generated script:
`$cmd = 'echo `$HOME && echo `$?'
# Output: $cmd = 'echo $HOME && echo $?'
# At runtime: single quotes prevent PS expansion, bash expands $HOME and $?

# To produce a PS double-quoted string — AVOID if it contains bash $ variables
# The generated script would try to expand $HOME as a PS variable
```

### Batch File Quote Escaping with WSL
When passing double-quoted arguments from `.bat` files to `wsl.exe`:
- `\"` inside `set "VAR=..."` is stored literally as `\"` in the batch variable
- When expanded with `!VAR!` into `wsl.exe -- bash -lc "!VAR!"`, bash interprets `\"` as escaped double quotes
- This works because `cmd.exe`'s `set` treats everything between outer quotes literally, and bash understands `\"` escaping inside `"..."`
- `$` signs are NOT special in batch — they pass through to bash unchanged

### Console Box Drawing
When creating visual boxes/borders in PowerShell console output:
- **Never use right-side borders** — Terminal widths vary and right-aligned box characters (`│` on right side) will misalign
- **Use open-right format** — Only draw left border and top/bottom edges:
  ```powershell
  # Good - open right side, works in all terminals
  Write-Host "  ┌─ Title ──────────────────────" -ForegroundColor Yellow
  Write-Host "  │  Content line here" -ForegroundColor Yellow
  Write-Host "  └──────────────────────────────" -ForegroundColor Yellow
  
  # Bad - right border will misalign in different terminal widths
  Write-Host "  ╭────────────────────────────────────╮" -ForegroundColor Yellow
  Write-Host "  │  Content line here                 │" -ForegroundColor Yellow
  Write-Host "  ╰────────────────────────────────────╯" -ForegroundColor Yellow
  ```
- **Reason** — PowerShell's `Write-Host` doesn't pad strings, and different console fonts render Unicode box characters with varying widths

## Troubleshooting

This document contains solutions for both common and **the most challenging, hard-to-diagnose errors** encountered during development and deployment. When facing issues, consult `docs/TROUBLESHOOT.md`.

If facing a new or unusual error or really difficult problem, please contribute your findings to `docs/TROUBLESHOOT.md` to assist future users and developers.
