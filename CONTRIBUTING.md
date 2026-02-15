# Contributing to Claude-Code-PCCleaner

We welcome contributions that align with the Gold Hat Philosophy: **empower users, never extract from them.**

---

## Reporting Issues

When reporting a bug, please include:

- **Operating system** and version (e.g., Windows 11 24H2, Pop!_OS 22.04)
- **Shell environment** (PowerShell 7, Bash 5.1, Git Bash, etc.)
- **Script output** from a scan-mode run showing the issue
- **Steps to reproduce** the problem

## Submitting Changes

### Before You Start

1. Fork the repository and create a branch from `main`
2. Use conventional commit format: `type(scope): description`
   - `feat(cache): add Bun cache detection`
   - `fix(build): correct .venv age calculation`
   - `docs: update module descriptions`
   - `refactor(startup): restructure registry scanning`
3. Test your changes in **scan mode** before submitting

### Development Guidelines

- **Cross-platform**: Consider how changes affect both Windows and Linux/macOS
- **Safety-first**: Never remove the scan-mode default. Every destructive action must be previewed first
- **Clarity over cleverness**: Write code that explains itself. Comments explain WHY, not WHAT
- **Test with edge cases**: Zero processes, empty directories, permission errors, missing tools

### Commit Format

```
type(scope): short description

Longer description if needed. Explain WHY, not just WHAT.

Refs: #issue-number (if applicable)
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
Scopes: `disk`, `cache`, `build`, `process`, `app`, `startup`, `onedrive`, `bash`, `config`, `docs`

### Pull Requests

- Keep PRs focused -- one feature or fix per PR
- Describe what changed and why
- Include before/after output if behavior changed
- Tag with relevant labels

## What We Welcome

- Bug fixes with reproduction steps
- New cleanup targets (with safety measures)
- New package manager cache detection
- Performance improvements
- Documentation clarity
- Cross-platform compatibility fixes

## What We Reject

- Telemetry or tracking of any kind
- Features that bypass safety measures
- Changes that remove the scan-mode default
- Complexity without clear value
- Dependencies on external services
- Anything that deletes without preview

## Code of Conduct

Build what elevates. Reject what degrades. Treat contributors with the dignity you'd want for yourself.

---

> *Every contribution should leave the user more empowered than before.*
