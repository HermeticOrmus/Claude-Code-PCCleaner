<#
.SYNOPSIS
    RAM and process analysis module for Claude-Code-PCCleaner.
.DESCRIPTION
    Lists top processes by memory usage, groups by name, identifies common
    RAM hogs, shows system RAM overview, and optionally offers to kill
    selected non-essential processes.
#>

# Processes that should NEVER be killed -- system-critical
$script:ProtectedProcesses = @(
    "System", "Idle", "Registry", "smss", "csrss", "wininit", "winlogon",
    "services", "lsass", "svchost", "dwm", "explorer", "fontdrvhost",
    "Memory Compression", "SecurityHealthService", "MsMpEng", "NisSrv",
    "SearchIndexer", "sihost", "taskhostw", "RuntimeBroker", "dllhost",
    "conhost", "ctfmon", "spoolsv", "WmiPrvSE", "audiodg", "dasHost",
    "LsaIso", "sgrmbroker", "SystemSettingsBroker", "TextInputHost",
    "WindowsTerminal", "powershell", "pwsh"
)

# Common RAM hogs that users might want to kill
$script:KnownHogs = @{
    "chrome"          = "Google Chrome"
    "msedge"          = "Microsoft Edge"
    "firefox"         = "Firefox"
    "Teams"           = "Microsoft Teams"
    "Slack"           = "Slack"
    "Discord"         = "Discord"
    "Code"            = "VS Code"
    "Figma"           = "Figma"
    "Spotify"         = "Spotify"
    "node"            = "Node.js"
    "java"            = "Java"
    "python"          = "Python"
    "Electron"        = "Electron App"
    "GitHubDesktop"   = "GitHub Desktop"
    "Postman"         = "Postman"
    "Docker Desktop"  = "Docker Desktop"
}

