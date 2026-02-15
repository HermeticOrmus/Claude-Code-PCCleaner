<#
.SYNOPSIS
    Disk usage audit module for Claude-Code-PCCleaner.
.DESCRIPTION
    Scans key directories and reports disk usage. Identifies large files,
    breaks down user profile directories, and reports drive capacity with
    color-coded health indicators.
#>

function Get-DirectorySize {
    <#
    .SYNOPSIS
        Calculates the total size of a directory in bytes.
    .DESCRIPTION
        Recursively measures all files in a directory. Returns 0 if the
        directory doesn't exist or is inaccessible. Uses -ErrorAction
        SilentlyContinue to skip permission-denied files gracefully.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return 0 }

    try {
        $size = (Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $size) { return 0 }
        return [long]$size
    }
    catch {
        return 0
    }
}

function Format-Size {
    <#
    .SYNOPSIS
        Converts bytes to a human-readable string (KB, MB, GB, TB).
    #>
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Invoke-DiskAudit {
    <#
    .SYNOPSIS
        Performs a full disk usage audit.
    .PARAMETER Mode
        Scan (report only), Clean (interactive), or Aggressive (auto-confirm).
        Disk audit is always report-only regardless of mode.
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

    $thresholdMB = $Config.large_file_threshold_mb
    $thresholdBytes = [long]$thresholdMB * 1MB
    $userProfile = $env:USERPROFILE
    $projectsDir = Join-Path $userProfile "projects"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  DISK AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- Drive Capacity ---
    Write-Host "[Drive Capacity]" -ForegroundColor Yellow
    Write-Host ""

    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 -or $_.Free -gt 0 }

    foreach ($drive in $drives) {
        $total = $drive.Used + $drive.Free
        if ($total -eq 0) { continue }

        $freePercent = [math]::Round(($drive.Free / $total) * 100, 1)
        $usedPercent = [math]::Round(($drive.Used / $total) * 100, 1)

        $color = "Green"
        if ($freePercent -lt 15) { $color = "Red" }
        elseif ($freePercent -lt 25) { $color = "Yellow" }

        $driveName = "$($drive.Name):\"
        Write-Host "  $driveName" -ForegroundColor White -NoNewline
        Write-Host "  Total: $(Format-Size $total)" -NoNewline
        Write-Host "  Used: $(Format-Size $drive.Used) ($usedPercent%)" -NoNewline
        Write-Host "  Free: $(Format-Size $drive.Free) ($freePercent%)" -ForegroundColor $color

        # Visual bar
        $barLength = 40
        $usedBars = [math]::Round(($usedPercent / 100) * $barLength)
        $freeBars = $barLength - $usedBars
        $bar = "[" + ("=" * $usedBars) + ("-" * $freeBars) + "]"
        Write-Host "  $bar" -ForegroundColor $color
    }

    Write-Host ""

    # --- User Profile Breakdown ---
    Write-Host "[User Profile Breakdown]" -ForegroundColor Yellow
    Write-Host "  Profile: $userProfile" -ForegroundColor DarkGray
    Write-Host ""

    $profileDirs = @(
        @{ Name = "Desktop";    Path = Join-Path $userProfile "Desktop" },
        @{ Name = "Downloads";  Path = Join-Path $userProfile "Downloads" },
        @{ Name = "Documents";  Path = Join-Path $userProfile "Documents" },
        @{ Name = "Pictures";   Path = Join-Path $userProfile "Pictures" },
        @{ Name = "Videos";     Path = Join-Path $userProfile "Videos" },
        @{ Name = "Music";      Path = Join-Path $userProfile "Music" },
        @{ Name = "AppData";    Path = Join-Path $userProfile "AppData" }
    )

    $profileResults = @()
    foreach ($dir in $profileDirs) {
        if (Test-Path $dir.Path) {
            $size = Get-DirectorySize -Path $dir.Path
            $profileResults += [PSCustomObject]@{
                Directory = $dir.Name
                Path      = $dir.Path
                Size      = Format-Size $size
                SizeBytes = $size
            }
        }
    }

    $profileResults | Sort-Object SizeBytes -Descending |
        Format-Table @(
            @{ Label = "Directory"; Expression = { $_.Directory }; Width = 15 },
            @{ Label = "Size"; Expression = { $_.Size }; Width = 15; Alignment = "Right" },
            @{ Label = "Path"; Expression = { $_.Path }; Width = 60 }
        ) -AutoSize | Out-String | Write-Host

    # --- Projects Breakdown ---
    if (Test-Path $projectsDir) {
        Write-Host "[Projects Breakdown]" -ForegroundColor Yellow
        Write-Host "  Projects: $projectsDir" -ForegroundColor DarkGray
        Write-Host ""

        $projectFolders = Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue
        $projectResults = @()

        foreach ($folder in $projectFolders) {
            $size = Get-DirectorySize -Path $folder.FullName
            $projectResults += [PSCustomObject]@{
                Project   = $folder.Name
                Size      = Format-Size $size
                SizeBytes = $size
            }
        }

        $projectResults | Sort-Object SizeBytes -Descending |
            Format-Table @(
                @{ Label = "Project"; Expression = { $_.Project }; Width = 40 },
                @{ Label = "Size"; Expression = { $_.Size }; Width = 15; Alignment = "Right" }
            ) -AutoSize | Out-String | Write-Host

        $totalProjectSize = ($projectResults | Measure-Object -Property SizeBytes -Sum).Sum
        Write-Host "  Total projects: $(Format-Size $totalProjectSize)" -ForegroundColor White
        Write-Host ""
    }

    # --- Large File Finder ---
    Write-Host "[Large Files (> $thresholdMB MB)]" -ForegroundColor Yellow
    Write-Host "  Scanning user profile... this may take a moment." -ForegroundColor DarkGray
    Write-Host ""

    $largeFiles = Get-ChildItem -Path $userProfile -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $thresholdBytes } |
        Sort-Object Length -Descending |
        Select-Object -First 30

    if ($largeFiles.Count -eq 0) {
        Write-Host "  No files found above $(Format-Size $thresholdBytes)." -ForegroundColor Green
    }
    else {
        $largeFileResults = @()
        foreach ($file in $largeFiles) {
            $largeFileResults += [PSCustomObject]@{
                Size     = Format-Size $file.Length
                Modified = $file.LastWriteTime.ToString("yyyy-MM-dd")
                Path     = $file.FullName.Replace($userProfile, "~")
            }
        }

        $largeFileResults |
            Format-Table @(
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" },
                @{ Label = "Modified"; Expression = { $_.Modified }; Width = 12 },
                @{ Label = "Path"; Expression = { $_.Path }; Width = 80 }
            ) -AutoSize | Out-String | Write-Host

        $totalLargeSize = ($largeFiles | Measure-Object -Property Length -Sum).Sum
        Write-Host "  Total in large files: $(Format-Size $totalLargeSize)" -ForegroundColor White
    }

    Write-Host ""
}
