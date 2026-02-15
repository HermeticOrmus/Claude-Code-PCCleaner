<#
.SYNOPSIS
    Claude-Code-PCCleaner -- Full PC optimization for developers.
.DESCRIPTION
    Orchestrates modular cleanup of disk space, RAM, package caches, build
    artifacts, application caches, startup programs, and OneDrive. Operates
    in three safety tiers: Scan (report only), Clean (interactive), and
    Aggressive (auto-confirm maximum cleanup).
.PARAMETER Scan
    Run all modules in report-only mode. This is the default behavior.
    Nothing is modified on disk or in the registry.
.PARAMETER Clean
    Run selected modules with interactive confirmations before each action.
.PARAMETER Aggressive
    Run all modules with auto-confirmation for maximum cleanup.
.PARAMETER Caches
    Target package manager caches (npm, uv, pip, Go, Cargo).
.PARAMETER Builds
    Target build artifacts and stale dependencies.
.PARAMETER Processes
    Target RAM analysis and process management.
.PARAMETER Apps
    Target browser and Electron app caches.
.PARAMETER OneDrive
    Target OneDrive local cache optimization.
.PARAMETER Startup
    Target startup program audit.
.PARAMETER Verbose
    Enable verbose output with additional detail.
.EXAMPLE
    .\pccleaner.ps1 -Scan
    Full system scan. Safe -- nothing is modified.
.EXAMPLE
    .\pccleaner.ps1 -Clean -Caches
    Clean package manager caches with confirmations.
.EXAMPLE
    .\pccleaner.ps1 -Aggressive
    Maximum cleanup across all modules, auto-confirmed.
#>

[CmdletBinding(DefaultParameterSetName = "ScanMode")]
param(
    [Parameter(ParameterSetName = "ScanMode")]
    [switch]$Scan,

    [Parameter(ParameterSetName = "CleanMode")]
    [switch]$Clean,

    [Parameter(ParameterSetName = "AggressiveMode")]
    [switch]$Aggressive,

    [switch]$Caches,
    [switch]$Builds,
    [switch]$Processes,
    [switch]$Apps,
    [switch]$OneDrive,
    [switch]$Startup
)

# ============================================================
# INITIALIZATION
# ============================================================

$ErrorActionPreference = "Continue"
$scriptRoot = $PSScriptRoot

# Determine mode
$mode = "Scan"  # Default
if ($Clean) { $mode = "Clean" }
if ($Aggressive) { $mode = "Aggressive" }

# Determine which modules to run
$noModuleFlags = -not ($Caches -or $Builds -or $Processes -or $Apps -or $OneDrive -or $Startup)
$runAll = ($mode -eq "Scan" -and $noModuleFlags) -or ($mode -eq "Aggressive") -or $noModuleFlags

$runCaches    = $runAll -or $Caches
$runBuilds    = $runAll -or $Builds
$runProcesses = $runAll -or $Processes
$runApps      = $runAll -or $Apps
$runOneDrive  = $runAll -or $OneDrive
$runStartup   = $runAll -or $Startup

# ============================================================
# LOAD CONFIG
# ============================================================

$configPath = Join-Path $scriptRoot "config\defaults.json"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found at $configPath" -ForegroundColor Red
    Write-Host "Expected: config\defaults.json relative to script location." -ForegroundColor Red
    exit 1
}

try {
    $configJson = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Convert PSCustomObject to hashtable for easier use in modules
    $config = @{
        dry_run               = $configJson.dry_run
        large_file_threshold_mb = $configJson.large_file_threshold_mb
        inactive_project_days = $configJson.inactive_project_days
        temp_age_days         = $configJson.temp_age_days
        exclusions            = @{
            directories = @($configJson.exclusions.directories)
            files       = @($configJson.exclusions.files)
        }
        cache_paths           = @{
            npm   = $configJson.cache_paths.npm
            uv    = $configJson.cache_paths.uv
            pip   = $configJson.cache_paths.pip
            go    = $configJson.cache_paths.go
            cargo = $configJson.cache_paths.cargo
        }
        build_patterns        = @($configJson.build_patterns)
    }
}
catch {
    Write-Host "ERROR: Failed to parse config file: $_" -ForegroundColor Red
    exit 1
}

# Check for local config override
$localConfigPath = Join-Path $scriptRoot "config\local.json"
if (Test-Path $localConfigPath) {
    try {
        $localJson = Get-Content -Path $localConfigPath -Raw | ConvertFrom-Json

        # Override specific values from local config
        if ($null -ne $localJson.large_file_threshold_mb) { $config.large_file_threshold_mb = $localJson.large_file_threshold_mb }
        if ($null -ne $localJson.inactive_project_days) { $config.inactive_project_days = $localJson.inactive_project_days }
        if ($null -ne $localJson.temp_age_days) { $config.temp_age_days = $localJson.temp_age_days }

        Write-Host "  Loaded local config override: $localConfigPath" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  Warning: Failed to parse local config, using defaults." -ForegroundColor Yellow
    }
}

# ============================================================
# LOAD MODULES
# ============================================================

$modulesDir = Join-Path $scriptRoot "modules"

# Dot-source all module files
$moduleFiles = @(
    "disk-audit.ps1",
    "cache-cleaner.ps1",
    "build-cleaner.ps1",
    "process-audit.ps1",
    "app-cleaner.ps1",
    "startup-audit.ps1",
    "onedrive-opt.ps1"
)

foreach ($moduleFile in $moduleFiles) {
    $modulePath = Join-Path $modulesDir $moduleFile
    if (Test-Path $modulePath) {
        . $modulePath
    }
    else {
        Write-Host "  Warning: Module not found: $moduleFile" -ForegroundColor Yellow
    }
}

