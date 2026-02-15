<#
.SYNOPSIS
    Application cache cleaner module for Claude-Code-PCCleaner.
.DESCRIPTION
    Cleans browser caches (Chrome, Firefox, Edge), Electron app caches
    (Discord, Slack, VS Code, Figma), and system temp directories.
#>

function Invoke-AppCleaner {
    <#
    .SYNOPSIS
        Scans and optionally cleans application caches and temp files.
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
    $localAppData = $env:LOCALAPPDATA
    $appData = $env:APPDATA
    $tempAgeDays = $Config.temp_age_days
    $tempCutoff = (Get-Date).AddDays(-$tempAgeDays)
    $totalFreed = [long]0

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  APPLICATION CACHE CLEANER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Define all cache targets
    # Each target has a name, one or more paths to check, and a description
    $cacheTargets = @(
        # --- Browsers ---
        @{
            Name  = "Chrome Cache"
            Group = "Browser"
            Paths = @(
                "$localAppData\Google\Chrome\User Data\Default\Cache",
                "$localAppData\Google\Chrome\User Data\Default\Code Cache",
                "$localAppData\Google\Chrome\User Data\Default\GPUCache",
                "$localAppData\Google\Chrome\User Data\Default\Service Worker\CacheStorage",
                "$localAppData\Google\Chrome\User Data\ShaderCache"
            )
        },
        @{
            Name  = "Edge Cache"
            Group = "Browser"
            Paths = @(
                "$localAppData\Microsoft\Edge\User Data\Default\Cache",
                "$localAppData\Microsoft\Edge\User Data\Default\Code Cache",
                "$localAppData\Microsoft\Edge\User Data\Default\GPUCache",
                "$localAppData\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage",
                "$localAppData\Microsoft\Edge\User Data\ShaderCache"
            )
        },
        @{
            Name  = "Firefox Cache"
            Group = "Browser"
            Paths = @(
                "$localAppData\Mozilla\Firefox\Profiles\*.default*\cache2"
            )
        },

        # --- Electron Apps ---
        @{
            Name  = "Discord Cache"
            Group = "Electron"
            Paths = @(
                "$appData\discord\Cache",
                "$appData\discord\Code Cache",
                "$appData\discord\GPUCache"
            )
        },
        @{
            Name  = "Slack Cache"
            Group = "Electron"
            Paths = @(
                "$appData\Slack\Cache",
                "$appData\Slack\Code Cache",
                "$appData\Slack\GPUCache",
                "$appData\Slack\Service Worker\CacheStorage"
            )
        },
        @{
            Name  = "VS Code Cache"
            Group = "Electron"
            Paths = @(
                "$appData\Code\Cache",
                "$appData\Code\CachedData",
                "$appData\Code\CachedExtensions",
                "$appData\Code\CachedExtensionVSIXs",
                "$appData\Code\Code Cache",
                "$appData\Code\GPUCache"
            )
        },
        @{
            Name  = "Figma Cache"
            Group = "Electron"
            Paths = @(
                "$appData\Figma\Cache",
                "$appData\Figma\Code Cache",
                "$appData\Figma\GPUCache"
            )
        },

        # --- Other Apps ---
        @{
            Name  = "Spotify Cache"
            Group = "Other"
            Paths = @(
                "$localAppData\Spotify\Storage",
                "$appData\Spotify\Data"
            )
        },
        @{
            Name  = "Replit Cache"
            Group = "Other"
            Paths = @(
                "$appData\replit\Cache",
                "$appData\replit\Code Cache"
            )
        }
    )

    # Scan all cache targets
    $results = @()

    foreach ($target in $cacheTargets) {
        $targetSize = [long]0
        $targetExists = $false
        $resolvedPaths = @()

        foreach ($pathPattern in $target.Paths) {
            # Resolve wildcards (for Firefox profiles)
            $resolved = Resolve-Path -Path $pathPattern -ErrorAction SilentlyContinue
            foreach ($rp in $resolved) {
                if (Test-Path $rp.Path) {
                    $targetExists = $true
                    $resolvedPaths += $rp.Path
                    $size = (Get-ChildItem -Path $rp.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($null -ne $size) { $targetSize += $size }
                }
            }

            # If no wildcard, try direct path
            if ($resolved.Count -eq 0 -and (Test-Path $pathPattern)) {
                $targetExists = $true
                $resolvedPaths += $pathPattern
                $size = (Get-ChildItem -Path $pathPattern -Recurse -File -Force -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($null -ne $size) { $targetSize += $size }
            }
        }

        if ($targetExists) {
            $results += [PSCustomObject]@{
                Name          = $target.Name
                Group         = $target.Group
                Size          = Format-Size $targetSize
                SizeBytes     = $targetSize
                Paths         = $resolvedPaths
                PathCount     = $resolvedPaths.Count
            }
        }
    }

    # Display by group
    $groups = $results | Group-Object Group

    foreach ($group in $groups) {
        Write-Host "[$($group.Name) Caches]" -ForegroundColor Yellow
        Write-Host ""

        foreach ($item in ($group.Group | Sort-Object SizeBytes -Descending)) {
            $sizeColor = if ($item.SizeBytes -gt 500MB) { "Red" }
                         elseif ($item.SizeBytes -gt 100MB) { "Yellow" }
                         else { "White" }

            Write-Host "  $($item.Name)" -ForegroundColor White -NoNewline
            Write-Host "  $(($item.Size).PadLeft(12))" -ForegroundColor $sizeColor -NoNewline
            Write-Host "  ($($item.PathCount) locations)" -ForegroundColor DarkGray
        }

        $groupTotal = ($group.Group | Measure-Object -Property SizeBytes -Sum).Sum
        Write-Host ""
        Write-Host "  Subtotal: $(Format-Size $groupTotal)" -ForegroundColor White
        Write-Host ""

        # Clean this group
        if ($Mode -ne "Scan" -and $groupTotal -gt 0) {
            $shouldClean = $false

            if ($Mode -eq "Aggressive") {
                $shouldClean = $true
            }
            else {
                $response = Read-Host "  Clean all $($group.Name) caches ($(Format-Size $groupTotal))? [y/N]"
                $shouldClean = $response -match '^[Yy]'
            }

            if ($shouldClean) {
                foreach ($item in $group.Group) {
                    foreach ($path in $item.Paths) {
                        try {
                            # Remove contents but preserve the directory itself
                            # (some apps expect the cache directory to exist)
                            Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue |
                                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                            Write-Host "    Cleaned: $($item.Name)" -ForegroundColor Green
                            $totalFreed += $item.SizeBytes
                        }
                        catch {
                            Write-Host "    Partial clean of $($item.Name) (some files in use)" -ForegroundColor Yellow
                        }
                    }
                }
            }
            else {
                Write-Host "  Skipped." -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    # --- Temp Directories ---
    Write-Host "[Temp Directories]" -ForegroundColor Yellow
    Write-Host ""

    $tempDirs = @(
        @{ Name = "User Temp"; Path = $env:TEMP },
        @{ Name = "Windows Temp"; Path = "C:\Windows\Temp" }
    )

    foreach ($tempDir in $tempDirs) {
        if (-not (Test-Path $tempDir.Path)) {
            Write-Host "  $($tempDir.Name): Not accessible" -ForegroundColor DarkGray
            continue
        }

        # Count old temp files (older than threshold)
        $oldFiles = Get-ChildItem -Path $tempDir.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $tempCutoff }

        $oldSize = ($oldFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $oldSize) { $oldSize = 0 }

        $totalSize = (Get-ChildItem -Path $tempDir.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalSize) { $totalSize = 0 }

        Write-Host "  $($tempDir.Name) ($($tempDir.Path))" -ForegroundColor White
        Write-Host "    Total size: $(Format-Size $totalSize)" -ForegroundColor DarkGray
        Write-Host "    Files older than $tempAgeDays days: $(Format-Size $oldSize) ($($oldFiles.Count) files)" -ForegroundColor Yellow

        if ($Mode -ne "Scan" -and $oldSize -gt 0) {
            $shouldClean = $false

            if ($Mode -eq "Aggressive") {
                $shouldClean = $true
            }
            else {
                $response = Read-Host "    Clean old temp files from $($tempDir.Name) ($(Format-Size $oldSize))? [y/N]"
                $shouldClean = $response -match '^[Yy]'
            }

            if ($shouldClean) {
                $cleaned = 0
                $failed = 0
                foreach ($file in $oldFiles) {
                    try {
                        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                        $cleaned++
                        $totalFreed += $file.Length
                    }
                    catch {
                        $failed++
                    }
                }
                Write-Host "    Cleaned $cleaned files" -ForegroundColor Green
                if ($failed -gt 0) {
                    Write-Host "    $failed files in use (skipped)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "    Skipped." -ForegroundColor DarkGray
            }
        }

        Write-Host ""
    }

    # Summary
    $totalAppCache = ($results | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host "[App Cache Summary]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Total application caches: $(Format-Size $totalAppCache)" -ForegroundColor White

    if ($Mode -ne "Scan" -and $totalFreed -gt 0) {
        Write-Host "  Space freed: $(Format-Size $totalFreed)" -ForegroundColor Green
    }

    Write-Host ""

    return $totalFreed
}
