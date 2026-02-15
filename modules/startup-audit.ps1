<#
.SYNOPSIS
    Startup program audit module for Claude-Code-PCCleaner.
.DESCRIPTION
    Lists and categorizes startup programs from the Windows registry,
    startup folder, and WMI. Offers to disable optional or suspicious items.
#>

# Known essential startup items (partial name match)
$script:EssentialPatterns = @(
    "SecurityHealth",  # Windows Security
    "Windows Defender", # Defender
    "RealTek", "Realtek",  # Audio drivers
    "NVIDIA", "nvidia",  # GPU drivers
    "AMD", "Radeon",  # AMD GPU
    "Intel",  # Intel drivers
    "SynTP", "Synaptics",  # Touchpad
    "igfx",  # Intel Graphics
    "WindowsTerminal",
    "ctfmon",  # Text input
    "OneDrive"  # OneDrive sync (debatable but usually wanted)
)

# Known optional apps (partial name match)
$script:OptionalPatterns = @(
    "Spotify", "Discord", "Slack", "Steam", "Epic Games",
    "iTunes", "Dropbox", "Teams", "Zoom", "Skype",
    "Adobe", "Acrobat", "Creative Cloud",
    "Figma", "Notion", "Obsidian",
    "VPN", "IPVanish", "NordVPN", "ExpressVPN",
    "Java Update", "CCleaner", "Google Update",
    "Cortana", "YourPhone", "GameBar"
)

function Get-StartupCategory {
    <#
    .SYNOPSIS
        Categorizes a startup item as Essential, Optional, or Suspicious.
    #>
    param([string]$Name, [string]$Command)

    foreach ($pattern in $script:EssentialPatterns) {
        if ($Name -match [regex]::Escape($pattern) -or $Command -match [regex]::Escape($pattern)) {
            return "Essential"
        }
    }

    foreach ($pattern in $script:OptionalPatterns) {
        if ($Name -match [regex]::Escape($pattern) -or $Command -match [regex]::Escape($pattern)) {
            return "Optional"
        }
    }

    return "Unknown"
}

function Get-RegistryStartupItems {
    <#
    .SYNOPSIS
        Reads startup items from a registry path.
    #>
    param(
        [string]$Path,
        [string]$Source
    )

    $items = @()

    if (-not (Test-Path $Path)) { return $items }

    $reg = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $reg) { return $items }

    foreach ($valueName in $reg.GetValueNames()) {
        if ([string]::IsNullOrWhiteSpace($valueName)) { continue }

        $command = $reg.GetValue($valueName)
        $category = Get-StartupCategory -Name $valueName -Command "$command"

        $items += [PSCustomObject]@{
            Name     = $valueName
            Command  = "$command"
            Source   = $Source
            Category = $category
        }
    }

    return $items
}