function Invoke-ProcessAudit {
    <#
    .SYNOPSIS
        Analyzes running processes by memory usage.
    .PARAMETER Mode
        Scan (report only), Clean (interactive kill), or Aggressive (auto-kill non-essential).
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
    Write-Host "  PROCESS AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- System RAM Overview ---
    Write-Host "[System Memory]" -ForegroundColor Yellow
    Write-Host ""

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $totalRAM = [long]$os.TotalVisibleMemorySize * 1KB
        $freeRAM = [long]$os.FreePhysicalMemory * 1KB
        $usedRAM = $totalRAM - $freeRAM
        $usedPercent = [math]::Round(($usedRAM / $totalRAM) * 100, 1)
        $freePercent = [math]::Round(($freeRAM / $totalRAM) * 100, 1)

        $memColor = "Green"
        if ($freePercent -lt 15) { $memColor = "Red" }
        elseif ($freePercent -lt 30) { $memColor = "Yellow" }

        Write-Host "  Total RAM:     $(Format-Size $totalRAM)" -ForegroundColor White
        Write-Host "  Used:          $(Format-Size $usedRAM) ($usedPercent%)" -ForegroundColor $memColor
        Write-Host "  Available:     $(Format-Size $freeRAM) ($freePercent%)" -ForegroundColor $memColor

        # Visual bar
        $barLength = 40
        $usedBars = [math]::Round(($usedPercent / 100) * $barLength)
        $freeBars = $barLength - $usedBars
        $bar = "[" + ("=" * $usedBars) + ("-" * $freeBars) + "]"
        Write-Host "  $bar" -ForegroundColor $memColor
    }
    else {
        Write-Host "  Unable to query system memory." -ForegroundColor Red
    }

    Write-Host ""

    # --- Top 20 Processes by Memory ---
    Write-Host "[Top 20 Processes by Memory]" -ForegroundColor Yellow
    Write-Host ""

    $allProcesses = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 0 } |
        Sort-Object WorkingSet64 -Descending

    $top20 = $allProcesses | Select-Object -First 20

    $processResults = @()
    foreach ($proc in $top20) {
        $isProtected = $script:ProtectedProcesses -contains $proc.ProcessName
        $isKnownHog = $script:KnownHogs.ContainsKey($proc.ProcessName)
        $label = if ($isKnownHog) { $script:KnownHogs[$proc.ProcessName] } else { $proc.ProcessName }

        $processResults += [PSCustomObject]@{
            PID       = $proc.Id
            Name      = $proc.ProcessName
            Label     = $label
            Memory    = Format-Size $proc.WorkingSet64
            MemBytes  = $proc.WorkingSet64
            Protected = $isProtected
            Category  = if ($isProtected) { "System" } elseif ($isKnownHog) { "App" } else { "Other" }
        }
    }

    $processResults |
        Format-Table @(
            @{ Label = "PID"; Expression = { $_.PID }; Width = 8 },
            @{ Label = "Process"; Expression = { $_.Label }; Width = 25 },
            @{ Label = "Memory"; Expression = { $_.Memory }; Width = 12; Alignment = "Right" },
            @{ Label = "Type"; Expression = { $_.Category }; Width = 8 }
        ) -AutoSize | Out-String | Write-Host

    # --- Grouped by Process Name ---
    Write-Host "[Memory by Application (grouped)]" -ForegroundColor Yellow
    Write-Host ""

    $grouped = $allProcesses |
        Group-Object ProcessName |
        ForEach-Object {
            $totalMem = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum
            [PSCustomObject]@{
                Name       = $_.Name
                Instances  = $_.Count
                TotalMem   = Format-Size $totalMem
                TotalBytes = $totalMem
                IsHog      = $script:KnownHogs.ContainsKey($_.Name)
                Protected  = $script:ProtectedProcesses -contains $_.Name
            }
        } |
        Sort-Object TotalBytes -Descending |
        Select-Object -First 20

    $grouped |
        Format-Table @(
            @{ Label = "Application"; Expression = { $_.Name }; Width = 25 },
            @{ Label = "Instances"; Expression = { $_.Instances }; Width = 10; Alignment = "Right" },
            @{ Label = "Total Memory"; Expression = { $_.TotalMem }; Width = 14; Alignment = "Right" }
        ) -AutoSize | Out-String | Write-Host

    # --- Killable Suggestions ---
    $killable = $grouped | Where-Object { -not $_.Protected -and $_.TotalBytes -gt 100MB }

    if ($killable.Count -gt 0) {
        Write-Host "[Killable Processes (> 100 MB, non-system)]" -ForegroundColor Yellow
        Write-Host ""

        $killable |
            Format-Table @(
                @{ Label = "Application"; Expression = { $_.Name }; Width = 25 },
                @{ Label = "Instances"; Expression = { $_.Instances }; Width = 10; Alignment = "Right" },
                @{ Label = "Total Memory"; Expression = { $_.TotalMem }; Width = 14; Alignment = "Right" }
            ) -AutoSize | Out-String | Write-Host

        $totalKillable = ($killable | Measure-Object -Property TotalBytes -Sum).Sum
        Write-Host "  Potential RAM recovery: $(Format-Size $totalKillable)" -ForegroundColor White
        Write-Host ""

        # Kill processes in Clean or Aggressive mode
        if ($Mode -ne "Scan") {
            foreach ($proc in $killable) {
                $shouldKill = $false

                if ($Mode -eq "Aggressive") {
                    $shouldKill = $true
                }
                else {
                    $response = Read-Host "  Kill $($proc.Name) ($($proc.Instances) instances, $($proc.TotalMem))? [y/N]"
                    $shouldKill = $response -match '^[Yy]'
                }

                if ($shouldKill) {
                    try {
                        Get-Process -Name $proc.Name -ErrorAction Stop | Stop-Process -Force -ErrorAction Stop
                        Write-Host "    Killed: $($proc.Name) -- freed ~$($proc.TotalMem)" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "    Failed to kill $($proc.Name)`: $_" -ForegroundColor Red
                    }
                }
                else {
                    Write-Host "    Skipped: $($proc.Name)" -ForegroundColor DarkGray
                }
            }
        }
    }
    else {
        Write-Host "  No significant killable processes found." -ForegroundColor Green
    }

    Write-Host ""
}
