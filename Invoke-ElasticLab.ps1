#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Invoke-ElasticLab.ps1 -- Master Elastic Lab Driver

.DESCRIPTION
    Single entry point for the Elastic lab. Loads config and the ElasticLab
    module, then calls the appropriate invoke function for the requested phase.

    All configuration lives in config\LabConfig.psd1 -- edit that file, not this one.

    Phases:

      Elastic  -- Core stack: Elasticsearch + Kibana + ELSER + Ollama
      Fleet    -- Fleet Server + monitored containers  (requires Elastic)
      VMs      -- Windows + Linux VMs with Elastic Agent  (requires Fleet)
      All      -- Runs Elastic -> Fleet -> VMs in sequence  (default)
      Cleanup  -- Tears everything down

    Examples:

      # Full build -- all three phases in order (default)
      .\Invoke-ElasticLab.ps1

      # Core stack only
      .\Invoke-ElasticLab.ps1 -Phase Elastic

      # Add Fleet on top of an already-running Elastic stack
      .\Invoke-ElasticLab.ps1 -Phase Fleet

      # Provision VMs after Fleet is already running
      .\Invoke-ElasticLab.ps1 -Phase VMs

      # Tear everything down
      .\Invoke-ElasticLab.ps1 -Phase Cleanup

.PARAMETER Phase
    Which phase to run. Defaults to 'All'.
    Valid values: Elastic, Fleet, VMs, All, Cleanup

.PARAMETER Stack
    Override the StackMode setting in LabConfig.psd1 without editing the file.
    Valid values: 8, 9, Both
    If omitted, uses whatever StackMode is set to in LabConfig.psd1.

    Examples:
      .\Invoke-ElasticLab.ps1 -Stack 8           # ES8 only, all phases
      .\Invoke-ElasticLab.ps1 -Stack 9 -Phase Elastic  # ES9 only, Elastic phase

.NOTES
    Run PowerShell as Administrator.
    Configuration : config\LabConfig.psd1
    Module        : modules\ElasticLab.psd1

    PREREQUISITES -- All phases:
      - PowerShell 5.1 or later (run as Administrator)
      - Docker Desktop installed and running
        https://www.docker.com/products/docker-desktop/
      - WSL2 enabled (required by Docker Desktop)
        wsl --install   (then reboot if prompted)

    PREREQUISITES -- VMs phase only:
      - Vagrant installed
        https://www.vagrantup.com/downloads
        (installed automatically if winget is available)

      - VagrantProvider in LabConfig.psd1 (default: "auto"):

          "auto"       -- Detects Windows edition at runtime.
                          Pro/Enterprise/Education -> Hyper-V.
                          Home -> VirtualBox.

          "hyperv"     -- Force Hyper-V. Requires Pro/Enterprise/Education.
                          Requires Hyper-V Management Tools (PowerShell module).
                          Enable via: optionalfeatures.exe -> Hyper-V ->
                          check 'Hyper-V Management Tools' -> reboot.

          "virtualbox" -- Force VirtualBox. Works on all Windows editions.
                          VirtualBox installed automatically via winget.
#>

[CmdletBinding()]
param(
    [ValidateSet("Elastic", "Fleet", "VMs", "All", "Cleanup")]
    [string]$Phase = "All",

    # Override StackMode from LabConfig.psd1 at runtime without editing the file.
    #   8    -- Elasticsearch 8 only
    #   9    -- Elasticsearch 9 only
    #   Both -- Both stacks (default -- reads from LabConfig.psd1)
    [ValidateSet("8", "9", "Both", "")]
    [string]$Stack = ""
)

$ErrorActionPreference = "Stop"

# -- Resolve script directory --------------------------------------------------
$scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Definition
}

# -- Start timing --------------------------------------------------------------
$startTime = Get-Date

# -- Load configuration --------------------------------------------------------
$configPath = Join-Path $scriptDir "config\LabConfig.psd1"
if (-not (Test-Path $configPath)) {
    Write-Host "`n  [ERR] LabConfig.psd1 not found at: $configPath" -ForegroundColor Red
    Write-Host "  Ensure config\LabConfig.psd1 exists alongside this script." -ForegroundColor Red
    exit 1
}
$rawConfig = Import-PowerShellDataFile -Path $configPath

