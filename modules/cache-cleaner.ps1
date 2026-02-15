<#
.SYNOPSIS
    Package manager cache cleaner module for Claude-Code-PCCleaner.
.DESCRIPTION
    Identifies and cleans package manager caches: npm, uv, pip, Go, Cargo.
    Reports size before cleaning. Warns about commonly confused paths
    (e.g., AppData/Roaming/npm is NOT a cache).
#>

function Invoke-CacheCleaner {
    <#
    .SYNOPSIS
        Scans and optionally cleans package manager caches.
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
    $totalFreed = [long]0

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CACHE CLEANER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- WARNING about common confusion ---
    Write-Host "  [!] WARNING: AppData\Roaming\npm is NOT a cache." -ForegroundColor Red
    Write-Host "      It contains globally installed CLI tools (claude, vercel, etc.)." -ForegroundColor Red
    Write-Host "      This module will NEVER touch it." -ForegroundColor Red
    Write-Host ""

    # Define cache targets with their detection and cleaning strategies
    $cacheTargets = @(
        @{
            Name        = "npm"
            Path        = Join-Path $userProfile $Config.cache_paths.npm
            CleanCmd    = "npm cache clean --force"
            HasCLI      = $null -ne (Get-Command npm -ErrorAction SilentlyContinue)
        },
        @{
            Name        = "uv (Python)"
            Path        = ""  # uv uses its own managed location
            CleanCmd    = "uv cache clean"
            HasCLI      = $null -ne (Get-Command uv -ErrorAction SilentlyContinue)
            CLIOnly     = $true
        },
        @{
            Name        = "pip"
            Path        = Join-Path $userProfile $Config.cache_paths.pip
            CleanCmd    = "pip cache purge"
            HasCLI      = $null -ne (Get-Command pip -ErrorAction SilentlyContinue)
        },
        @{
            Name        = "Go modules"
            Path        = Join-Path $userProfile $Config.cache_paths.go
            CleanCmd    = "go clean -modcache"
            HasCLI      = $null -ne (Get-Command go -ErrorAction SilentlyContinue)
        },
        @{
            Name        = "Cargo"
            Path        = Join-Path $userProfile $Config.cache_paths.cargo
            CleanCmd    = $null  # No CLI clean command -- direct delete
            HasCLI      = $false
        }
    )

    $results = @()

    foreach ($cache in $cacheTargets) {
        $name = $cache.Name
        $cacheSize = [long]0
        $exists = $false

        # Check if cache exists via path or CLI
        if ($cache.CLIOnly -and $cache.HasCLI) {
            # For uv, query cache size via CLI
            $exists = $true
            try {
                $uvOutput = & uv cache dir 2>$null
                if ($uvOutput -and (Test-Path $uvOutput)) {
                    $cacheSize = (Get-ChildItem -Path $uvOutput -Recurse -File -Force -ErrorAction SilentlyContinue |
                                  Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($null -eq $cacheSize) { $cacheSize = 0 }
                    $cache.Path = $uvOutput
                }
            }
            catch {
                $cacheSize = 0
            }
        }
        elseif ($cache.Path -and (Test-Path $cache.Path)) {
            $exists = $true
            $cacheSize = (Get-ChildItem -Path $cache.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $cacheSize) { $cacheSize = 0 }
        }

        $status = if ($exists) { "Found" } else { "Not found" }
        $statusColor = if ($exists -and $cacheSize -gt 0) { "Yellow" }
                       elseif ($exists) { "Green" }
                       else { "DarkGray" }

        $results += [PSCustomObject]@{
            Name      = $name
            Status    = $status
            Size      = if ($exists) { Format-Size $cacheSize } else { "-" }
            SizeBytes = $cacheSize
            Path      = if ($cache.Path) { $cache.Path } else { "(managed by CLI)" }
        }

        # Display each cache
        Write-Host "  [$name]" -ForegroundColor White
        if ($exists -and $cacheSize -gt 0) {
            Write-Host "    Size: $(Format-Size $cacheSize)" -ForegroundColor $statusColor
            Write-Host "    Path: $($cache.Path)" -ForegroundColor DarkGray
        }
        elseif ($exists) {
            Write-Host "    Empty or inaccessible" -ForegroundColor DarkGray
        }
        else {
            Write-Host "    Not found" -ForegroundColor DarkGray
            if (-not $cache.HasCLI -and -not $cache.CLIOnly) {
                Write-Host "    ($name CLI not installed)" -ForegroundColor DarkGray
            }
        }

        # Clean if in Clean or Aggressive mode and cache exists
        if ($Mode -ne "Scan" -and $exists -and $cacheSize -gt 0) {
            $shouldClean = $false

            if ($Mode -eq "Aggressive") {
                $shouldClean = $true
            }
            else {
                $response = Read-Host "    Clean $name cache ($(Format-Size $cacheSize))? [y/N]"
                $shouldClean = $response -match '^[Yy]'
            }

            if ($shouldClean) {
                Write-Host "    Cleaning..." -ForegroundColor Yellow

                try {
                    if ($cache.HasCLI -and $cache.CleanCmd) {
                        # Prefer CLI tool for cleaning when available
                        $cmdParts = $cache.CleanCmd -split ' ', 2
                        $exe = $cmdParts[0]
                        $args = if ($cmdParts.Length -gt 1) { $cmdParts[1] } else { "" }

                        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $processInfo.FileName = $exe
                        $processInfo.Arguments = $args
                        $processInfo.RedirectStandardOutput = $true
                        $processInfo.RedirectStandardError = $true
                        $processInfo.UseShellExecute = $false
                        $processInfo.CreateNoWindow = $true

                        $process = [System.Diagnostics.Process]::Start($processInfo)
                        $process.WaitForExit(60000) | Out-Null

                        Write-Host "    Cleaned via: $($cache.CleanCmd)" -ForegroundColor Green
                    }
                    elseif ($cache.Path -and (Test-Path $cache.Path)) {
                        # Direct delete for caches without CLI clean commands
                        Remove-Item -Path $cache.Path -Recurse -Force -ErrorAction Stop
                        Write-Host "    Deleted: $($cache.Path)" -ForegroundColor Green
                    }

                    $totalFreed += $cacheSize
                }
                catch {
                    Write-Host "    Error cleaning $name`: $_" -ForegroundColor Red
                }
            }
            else {
                Write-Host "    Skipped." -ForegroundColor DarkGray
            }
        }

        Write-Host ""
    }

    # Summary table
    Write-Host "[Cache Summary]" -ForegroundColor Yellow
    Write-Host ""

    $results | Format-Table @(
        @{ Label = "Cache"; Expression = { $_.Name }; Width = 15 },
        @{ Label = "Status"; Expression = { $_.Status }; Width = 12 },
        @{ Label = "Size"; Expression = { $_.Size }; Width = 12; Alignment = "Right" }
    ) -AutoSize | Out-String | Write-Host

    $totalCacheSize = ($results | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host "  Total cache size: $(Format-Size $totalCacheSize)" -ForegroundColor White

    if ($Mode -ne "Scan" -and $totalFreed -gt 0) {
        Write-Host "  Space freed: $(Format-Size $totalFreed)" -ForegroundColor Green
    }

    Write-Host ""

    return $totalFreed
}
