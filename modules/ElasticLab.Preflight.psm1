# =============================================================================
# ElasticLab.Preflight.psm1
# Pre-flight checks: Docker, WSL2, Ollama installation, and version resolution.
# Must run before any other lab setup step.
# =============================================================================

function Invoke-LabPreflight {
    <#
    .SYNOPSIS
        Validates the environment and resolves versions. Returns an enriched
        config hashtable with ES8Version/ES9Version updated to the chosen values.
        Exits the script if any hard requirement is unmet.
    #>
    param([hashtable]$Config)

    Write-LabStep "Pre-flight -- Validating Environment"

    # -- Validate StackMode ----------------------------------------------------
    if ($Config.StackMode -notin @("8","9","Both")) {
        Write-LabFail "Invalid StackMode '$($Config.StackMode)'. Must be '8', '9', or 'Both'."
        exit 1
    }

    # -- Validate AITool -------------------------------------------------------
    if ($Config.AITool -notin @("ELSER","Ollama","Both","None")) {
        Write-LabFail "Invalid AITool '$($Config.AITool)'. Must be 'ELSER', 'Ollama', 'Both', or 'None'."
        exit 1
    }

    # -- Docker CLI ------------------------------------------------------------
    if (-not (Test-LabCommandExists "docker")) {
        Write-LabFail "Docker CLI not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop"
        exit 1
    }

    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LabFail "Docker Desktop is not running. Start it and re-run."
        exit 1
    }
    Write-LabOK "Docker Desktop is running"

    docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LabFail "Docker Compose v2 not found. Update Docker Desktop."
        exit 1
    }
    Write-LabOK "Docker Compose v2 available"

    # -- WSL2 ------------------------------------------------------------------
    wsl --status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-LabWarn "WSL2 status check inconclusive -- continuing" }
    else                     { Write-LabOK   "WSL2 is available" }

    # -- Ollama install (if needed) --------------------------------------------
    if ($Config.SetupOllama) {
        _Install-Ollama -Config $Config
    }

    Write-LabOK "Pre-flight passed -- StackMode: $($Config.StackMode) | AI: $($Config.AITool)"

    # -- Version resolution ----------------------------------------------------
    $Config = _Resolve-ElasticVersions -Config $Config

    return $Config
}

# -- Private: Ollama install ---------------------------------------------------