# -- Apply runtime Stack override ----------------------------------------------
# -Stack parameter overrides StackMode in LabConfig.psd1 without editing the file
if ($Stack -ne "") {
    $rawConfig = $rawConfig.Clone()
    $rawConfig["StackMode"] = $Stack
    Write-Host "  [--]  Stack override: StackMode set to '$Stack'" -ForegroundColor DarkGray
}

# -- Load module ---------------------------------------------------------------
$modulePath = Join-Path $scriptDir "modules\ElasticLab.psd1"
if (-not (Test-Path $modulePath)) {
    Write-Host "`n  [ERR] ElasticLab module not found at: $modulePath" -ForegroundColor Red
    Write-Host "  Ensure the modules\ subfolder sits alongside this script." -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force

# -- Resolve config ------------------------------------------------------------
$config = Resolve-LabConfig -Config $rawConfig

# -- Start transcript ----------------------------------------------------------
# Log goes to LabRoot\logs\ so it's co-located with the lab and managed by cleanup
$logDir  = Join-Path $config.LabRoot "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir "ElasticLab-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')-$Phase.log"
Start-Transcript -Path $logFile -Append | Out-Null
Write-Host "`n  [$(Get-Date -Format 'HH:mm:ss')]  ElasticLab starting -- Phase: $Phase" -ForegroundColor Cyan
Write-Host "  Log file: $logFile" -ForegroundColor DarkGray

# -- Dispatch to the requested phase ------------------------------------------
switch ($Phase) {
    "Elastic" {
        [hashtable]$config = Invoke-ElasticLabBuild -Config $config
    }
    "Fleet" {
        Invoke-ElasticFleetBuild          -Config $config
    }
    "VMs" {
        Invoke-ElasticVMBuild             -Config $config
    }
    "All" {
        [hashtable]$config = Invoke-ElasticLabBuild -Config $config
        Invoke-ElasticFleetBuild -Config $config
        Invoke-ElasticVMBuild   -Config $config
    }
    "Cleanup" {
        Invoke-ElasticLabCleanup          -Config $config
    }
}

# -- End-of-run summary --------------------------------------------------------
$endTime = Get-Date
$elapsed = $endTime - $startTime
$elapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds

Write-Host "`n"
Write-Host "  +==============================================+" -ForegroundColor Cyan
Write-Host "  |   ElasticLab Run Summary                    |" -ForegroundColor Cyan
Write-Host "  +==============================================+" -ForegroundColor Cyan
Write-Host "  Phase     : $Phase" -ForegroundColor White
Write-Host "  Stack     : $($config.StackMode)" -ForegroundColor White
Write-Host "  Started   : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host "  Finished  : $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host "  Elapsed   : $elapsedStr" -ForegroundColor White
Write-Host "  Log file  : $logFile" -ForegroundColor White

# Replay warnings and errors
$entries = Get-LabLogEntries
$warns   = @($entries | Where-Object { $_.Level -eq "WARN"  })
$errors  = @($entries | Where-Object { $_.Level -eq "ERROR" })

if ($errors.Count -eq 0 -and $warns.Count -eq 0) {
    Write-Host "`n  [OK]  No warnings or errors -- clean run" -ForegroundColor Green
} else {
    if ($errors.Count -gt 0) {
        Write-Host "`n  +==============================================+" -ForegroundColor Red
        Write-Host "  |   ERRORS ($($errors.Count))                               |" -ForegroundColor Red
        Write-Host "  +==============================================+" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host "  [ERR] [$($e.Time)]  $($e.Message)" -ForegroundColor Red
        }
    }
    if ($warns.Count -gt 0) {
        Write-Host "`n  +==============================================+" -ForegroundColor Yellow
        Write-Host "  |   WARNINGS ($($warns.Count))                             |" -ForegroundColor Yellow
        Write-Host "  +==============================================+" -ForegroundColor Yellow
        foreach ($w in $warns) {
            Write-Host "  [!!]  [$($w.Time)]  $($w.Message)" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n  +==============================================+" -ForegroundColor Cyan
Write-Host ""

Stop-Transcript | Out-Null