function Invoke-StartupAudit {
    <#
    .SYNOPSIS
        Audits and optionally manages startup programs.
    .PARAMETER Mode
        Scan (report only), Clean (interactive disable), or Aggressive (auto-disable optional).
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

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  STARTUP AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $allItems = @()

    # --- Registry: Current User ---
    Write-Host "[Registry - Current User]" -ForegroundColor Yellow
    $hkcuPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $hkcuItems = Get-RegistryStartupItems -Path $hkcuPath -Source "HKCU\Run"
    $allItems += $hkcuItems

    if ($hkcuItems.Count -gt 0) {
        Write-Host "  Source: $hkcuPath" -ForegroundColor DarkGray
        Write-Host ""
    }
    else {
        Write-Host "  No items found." -ForegroundColor DarkGray
        Write-Host ""
    }

    # --- Registry: Local Machine ---
    Write-Host "[Registry - Local Machine]" -ForegroundColor Yellow
    $hklmPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    $hklmItems = Get-RegistryStartupItems -Path $hklmPath -Source "HKLM\Run"
    $allItems += $hklmItems

    if ($hklmItems.Count -gt 0) {
        Write-Host "  Source: $hklmPath" -ForegroundColor DarkGray
        Write-Host "  (Modifying HKLM requires admin privileges)" -ForegroundColor DarkGray
        Write-Host ""
    }
    else {
        Write-Host "  No items found." -ForegroundColor DarkGray
        Write-Host ""
    }

    # --- Startup Folder ---
    Write-Host "[Startup Folder]" -ForegroundColor Yellow
    $startupFolder = [System.Environment]::GetFolderPath("Startup")

    if (Test-Path $startupFolder) {
        $startupFiles = Get-ChildItem -Path $startupFolder -File -ErrorAction SilentlyContinue

        foreach ($file in $startupFiles) {
            $category = Get-StartupCategory -Name $file.Name -Command $file.FullName

            $allItems += [PSCustomObject]@{
                Name     = $file.BaseName
                Command  = $file.FullName
                Source   = "Startup Folder"
                Category = $category
            }
        }

        Write-Host "  Folder: $startupFolder" -ForegroundColor DarkGray
        Write-Host "  Items: $($startupFiles.Count)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Startup folder not found." -ForegroundColor DarkGray
    }

    Write-Host ""

    # --- WMI Backup (additional items) ---
    Write-Host "[WMI Startup Commands]" -ForegroundColor Yellow

    try {
        $wmiStartup = Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue

        foreach ($item in $wmiStartup) {
            # Avoid duplicates from registry scan
            $isDuplicate = $allItems | Where-Object { $_.Name -eq $item.Name }
            if ($isDuplicate) { continue }

            $category = Get-StartupCategory -Name $item.Name -Command $item.Command

            $allItems += [PSCustomObject]@{
                Name     = $item.Name
                Command  = $item.Command
                Source   = "WMI ($($item.Location))"
                Category = $category
            }
        }

        Write-Host "  Queried Win32_StartupCommand successfully." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  WMI query failed (non-critical): $_" -ForegroundColor DarkGray
    }

    Write-Host ""

    # --- Display All Items ---
    if ($allItems.Count -eq 0) {
        Write-Host "  No startup items found." -ForegroundColor Green
        return
    }

    Write-Host "[All Startup Items ($($allItems.Count) total)]" -ForegroundColor Yellow
    Write-Host ""

    # Display by category
    $categories = @("Essential", "Optional", "Unknown")

    foreach ($cat in $categories) {
        $catItems = $allItems | Where-Object { $_.Category -eq $cat }
        if ($catItems.Count -eq 0) { continue }

        $catColor = switch ($cat) {
            "Essential" { "Green" }
            "Optional"  { "Yellow" }
            "Unknown"   { "Red" }
        }

        Write-Host "  --- $cat ($($catItems.Count)) ---" -ForegroundColor $catColor
        Write-Host ""

        foreach ($item in $catItems) {
            Write-Host "    $($item.Name)" -ForegroundColor White
            Write-Host "      Command: $($item.Command)" -ForegroundColor DarkGray
            Write-Host "      Source:  $($item.Source)" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    # --- Disable optional/suspicious items in Clean/Aggressive mode ---
    $disableTargets = $allItems | Where-Object { $_.Category -ne "Essential" }

    if ($Mode -ne "Scan" -and $disableTargets.Count -gt 0) {
        Write-Host "[Startup Management]" -ForegroundColor Yellow
        Write-Host ""

        foreach ($item in $disableTargets) {
            $shouldDisable = $false

            if ($Mode -eq "Aggressive" -and $item.Category -eq "Optional") {
                $shouldDisable = $true
            }
            elseif ($Mode -eq "Clean") {
                $catLabel = if ($item.Category -eq "Unknown") { "UNKNOWN" } else { $item.Category }
                $response = Read-Host "    Disable '$($item.Name)' [$catLabel]? [y/N]"
                $shouldDisable = $response -match '^[Yy]'
            }

            if ($shouldDisable) {
                try {
                    if ($item.Source -eq "HKCU\Run") {
                        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $item.Name -ErrorAction Stop
                        Write-Host "    Disabled: $($item.Name) (removed from HKCU\Run)" -ForegroundColor Green
                    }
                    elseif ($item.Source -eq "HKLM\Run") {
                        Write-Host "    Skipped: $($item.Name) (HKLM requires admin)" -ForegroundColor Yellow
                    }
                    elseif ($item.Source -eq "Startup Folder") {
                        $filePath = $item.Command
                        if (Test-Path $filePath) {
                            # Move to a disabled subfolder rather than deleting
                            $disabledDir = Join-Path $startupFolder "_disabled"
                            if (-not (Test-Path $disabledDir)) {
                                New-Item -Path $disabledDir -ItemType Directory -Force | Out-Null
                            }
                            Move-Item -Path $filePath -Destination $disabledDir -Force
                            Write-Host "    Disabled: $($item.Name) (moved to _disabled)" -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Host "    Skipped: $($item.Name) (source not modifiable)" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "    Failed to disable $($item.Name)`: $_" -ForegroundColor Red
                }
            }
        }
    }

    Write-Host ""
}