# ============================================================
# BEFORE METRICS
# ============================================================

$beforeDisk = @{}
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 }
foreach ($drive in $drives) {
    $beforeDisk[$drive.Name] = $drive.Free
}

$beforeRAM = $null
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($osInfo) {
    $beforeRAM = [long]$osInfo.FreePhysicalMemory * 1KB
}

$startTime = Get-Date

# ============================================================
# BANNER
# ============================================================

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "    Claude-Code-PCCleaner" -ForegroundColor Cyan
Write-Host "    Full PC Optimization for Developers" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""

$modeColor = switch ($mode) {
    "Scan"       { "Green" }
    "Clean"      { "Yellow" }
    "Aggressive" { "Red" }
}
$modeLabel = switch ($mode) {
    "Scan"       { "SCAN (report only -- nothing will be modified)" }
    "Clean"      { "CLEAN (interactive -- will confirm before each action)" }
    "Aggressive" { "AGGRESSIVE (auto-confirm -- maximum cleanup)" }
}

Write-Host "  Mode: $modeLabel" -ForegroundColor $modeColor
Write-Host "  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "  User: $env:USERNAME @ $env:COMPUTERNAME" -ForegroundColor DarkGray

$activeModules = @()
if ($runCaches)    { $activeModules += "Caches" }
if ($runBuilds)    { $activeModules += "Builds" }
if ($runProcesses) { $activeModules += "Processes" }
if ($runApps)      { $activeModules += "Apps" }
if ($runOneDrive)  { $activeModules += "OneDrive" }
if ($runStartup)   { $activeModules += "Startup" }

Write-Host "  Modules: $($activeModules -join ', ')" -ForegroundColor DarkGray
Write-Host ""

# Safety warning for aggressive mode
if ($mode -eq "Aggressive") {
    Write-Host "  !! AGGRESSIVE MODE -- All actions will be auto-confirmed !!" -ForegroundColor Red
    Write-Host ""

    $confirm = Read-Host "  Type 'YES' to proceed"
    if ($confirm -ne "YES") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# ============================================================
# EXECUTE MODULES
# ============================================================

$totalFreed = [long]0

# Disk audit always runs first (information only)
if ($runAll) {
    Invoke-DiskAudit -Mode $mode -Config $config
}

# Caches
if ($runCaches) {
    $freed = Invoke-CacheCleaner -Mode $mode -Config $config
    if ($freed) { $totalFreed += $freed }
}

# Build artifacts
if ($runBuilds) {
    $freed = Invoke-BuildCleaner -Mode $mode -Config $config
    if ($freed) { $totalFreed += $freed }
}

# Process audit
if ($runProcesses) {
    Invoke-ProcessAudit -Mode $mode -Config $config
}

# Application caches
if ($runApps) {
    $freed = Invoke-AppCleaner -Mode $mode -Config $config
    if ($freed) { $totalFreed += $freed }
}

# Startup audit (Windows only)
if ($runStartup) {
    Invoke-StartupAudit -Mode $mode -Config $config
}

# OneDrive optimization (Windows only)
if ($runOneDrive) {
    $freed = Invoke-OneDriveOpt -Mode $mode -Config $config
    if ($freed) { $totalFreed += $freed }
}

# ============================================================
# AFTER METRICS & SUMMARY
# ============================================================

$endTime = Get-Date
$elapsed = $endTime - $startTime

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Mode:     $mode" -ForegroundColor $modeColor
Write-Host "  Duration: $([math]::Round($elapsed.TotalSeconds, 1)) seconds" -ForegroundColor DarkGray
Write-Host "  Modules:  $($activeModules -join ', ')" -ForegroundColor DarkGray
Write-Host ""

# Disk delta
if ($mode -ne "Scan") {
    Write-Host "[Disk Space Delta]" -ForegroundColor Yellow
    Write-Host ""

    $drivesAfter = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 }
    foreach ($drive in $drivesAfter) {
        if ($beforeDisk.ContainsKey($drive.Name)) {
            $delta = $drive.Free - $beforeDisk[$drive.Name]
            $deltaSign = if ($delta -ge 0) { "+" } else { "" }
            $deltaColor = if ($delta -gt 0) { "Green" } elseif ($delta -lt 0) { "Red" } else { "DarkGray" }

            Write-Host "  $($drive.Name):\  Before: $(Format-Size $beforeDisk[$drive.Name])  After: $(Format-Size $drive.Free)  Delta: $deltaSign$(Format-Size ([math]::Abs($delta)))" -ForegroundColor $deltaColor
        }
    }

    Write-Host ""

    # RAM delta
    $osInfoAfter = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($osInfoAfter -and $beforeRAM) {
        $afterRAM = [long]$osInfoAfter.FreePhysicalMemory * 1KB
        $ramDelta = $afterRAM - $beforeRAM
        $ramSign = if ($ramDelta -ge 0) { "+" } else { "" }
        $ramColor = if ($ramDelta -gt 0) { "Green" } elseif ($ramDelta -lt 0) { "Red" } else { "DarkGray" }

        Write-Host "[RAM Delta]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Before: $(Format-Size $beforeRAM)  After: $(Format-Size $afterRAM)  Delta: $ramSign$(Format-Size ([math]::Abs($ramDelta)))" -ForegroundColor $ramColor
        Write-Host ""
    }

    # Total freed
    if ($totalFreed -gt 0) {
        Write-Host "[Total Space Freed]" -ForegroundColor Green
        Write-Host ""
        Write-Host "  $(Format-Size $totalFreed)" -ForegroundColor Green
        Write-Host ""
    }
}
else {
    Write-Host "  No changes made (scan mode)." -ForegroundColor Green
    Write-Host "  Run with -Clean or -Aggressive to take action." -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "    Scan complete." -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""
