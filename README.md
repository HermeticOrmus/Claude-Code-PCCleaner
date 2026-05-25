> **Superseded by [`claude-maintain`](https://github.com/HermeticOrmus/claude-maintain)**, the maintained Claude Code environment-maintenance CLI. This repository is archived and kept for reference.

> **"Your machine is an extension of your mind. A cluttered system breeds cluttered thinking."**

# Claude-Code-PCCleaner

Full PC optimization for developers. Reclaim disk space, free RAM, clean caches, audit startup programs, and optimize OneDrive -- all from a single command.

---

## The Problem

Development machines accumulate cruft faster than any other workstation. Package manager caches grow to gigabytes. Build artifacts from abandoned experiments linger. Browser caches bloat. Startup programs multiply. Before you know it, your 512GB SSD is at 90% capacity and your builds are crawling.

## The Solution

A modular cleanup toolkit that scans, reports, and cleans with surgical precision. Every module operates in scan mode by default -- you always see the full picture before any changes are made.

## What's Inside

| Module | What It Cleans |
|--------|---------------|
| `disk-audit` | Drive analysis, large file finder, directory breakdown |
| `cache-cleaner` | npm, uv, pip, Go, Cargo caches |
| `build-cleaner` | .next, dist, build, target, node_modules, .venv |
| `process-audit` | RAM hogs, killable processes |
| `app-cleaner` | Browser caches, Electron apps, temp files |
| `startup-audit` | Startup programs (Windows) |
| `onedrive-opt` | OneDrive local cache optimization (Windows) |

## Quick Start

### Prerequisites

- **Windows**: PowerShell 5.1+
- **Linux/macOS**: Bash 4+

### Windows

```powershell
# Full system scan (safe -- changes nothing)
.\pccleaner.ps1 -Scan

# Clean package manager caches only
.\pccleaner.ps1 -Clean -Caches

# Clean build artifacts only
.\pccleaner.ps1 -Clean -Builds

# Clean everything with confirmations
.\pccleaner.ps1 -Clean

# Maximum cleanup (auto-confirm)
.\pccleaner.ps1 -Aggressive
```

### Linux/macOS

```bash
# Full system scan
./pccleaner.sh --scan

# Clean caches
./pccleaner.sh --clean --caches

# Clean build artifacts
./pccleaner.sh --clean --builds

# Maximum cleanup
./pccleaner.sh --aggressive
```

## Core Concepts

### Modular Architecture

Each cleanup domain is an independent module. Run them individually or together. Each module can scan (report) or clean (act). The main script orchestrates them based on your flags.

### Safety Tiers

| Mode | Behavior |
|------|----------|
| `Scan` (default) | Report only -- nothing is modified |
| `Clean` | Interactive -- confirms each action |
| `Aggressive` | Auto-confirm -- maximum cleanup |

### What's Safe to Delete

| Always Safe | Check First | Never Delete |
|-------------|-------------|--------------|
| Package manager caches | node_modules (can reinstall) | AppData/Roaming/npm (global tools) |
| Build artifacts | .venv (can recreate) | .git directories |
| Temp files > 7 days | Browser caches | .env files |
| Debug logs | App caches | SSH keys |

## Configuration

Edit `config/defaults.json`:

```json
{
  "dry_run": true,
  "large_file_threshold_mb": 500,
  "inactive_project_days": 30,
  "temp_age_days": 7
}
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. We follow the Gold Hat philosophy: every contribution should empower users, never extract from them.

## License

MIT + Gold Hat Addendum. See [LICENSE](LICENSE).

---

> *"As above, so below. As the code, so the consciousness."*
>
> **-- Hermetic Ormus, Gold Hat Technologist**
