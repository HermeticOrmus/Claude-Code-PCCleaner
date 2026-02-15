# Claude-Code-PCCleaner

A full PC optimization toolkit for developers. Disk, RAM, caches, apps, startup, OneDrive -- all from a single command.

---

## Project Overview

This tool addresses the universal problem of developer machine entropy: package manager caches growing to gigabytes, abandoned build artifacts lingering, browser caches bloating, startup programs multiplying, and SSDs filling past the performance cliff. It provides a modular, scan-first approach to reclaiming resources.

## Key Files

| File | Purpose |
|------|---------|
| `pccleaner.ps1` | Main orchestrator for Windows (PowerShell) |
| `pccleaner.sh` | Main orchestrator for Linux/macOS (Bash) |
| `config/defaults.json` | Configurable thresholds and paths |
| `modules/disk-audit.ps1` | Drive analysis, large file finder |
| `modules/cache-cleaner.ps1` | Package manager cache cleanup |
| `modules/build-cleaner.ps1` | Build artifact and stale dependency cleanup |
| `modules/process-audit.ps1` | RAM analysis, process management |
| `modules/app-cleaner.ps1` | Browser and Electron app cache cleanup |
| `modules/startup-audit.ps1` | Startup program audit and management |
| `modules/onedrive-opt.ps1` | OneDrive local cache optimization |

## Architecture

### PowerShell (Windows)

The main script `pccleaner.ps1` dot-sources all modules from `modules/`. Each module exports a function following the pattern `Invoke-<Name> -Mode <Scan|Clean|Aggressive> -Config <hashtable>`. The main script:

1. Loads config from `config/defaults.json`
2. Captures before-metrics (disk free, RAM available)
3. Dispatches to modules based on flags
4. Captures after-metrics and shows delta summary

### Bash (Linux/macOS)

`pccleaner.sh` is a self-contained equivalent. All module functions are defined within the single file. Windows-specific modules (OneDrive, startup) are omitted.

## Safety Philosophy

- **Scan is the default.** No flags = full report, zero changes.
- **Clean requires confirmation.** Each action group prompts before executing.
- **Aggressive auto-confirms.** For when you know what you want.
- **Never delete sacred paths.** `.git`, `.env`, SSH keys, global npm tools are always excluded.
- **Preview before action.** Every cleanup shows exactly what will happen.

## Commit Format

```
type(scope): description
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
Scopes: `disk`, `cache`, `build`, `process`, `app`, `startup`, `onedrive`, `bash`, `config`, `docs`

## Testing

Always test changes in scan mode first. The `-Scan` flag (or `--scan`) should never modify the filesystem.

## Important Notes

- `AppData/Roaming/npm` is NOT a cache -- it contains globally installed CLI tools
- SSD performance degrades significantly above 85% capacity
- `attrib +U -P` sets OneDrive files to online-only (dehydrates them)
- PowerShell `$_` gets mangled by Git Bash extglob -- always use `.ps1` script files
- IPVanish and some apps have broken uninstallers -- may need manual removal

## Cross-Platform Notes

- PowerShell uses `Get-ChildItem`, `Get-Process`, `Get-CimInstance`, `Remove-Item`
- Bash uses `du`, `find`, `ps`, `free`/`vm_stat`, `df`, `rm`
- Config file is shared between both implementations
- Windows-only modules: `startup-audit`, `onedrive-opt`

---

> *"A clean workspace is a clear mind."*