function _Install-Ollama {
    param([hashtable]$Config)

    $ollamaExe   = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    $ollamaFound = (Test-Path $ollamaExe) -or (Test-LabCommandExists "ollama")

    if (-not $ollamaFound) {
        Write-Host "`n  [Ollama] Not found -- downloading and installing..." -ForegroundColor White

        $installerPath = $Config.OllamaInstallerPath

        # Ensure installer directory exists
        $installerDir = Split-Path $installerPath -Parent
        if (-not (Test-Path $installerDir)) {
            New-Item -ItemType Directory -Path $installerDir -Force | Out-Null
        }

        if (Test-Path $installerPath) {
            Write-LabOK "[Ollama] Using cached installer: $installerPath ($([Math]::Round((Get-Item $installerPath).Length / 1MB, 1)) MB)"
        } else {
            try {
                Write-Host "  [Ollama] Downloading installer from ollama.com..." -ForegroundColor White
                $null = Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" `
                    -OutFile $installerPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                Write-LabOK "[Ollama] Downloaded ($([Math]::Round((Get-Item $installerPath).Length / 1MB, 1)) MB)"
            } catch {
                Write-LabFail "[Ollama] Failed to download installer: $_"
                Write-LabFail "Download manually from https://ollama.com/download and re-run."
                exit 1
            }
        }

        # Inno Setup silent install -- launch detached, poll for exe
        Write-Host "  [Ollama] Running silent install (30-60 seconds)..." -ForegroundColor White
        $null = Start-Process -FilePath $installerPath `
            -ArgumentList "/VERYSILENT /NORESTART /CLOSEAPPLICATIONS" `
            -WindowStyle Hidden

        $installWait = 0
        while (-not (Test-Path $ollamaExe) -and $installWait -lt 90) {
            # Kill auto-launched Ollama process continuously during install
            Get-Process -Name "ollama" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            $installWait += 3
            Write-Host "  [${installWait}s] Waiting for ollama.exe..." -ForegroundColor DarkGray
        }

        if (Test-Path $ollamaExe) {
            Write-LabOK "[Ollama] Installation complete"
        } else {
            Write-LabFail "[Ollama] ollama.exe not found after ${installWait}s -- install may have failed"
            exit 1
        }

        # Final sweep and PATH refresh
        Get-Process -Name "ollama" -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")

        Write-LabOK "[Ollama] Installer kept at $installerPath for future re-runs"

    } else {
        Write-LabOK "[Ollama] Already installed -- skipping"
    }

    # Ensure exe is on PATH for this session
    if (-not (Test-LabCommandExists "ollama") -and (Test-Path $ollamaExe)) {
        $env:Path += ";$env:LOCALAPPDATA\Programs\Ollama"
        Write-LabInfo "[Ollama] Added install dir to session PATH"
    }

    # Kill any stray processes, then start service cleanly
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Host "`n  [Ollama] Starting service..." -ForegroundColor White
    $svc = Get-Service -Name "ollama" -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne "Running") {
            $null = Start-Service -Name "ollama" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 4
        }
        Write-LabOK "[Ollama] Service status: $((Get-Service -Name 'ollama' -ErrorAction SilentlyContinue).Status)"
    } else {
        Write-LabInfo "[Ollama] No Windows service -- starting in background"
        $null = Start-Process -FilePath "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" `
            -ArgumentList "serve" -WindowStyle Hidden `
            -RedirectStandardOutput "$env:TEMP\ollama-serve.log" `
            -RedirectStandardError  "$env:TEMP\ollama-serve-err.log"
        Start-Sleep -Seconds 5
    }
}

# -- Private: version resolution -----------------------------------------------

function _Resolve-ElasticVersions {
    param([hashtable]$Config)

    Write-Host "`n  Checking latest Elastic release versions..." -ForegroundColor White

    function _Get-LatestVersion([string]$Major) {
        try {
            $resp = Invoke-WebRequest `
                -Uri "https://api.github.com/repos/elastic/elasticsearch/releases" `
                -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $releases = $resp.Content | ConvertFrom-Json
            $latest = $releases |
                Where-Object { -not $_.prerelease -and -not $_.draft -and $_.tag_name -match "^v$Major\." } |
                Sort-Object { [Version]($_.tag_name -replace '^v','') } -Descending |
                Select-Object -First 1
            if ($latest) { return ($latest.tag_name -replace '^v','') }
        } catch {}
        return $null
    }

    # Only fetch versions for active stacks
    $latest8 = if ($Config.SetupES8) { _Get-LatestVersion "8" } else { $null }
    $latest9 = if ($Config.SetupES9) { _Get-LatestVersion "9" } else { $null }

    $anyLatestFound = ($Config.SetupES8 -and $latest8) -or ($Config.SetupES9 -and $latest9)

    if ($anyLatestFound) {
        Write-Host ""
        Write-Host "  Latest stable versions found:" -ForegroundColor Cyan
        if ($Config.SetupES8 -and $latest8) { Write-Host "    8.x : $latest8" -ForegroundColor Cyan }
        if ($Config.SetupES9 -and $latest9) { Write-Host "    9.x : $latest9" -ForegroundColor Cyan }
        Write-Host ""
        Write-Host "  Config-defined versions:" -ForegroundColor Gray
        if ($Config.SetupES8) { Write-Host "    8.x : $($Config.ES8Version)" -ForegroundColor Gray }
        if ($Config.SetupES9) { Write-Host "    9.x : $($Config.ES9Version)" -ForegroundColor Gray }
        Write-Host ""

        $default = if ($Config.VersionMode -eq "latest") { "latest" } else { "config" }
        $choice  = Read-Host "  Use which versions? (latest / config) [default: $default]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $default }

        if ($choice -eq "latest") {
            if ($Config.SetupES8 -and $latest8) { $Config.ES8Version = $latest8 }
            if ($Config.SetupES9 -and $latest9) { $Config.ES9Version = $latest9 }
            Write-LabOK "Using latest: ES8=$($Config.ES8Version)  ES9=$($Config.ES9Version)"
        } else {
            Write-LabOK "Using config: ES8=$($Config.ES8Version)  ES9=$($Config.ES9Version)"
        }
    } else {
        Write-LabWarn "Could not fetch latest versions from GitHub -- using config-defined versions"
        if ($Config.SetupES8) { Write-LabWarn "  ES8=$($Config.ES8Version)" }
        if ($Config.SetupES9) { Write-LabWarn "  ES9=$($Config.ES9Version)" }
    }

    # Rebuild ActiveStacks with resolved versions
    foreach ($stack in $Config.ActiveStacks) {
        if ($stack.Label -eq "ES8") { $stack.Version = $Config.ES8Version }
        if ($stack.Label -eq "ES9") { $stack.Version = $Config.ES9Version }
    }

    return $Config
}

Export-ModuleMember -Function Invoke-LabPreflight
