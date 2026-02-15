<#
.SYNOPSIS
    Build artifact cleaner module for Claude-Code-PCCleaner.
.DESCRIPTION
    Finds and optionally removes build artifacts (.next, dist, build, target,
    out, __pycache__, etc.) and stale dependencies (node_modules, .venv) in
    projects that haven't been modified recently.
#>

function Invoke-BuildCleaner {
    <#
    .SYNOPSIS
        Scans and optionally cleans build artifacts and stale dependencies.
    .PARAMETER Mode
        Scan (report only), Clean (interactive), or Aggressive (auto-confirm).
    .PARAMETER Config
        Configuration hashtable loaded from defaults.json.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Scan", "Clean", "Aggressive")]
        [string]$Mode,

        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $userProfile = $env:USERPROFILE
    $projectsDir = Join-Path $userProfile "projects"
    $buildPatterns = $Config.build_patterns
    $inactiveDays = $Config.inactive_project_days
    $cutoffDate = (Get-Date).AddDays(-$inactiveDays)
    $totalFreed = [long]0

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  BUILD ARTIFACT CLEANER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $projectsDir)) {
        Write-Host "  Projects directory not found: $projectsDir" -ForegroundColor Red
        Write-Host "  Nothing to scan." -ForegroundColor DarkGray
        return 0
    }

    Write-Host "  Scanning: $projectsDir" -ForegroundColor DarkGray
    Write-Host "  Inactive threshold: $inactiveDays days" -ForegroundColor DarkGray
    Write-Host "  Build patterns: $($buildPatterns -join ', ')" -ForegroundColor DarkGray
    Write-Host ""

    # --- Build Artifacts ---
    Write-Host "[Build Artifacts]" -ForegroundColor Yellow
    Write-Host ""

    $buildArtifacts = @()

    foreach ($pattern in $buildPatterns) {
        # Search for directories matching the pattern under projects
        $found = Get-ChildItem -Path $projectsDir -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $pattern }

        foreach ($dir in $found) {
            # Skip if inside node_modules or .git (avoid cleaning nested build dirs in deps)
            $relativePath = $dir.FullName.Replace($projectsDir, "")
            if ($relativePath -match '[\\/]node_modules[\\/]' -or $relativePath -match '[\\/]\.git[\\/]') {
                continue
            }

            $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $size) { $size = 0 }

            $buildArtifacts += [PSCustomObject]@{
                Type      = $pattern
                Path      = $dir.FullName
                RelPath   = $dir.FullName.Replace($userProfile, "~")
                Size      = Format-Size $size
                SizeBytes = [long]$size
                Modified  = $dir.LastWriteTime.ToString("yyyy-MM-dd")
            }
        }
    }

    if ($buildArtifacts.Count -eq 0) {
        Write-Host "  No build artifacts found." -ForegroundColor Green
    }
    else {
        $buildArtifacts | Sort-Object SizeBytes -Descending |
            Format-Table @(
                @{ Label = "Type"; Expression = { $_.Type }; Width = 16 },
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" },
                @{ Label = "Modified"; Expression = { $_.Modified }; Width = 12 },
                @{ Label = "Path"; Expression = { $_.RelPath }; Width = 70 }
            ) -AutoSize | Out-String | Write-Host

        $totalBuildSize = ($buildArtifacts | Measure-Object -Property SizeBytes -Sum).Sum
        Write-Host "  Total build artifacts: $(Format-Size $totalBuildSize) across $($buildArtifacts.Count) directories" -ForegroundColor White
        Write-Host ""

        # Clean build artifacts
        if ($Mode -ne "Scan") {
            if ($Mode -eq "Aggressive") {
                Write-Host "  [Aggressive] Removing all build artifacts..." -ForegroundColor Red
                foreach ($artifact in $buildArtifacts) {
                    try {
                        Remove-Item -Path $artifact.Path -Recurse -Force -ErrorAction Stop
                        Write-Host "    Removed: $($artifact.RelPath) ($($artifact.Size))" -ForegroundColor Green
                        $totalFreed += $artifact.SizeBytes
                    }
                    catch {
                        Write-Host "    Failed: $($artifact.RelPath) -- $_" -ForegroundColor Red
                    }
                }
            }
            else {
                $response = Read-Host "  Remove all build artifacts ($(Format-Size $totalBuildSize))? [y/N]"
                if ($response -match '^[Yy]') {
                    foreach ($artifact in $buildArtifacts) {
                        try {
                            Remove-Item -Path $artifact.Path -Recurse -Force -ErrorAction Stop
                            Write-Host "    Removed: $($artifact.RelPath) ($($artifact.Size))" -ForegroundColor Green
                            $totalFreed += $artifact.SizeBytes
                        }
                        catch {
                            Write-Host "    Failed: $($artifact.RelPath) -- $_" -ForegroundColor Red
                        }
                    }
                }
                else {
                    Write-Host "  Skipped." -ForegroundColor DarkGray
                }
            }
            Write-Host ""
        }
    }

    # --- Stale node_modules ---
    Write-Host "[Stale node_modules (inactive > $inactiveDays days)]" -ForegroundColor Yellow
    Write-Host ""

    $staleNodeModules = @()

    $nodeModulesDirs = Get-ChildItem -Path $projectsDir -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "node_modules" }

    foreach ($dir in $nodeModulesDirs) {
        # Skip nested node_modules (only care about top-level per project)
        $relativePath = $dir.FullName.Replace($projectsDir, "")
        $depth = ($relativePath -split '[\\/]' | Where-Object { $_ -eq "node_modules" }).Count
        if ($depth -gt 1) { continue }

        # Check if the parent project is inactive
        $parentProject = $dir.Parent
        $lastActivity = $parentProject.LastWriteTime

        # Also check for recently modified source files in the project
        $recentFiles = Get-ChildItem -Path $parentProject.FullName -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $cutoffDate } |
            Select-Object -First 1

        if ($null -eq $recentFiles -and $lastActivity -lt $cutoffDate) {
            $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $size) { $size = 0 }

            $staleNodeModules += [PSCustomObject]@{
                Project   = $parentProject.Name
                Path      = $dir.FullName
                RelPath   = $dir.FullName.Replace($userProfile, "~")
                Size      = Format-Size $size
                SizeBytes = [long]$size
                LastUsed  = $lastActivity.ToString("yyyy-MM-dd")
            }
        }
    }

    if ($staleNodeModules.Count -eq 0) {
        Write-Host "  No stale node_modules found." -ForegroundColor Green
    }
    else {
        $staleNodeModules | Sort-Object SizeBytes -Descending |
            Format-Table @(
                @{ Label = "Project"; Expression = { $_.Project }; Width = 30 },
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" },
                @{ Label = "Last Used"; Expression = { $_.LastUsed }; Width = 12 },
                @{ Label = "Path"; Expression = { $_.RelPath }; Width = 50 }
            ) -AutoSize | Out-String | Write-Host

        $totalNodeSize = ($staleNodeModules | Measure-Object -Property SizeBytes -Sum).Sum
        Write-Host "  Total stale node_modules: $(Format-Size $totalNodeSize) across $($staleNodeModules.Count) projects" -ForegroundColor White
        Write-Host ""

        if ($Mode -ne "Scan") {
            $shouldClean = $false
            if ($Mode -eq "Aggressive") {
                $shouldClean = $true
                Write-Host "  [Aggressive] Removing all stale node_modules..." -ForegroundColor Red
            }
            else {
                $response = Read-Host "  Remove stale node_modules ($(Format-Size $totalNodeSize))? [y/N]"
                $shouldClean = $response -match '^[Yy]'
            }

            if ($shouldClean) {
                foreach ($nm in $staleNodeModules) {
                    try {
                        Remove-Item -Path $nm.Path -Recurse -Force -ErrorAction Stop
                        Write-Host "    Removed: $($nm.RelPath) ($($nm.Size))" -ForegroundColor Green
                        $totalFreed += $nm.SizeBytes
                    }
                    catch {
                        Write-Host "    Failed: $($nm.RelPath) -- $_" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  Skipped." -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    # --- Stale .venv ---
    Write-Host ""
    Write-Host "[Stale .venv (inactive > $inactiveDays days)]" -ForegroundColor Yellow
    Write-Host ""

    $staleVenvs = @()

    $venvDirs = Get-ChildItem -Path $projectsDir -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq ".venv" }

    foreach ($dir in $venvDirs) {
        $parentProject = $dir.Parent
        $lastActivity = $parentProject.LastWriteTime

        $recentFiles = Get-ChildItem -Path $parentProject.FullName -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $cutoffDate } |
            Select-Object -First 1

        if ($null -eq $recentFiles -and $lastActivity -lt $cutoffDate) {
            $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $size) { $size = 0 }

            $staleVenvs += [PSCustomObject]@{
                Project   = $parentProject.Name
                Path      = $dir.FullName
                RelPath   = $dir.FullName.Replace($userProfile, "~")
                Size      = Format-Size $size
                SizeBytes = [long]$size
                LastUsed  = $lastActivity.ToString("yyyy-MM-dd")
            }
        }
    }

    if ($staleVenvs.Count -eq 0) {
        Write-Host "  No stale .venv directories found." -ForegroundColor Green
    }
    else {
        $staleVenvs | Sort-Object SizeBytes -Descending |
            Format-Table @(
                @{ Label = "Project"; Expression = { $_.Project }; Width = 30 },
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" },
                @{ Label = "Last Used"; Expression = { $_.LastUsed }; Width = 12 }
            ) -AutoSize | Out-String | Write-Host

        $totalVenvSize = ($staleVenvs | Measure-Object -Property SizeBytes -Sum).Sum
        Write-Host "  Total stale .venv: $(Format-Size $totalVenvSize) across $($staleVenvs.Count) projects" -ForegroundColor White
        Write-Host ""

        if ($Mode -ne "Scan") {
            $shouldClean = $false
            if ($Mode -eq "Aggressive") {
                $shouldClean = $true
                Write-Host "  [Aggressive] Removing all stale .venv..." -ForegroundColor Red
            }
            else {
                $response = Read-Host "  Remove stale .venv directories ($(Format-Size $totalVenvSize))? [y/N]"
                $shouldClean = $response -match '^[Yy]'
            }

            if ($shouldClean) {
                foreach ($venv in $staleVenvs) {
                    try {
                        Remove-Item -Path $venv.Path -Recurse -Force -ErrorAction Stop
                        Write-Host "    Removed: $($venv.RelPath) ($($venv.Size))" -ForegroundColor Green
                        $totalFreed += $venv.SizeBytes
                    }
                    catch {
                        Write-Host "    Failed: $($venv.RelPath) -- $_" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  Skipped." -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""

    if ($Mode -ne "Scan" -and $totalFreed -gt 0) {
        Write-Host "  Build cleaner freed: $(Format-Size $totalFreed)" -ForegroundColor Green
    }

    Write-Host ""

    return $totalFreed
}
