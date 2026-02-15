<#
.SYNOPSIS
    OneDrive optimization module for Claude-Code-PCCleaner.
.DESCRIPTION
    Scans the OneDrive folder for large locally-cached files and optionally
    sets them to online-only using 'attrib +U -P' to free local disk space.
    Skips files that are currently open or recently accessed.
#>

function Invoke-OneDriveOpt {
    <#
    .SYNOPSIS
        Scans and optionally dehydrates OneDrive files to free local space.
    .PARAMETER Mode
        Scan (report only), Clean (interactive), or Aggressive (auto-dehydrate).
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
    $totalFreeable = [long]0
    $totalFreed = [long]0

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  ONEDRIVE OPTIMIZATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Find OneDrive folder(s)
    # Common locations: ~/OneDrive, ~/OneDrive - Personal, ~/OneDrive - CompanyName
    $oneDrivePaths = @()

    # Check environment variable first
    if ($env:OneDrive -and (Test-Path $env:OneDrive)) {
        $oneDrivePaths += $env:OneDrive
    }

    # Also check for common OneDrive directory names
    $possiblePaths = Get-ChildItem -Path $userProfile -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^OneDrive" }

    foreach ($dir in $possiblePaths) {
        if ($oneDrivePaths -notcontains $dir.FullName) {
            $oneDrivePaths += $dir.FullName
        }
    }

    if ($oneDrivePaths.Count -eq 0) {
        Write-Host "  OneDrive folder not found." -ForegroundColor DarkGray
        Write-Host "  Checked: `$env:OneDrive, $userProfile\OneDrive*" -ForegroundColor DarkGray
        Write-Host ""
        return 0
    }

    $recentThreshold = (Get-Date).AddHours(-24)

    foreach ($oneDrivePath in $oneDrivePaths) {
        Write-Host "[OneDrive: $oneDrivePath]" -ForegroundColor Yellow
        Write-Host ""

        # Get total local footprint
        $allFiles = Get-ChildItem -Path $oneDrivePath -Recurse -File -Force -ErrorAction SilentlyContinue
        $totalLocalSize = ($allFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalLocalSize) { $totalLocalSize = 0 }

        Write-Host "  Total local footprint: $(Format-Size $totalLocalSize)" -ForegroundColor White
        Write-Host "  Total files: $($allFiles.Count)" -ForegroundColor DarkGray
        Write-Host ""

        # Find files that are locally available and could be dehydrated
        # Files with the 'O' (offline) attribute are already online-only
        # Files with 'P' (pinned) are always kept local
        # We target files without 'O' attribute (they are locally cached)
        $localFiles = @()
        $skippedRecent = 0
        $skippedSmall = 0

        foreach ($file in $allFiles) {
            # Skip very small files (not worth dehydrating)
            if ($file.Length -lt 1MB) {
                $skippedSmall++
                continue
            }

            # Skip recently accessed files (within 24 hours)
            if ($file.LastAccessTime -gt $recentThreshold -or $file.LastWriteTime -gt $recentThreshold) {
                $skippedRecent++
                continue
            }

            # Check if file is already online-only by checking attributes
            # Online-only files in OneDrive have the ReparsePoint attribute
            # and very small on-disk size. We check via attrib output.
            try {
                $attribOutput = & attrib $file.FullName 2>$null
                if ($attribOutput -match "U") {
                    # Already online-only (has Unpinned attribute)
                    continue
                }
            }
            catch {
                continue
            }

            $localFiles += [PSCustomObject]@{
                Name      = $file.Name
                Path      = $file.FullName
                RelPath   = $file.FullName.Replace($oneDrivePath, "~OneDrive")
                Size      = Format-Size $file.Length
                SizeBytes = $file.Length
                Modified  = $file.LastWriteTime.ToString("yyyy-MM-dd")
                Accessed  = $file.LastAccessTime.ToString("yyyy-MM-dd")
            }

            $totalFreeable += $file.Length
        }

        Write-Host "  Dehydratable files: $($localFiles.Count)" -ForegroundColor White
        Write-Host "  Space freeable: $(Format-Size $totalFreeable)" -ForegroundColor White
        Write-Host "  Skipped (< 1 MB): $skippedSmall" -ForegroundColor DarkGray
        Write-Host "  Skipped (accessed < 24h): $skippedRecent" -ForegroundColor DarkGray
        Write-Host ""

        if ($localFiles.Count -eq 0) {
            Write-Host "  No files eligible for dehydration." -ForegroundColor Green
            Write-Host ""
            continue
        }

        # Show top files by size
        Write-Host "  [Largest locally-cached files]" -ForegroundColor Yellow
        Write-Host ""

        $topFiles = $localFiles | Sort-Object SizeBytes -Descending | Select-Object -First 20

        $topFiles |
            Format-Table @(
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" },
                @{ Label = "Modified"; Expression = { $_.Modified }; Width = 12 },
                @{ Label = "Path"; Expression = { $_.RelPath }; Width = 70 }
            ) -AutoSize | Out-String | Write-Host

        # Size breakdown by extension
        Write-Host "  [Size by file type]" -ForegroundColor Yellow
        Write-Host ""

        $byExtension = $localFiles |
            Group-Object { [System.IO.Path]::GetExtension($_.Name).ToLower() } |
            ForEach-Object {
                $extTotal = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
                [PSCustomObject]@{
                    Extension = if ($_.Name) { $_.Name } else { "(no ext)" }
                    Count     = $_.Count
                    Size      = Format-Size $extTotal
                    SizeBytes = $extTotal
                }
            } |
            Sort-Object SizeBytes -Descending |
            Select-Object -First 10

        $byExtension |
            Format-Table @(
                @{ Label = "Extension"; Expression = { $_.Extension }; Width = 12 },
                @{ Label = "Files"; Expression = { $_.Count }; Width = 8; Alignment = "Right" },
                @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" }
            ) -AutoSize | Out-String | Write-Host

        # Dehydrate in Clean/Aggressive mode
        if ($Mode -ne "Scan" -and $localFiles.Count -gt 0) {
            $shouldDehydrate = $false

            if ($Mode -eq "Aggressive") {
                $shouldDehydrate = $true
            }
            else {
                $response = Read-Host "  Set $($localFiles.Count) files to online-only (free $(Format-Size $totalFreeable))? [y/N]"
                $shouldDehydrate = $response -match '^[Yy]'
            }

            if ($shouldDehydrate) {
                Write-Host ""
                Write-Host "  Dehydrating files (setting to online-only)..." -ForegroundColor Yellow
                $dehydrated = 0
                $failedCount = 0

                foreach ($file in $localFiles) {
                    try {
                        # attrib +U -P sets the file to online-only (Unpinned, not Pinned)
                        $result = & attrib "+U" "-P" $file.Path 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $dehydrated++
                            $totalFreed += $file.SizeBytes
                        }
                        else {
                            $failedCount++
                        }
                    }
                    catch {
                        $failedCount++
                    }
                }

                Write-Host "  Dehydrated: $dehydrated files" -ForegroundColor Green
                Write-Host "  Space freed: ~$(Format-Size $totalFreed)" -ForegroundColor Green
                if ($failedCount -gt 0) {
                    Write-Host "  Failed: $failedCount files (may be in use)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "  Skipped." -ForegroundColor DarkGray
            }
        }

        Write-Host ""
    }

    return $totalFreed
}
