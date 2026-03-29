# =============================================================================
# ElasticLab.Cleanup.psm1
# Inventory-first lab teardown.
# Detects what is present before prompting for anything.
# Only prompts to remove things that actually exist.
# Preserves ELSER model files and Ollama installer if the user chooses to keep
# them, and handles the lab folder removal accordingly.
# =============================================================================

function Invoke-LabCleanup {
    <#
    .SYNOPSIS
        Tears down the Elastic lab. Inventories all components first, then
        prompts only for items that are actually present. Large downloadable
        artifacts (ELSER model files, Ollama installer) can be kept to avoid
        re-downloading on the next test cycle.
    #>
    param([hashtable]$Config)

    # -- Pre-flight ------------------------------------------------------------
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n  [ERR] Docker Desktop is not running. Start it and re-run." -ForegroundColor Red
        exit 1
    }

    # -- Inventory -------------------------------------------------------------
    Write-LabStep "Inventory -- Scanning for Lab Components"

    $inv = _Get-LabInventory -Config $Config

    # -- Nothing found -- exit early --------------------------------------------
    $anythingFound = $inv.Containers -or $inv.Volumes -or $inv.Networks -or
                     $inv.Images -or $inv.ComposeProjects -or
                     $inv.VagrantDirs -or $inv.HyperVVMs -or
                     $inv.VagrantBoxes -or $inv.AgentCacheFiles -or
                     $inv.ElserFilesOnDisk -or $inv.OllamaInstalled -or
                     $inv.OllamaInstallerFound -or $inv.OllamaDataPaths -or $inv.LabFolderExists

    Write-Host "`n"
    Write-Host "  +==============================================+" -ForegroundColor Red
    Write-Host "  |      ELASTIC HOME LAB -- FULL CLEANUP         |" -ForegroundColor Red
    Write-Host "  |   All [>>] items above will be processed.    |" -ForegroundColor Red
    Write-Host "  |   Optional items will be prompted below.     |" -ForegroundColor Red
    Write-Host "  |   This action cannot be undone.              |" -ForegroundColor Red
    Write-Host "  +==============================================+" -ForegroundColor Red
    Write-Host ""

    if (-not $anythingFound) {
        Write-Host "  Nothing found to clean up -- lab already fully removed." -ForegroundColor Green
        return
    }

    $confirm = Read-Host "  Type YES to proceed"
    if ($confirm -ne "YES") {
        Write-Host "`n  Cleanup cancelled." -ForegroundColor Yellow
        return
    }

    # -- Step 1: Remove inference endpoints -----------------------------------
    _Remove-InferenceEndpoints -Config $Config -Inv $inv

    # -- Step 2: docker compose down -v ---------------------------------------
    _Remove-Stacks -Config $Config -Inv $inv

    # -- Step 3: Force-remove lingering containers -----------------------------
    _Remove-Containers -Inv $inv

    # -- Step 4: Remove volumes ------------------------------------------------
    _Remove-Volumes -Inv $inv

    # -- Step 5: Remove networks -----------------------------------------------
    _Remove-Networks -Inv $inv

    # -- Step 6: Remove Docker images (optional) -------------------------------
    _Remove-Images -Inv $inv

    # -- Step 7: Remove ELSER model files (optional, preservable) -------------
    $keepElser = _Remove-ElserFiles -Config $Config -Inv $inv

    # -- Step 8: Remove Ollama (optional, installer preservable) --------------
    _Remove-Ollama -Config $Config -Inv $inv

    # -- Step 8b: Vagrant box cache (optional, kept by default) ---------------
    _Remove-VagrantBoxes -Config $Config -Inv $inv

    # -- Step 8c: Agent installer cache (optional, kept by default) -----------
    _Remove-AgentCache -Config $Config -Inv $inv

    # -- Step 9: Remove VMs BEFORE lab folder -- vagrant destroy needs Vagrantfiles
    _Remove-VMs -Config $Config -Inv $inv

    # -- Step 10: Remove lab folder (smart -- honours kept artifacts) -----------
    _Remove-LabFolder -Config $Config -Inv $inv -KeepElser $keepElser

    # -- Step 11: Verify -------------------------------------------------------
    _Show-CleanupVerification -Config $Config -Inv $inv
}

# =============================================================================
# Private -- Inventory
# =============================================================================

function _Get-LabInventory {
    param([hashtable]$Config)

    $inv = @{}

    # Containers -- ES stack + Fleet stack
    $allContainers     = docker ps -a --format "{{.Names}}" 2>&1
    $labContainerNames = @(
        "es8","kibana8","elser-repo",
        "es9","kibana9","elser-repo9",
        "fleet8","linux8","agent8",
        "fleet9","linux9","agent9"
    )
    $inv.Containers    = $labContainerNames | Where-Object { $allContainers -contains $_ }
    if ($inv.Containers) { foreach ($c in $inv.Containers) { Write-LabFound "Container: $c" } }
    else                 { Write-LabMissing "No lab containers found" }

    # Volumes -- ES stack only (Fleet uses the ES network, no separate volumes)
    $allVolumes        = docker volume ls --format "{{.Name}}" 2>&1
    $labVolumeNames    = @("elastic8_es8-data","elastic9_es9-data")
    $inv.Volumes       = $labVolumeNames | Where-Object { $allVolumes -contains $_ }
    if ($inv.Volumes)  { foreach ($v in $inv.Volumes) { Write-LabFound "Volume: $v" } }
    else               { Write-LabMissing "No lab volumes found" }

    # Networks
    $allNetworks       = docker network ls --format "{{.Name}}" 2>&1
    $labNetworkNames   = @("elastic8_elastic8-net","elastic9_elastic9-net")
    $inv.Networks      = $labNetworkNames | Where-Object { $allNetworks -contains $_ }
    if ($inv.Networks) { foreach ($n in $inv.Networks) { Write-LabFound "Network: $n" } }
    else               { Write-LabMissing "No lab networks found" }

    # Docker images -- ES stack + Fleet/Agent + nginx
    $allImages         = docker images --format "{{.Repository}}:{{.Tag}}" 2>&1
    $reg               = $Config.DockerRegistry
    $labImageNames     = @(
        "$reg/elasticsearch/elasticsearch:$($Config.ES8Version)",
        "$reg/kibana/kibana:$($Config.ES8Version)",
        "$reg/elasticsearch/elasticsearch:$($Config.ES9Version)",
        "$reg/kibana/kibana:$($Config.ES9Version)",
        "$reg/elastic-agent/elastic-agent:$($Config.ES8Version)",
        "$reg/elastic-agent/elastic-agent:$($Config.ES9Version)",
        "nginx:alpine",
        $Config.FleetLinuxImage
    )
    $inv.Images        = $labImageNames | Where-Object { $allImages -contains $_ }
    if ($inv.Images) {
        $inv.ImageSizeEst = ($inv.Images.Count * 1.2).ToString("0.0")
        foreach ($i in $inv.Images) { Write-LabFound "Image: $i" }
        Write-LabInfo "Estimated image size: ~$($inv.ImageSizeEst) GB"
    } else { Write-LabMissing "No lab Docker images found" }

    # Compose project directories present on disk
    $inv.ComposeProjects = @("elastic8","elastic9","fleet8","fleet9") | Where-Object {
        Test-Path (Join-Path $Config.LabRoot "$_\docker-compose.yml")
    }
    foreach ($p in $inv.ComposeProjects) { Write-LabFound "Compose project: $p" }

    # ELSER model files
    $inv.ElserFilesOnDisk = $false
    $inv.ElserFileSizeMB  = 0
    if (Test-Path $Config.ElserModelDir) {
        $files = Get-ChildItem -Path $Config.ElserModelDir -ErrorAction SilentlyContinue
        if ($files) {
            $inv.ElserFilesOnDisk = $true
            $inv.ElserFileSizeMB  = [Math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
            Write-LabFound "ELSER model files: $($Config.ElserModelDir) ($($inv.ElserFileSizeMB) MB total)"
            foreach ($f in $files) {
                Write-LabFound "  $($f.Name) ($([Math]::Round($f.Length / 1MB, 1)) MB)"
            }
        } else { Write-LabMissing "ELSER model directory exists but is empty" }
    } else { Write-LabMissing "ELSER model files not found: $($Config.ElserModelDir)" }

    # Ollama
    $ollamaExePath        = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    $inv.OllamaExePath    = $ollamaExePath
    $inv.OllamaInstalled  = (Test-Path $ollamaExePath) -or [bool](Get-Command ollama -ErrorAction SilentlyContinue)
    $inv.OllamaExe        = if (Test-Path $ollamaExePath) { $ollamaExePath } else { "ollama" }
    $inv.OllamaSvc        = Get-Service -Name "ollama" -ErrorAction SilentlyContinue
    $inv.OllamaModelFound = $false

    if ($inv.OllamaInstalled) {
        Write-LabFound "Ollama installed: $ollamaExePath"
        if ($inv.OllamaSvc) { Write-LabFound "Ollama service: $($inv.OllamaSvc.Status)" }

        $ollamaRunning = $false
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" `
                -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $ollamaRunning = ($r.StatusCode -eq 200)
        } catch {}

        if ($ollamaRunning) {
            $modelList = & $inv.OllamaExe list 2>&1
            if ($modelList -match $Config.OllamaModel) {
                $inv.OllamaModelFound = $true
                Write-LabFound "Ollama model pulled: $($Config.OllamaModel)"
            } else {
                Write-LabMissing "Ollama model not pulled: $($Config.OllamaModel)"
            }
        } else {
            Write-LabInfo "Ollama service not running -- cannot check pulled models"
        }
    } else {
        Write-LabMissing "Ollama not installed"
    }

    # Ollama cached installer
    $inv.OllamaInstallerFound  = Test-Path $Config.OllamaInstallerPath
    $inv.OllamaInstallerSizeMB = 0
    if ($inv.OllamaInstallerFound) {
        $inv.OllamaInstallerSizeMB = [Math]::Round((Get-Item $Config.OllamaInstallerPath).Length / 1MB, 1)
        Write-LabFound "Ollama cached installer: $($Config.OllamaInstallerPath) ($($inv.OllamaInstallerSizeMB) MB)"
    } else {
        Write-LabMissing "Ollama cached installer not found: $($Config.OllamaInstallerPath)"
    }

    # Ollama data folders
    $ollamaDataPaths     = @("$env:USERPROFILE\.ollama","$env:LOCALAPPDATA\Ollama","$env:LOCALAPPDATA\Programs\Ollama")
    $inv.OllamaDataPaths = $ollamaDataPaths | Where-Object { Test-Path $_ }
    foreach ($p in $inv.OllamaDataPaths) { Write-LabFound "Ollama data folder: $p" }

    # Lab folder
    $inv.LabFolderExists = Test-Path $Config.LabRoot
    if ($inv.LabFolderExists) {
        Write-LabFound "Lab folder: $($Config.LabRoot)"
        $logDir = Join-Path $Config.LabRoot "logs"
        if (Test-Path $logDir) {
            $logFiles = Get-ChildItem $logDir -File -ErrorAction SilentlyContinue
            if ($logFiles) {
                $logMB = [Math]::Round(($logFiles | Measure-Object Length -Sum).Sum / 1MB, 1)
                Write-LabFound "  Log files: $logDir ($($logFiles.Count) files, $logMB MB)"
            }
        }
    }
    else { Write-LabMissing "Lab folder not found: $($Config.LabRoot)" }

    # Vagrant VMs -- check for Vagrantfiles using Config.VMDefs derived paths
    $inv.VagrantDirs = @()
    if ($Config.VMDefs) {
        $inv.VagrantDirs = $Config.VMDefs | Where-Object {
            Test-Path (Join-Path $_.Dir "Vagrantfile")
        } | ForEach-Object { $_.Dir }
    }
    foreach ($d in $inv.VagrantDirs) { Write-LabFound "Vagrant VM dir: $d" }

    # Hyper-V VMs -- use VMName from Config.VMDefs
    $inv.HyperVVMs = @()
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        if ($Config.VMDefs) {
            $inv.HyperVVMs = $Config.VMDefs | Where-Object {
                Get-VM -Name $_.VMName -ErrorAction SilentlyContinue
            } | ForEach-Object { $_.VMName }
        }
        foreach ($vm in $inv.HyperVVMs) { Write-LabFound "Hyper-V VM: $vm" }
    }
    if (-not $inv.VagrantDirs -and -not $inv.HyperVVMs) {
        Write-LabMissing "No lab VMs found"
    }

    # Vagrant box cache -- stored in LabRoot\artifacts\.vagrant.d\boxes\
    # Gets a keep/remove prompt -- boxes are large (~6 GB Windows, ~600 MB Linux)
    $vagrantBoxDir       = Join-Path $Config.VagrantHome "boxes"
    $inv.VagrantBoxDir   = $vagrantBoxDir
    $inv.VagrantBoxes    = @()
    if (Test-Path $vagrantBoxDir) {
        $inv.VagrantBoxes = Get-ChildItem $vagrantBoxDir -Directory -ErrorAction SilentlyContinue
        if ($inv.VagrantBoxes) {
            $totalMB = [Math]::Round((Get-ChildItem $vagrantBoxDir -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1MB, 0)
            Write-LabFound "Vagrant box cache: $vagrantBoxDir ($($inv.VagrantBoxes.Count) box(es), $totalMB MB)"
            foreach ($b in $inv.VagrantBoxes) {
                $boxMB = [Math]::Round((Get-ChildItem $b.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum / 1MB, 0)
                Write-LabFound "  $($b.Name) ($boxMB MB)"
            }
        } else {
            Write-LabMissing "Vagrant box cache empty: $vagrantBoxDir"
        }
    } else {
        Write-LabMissing "Vagrant box cache not found: $vagrantBoxDir"
    }

    # Agent installer cache -- stored in LabRoot\artifacts\agent-installers\
    # Gets a keep/remove prompt -- ~500 MB per version pair
    $inv.AgentCacheDir   = $Config.AgentInstallerCache
    $inv.AgentCacheFiles = @()
    if (Test-Path $Config.AgentInstallerCache) {
        $inv.AgentCacheFiles = Get-ChildItem $Config.AgentInstallerCache -ErrorAction SilentlyContinue
        $totalMB = [Math]::Round(($inv.AgentCacheFiles | Measure-Object Length -Sum).Sum / 1MB, 0)
        Write-LabFound "Agent installer cache: $($Config.AgentInstallerCache) ($($inv.AgentCacheFiles.Count) files, $totalMB MB)"
        foreach ($f in $inv.AgentCacheFiles) {
            Write-LabFound "  $($f.Name) ($([Math]::Round($f.Length/1MB,0)) MB)"
        }
    } else {
        Write-LabMissing "Agent installer cache not found: $($Config.AgentInstallerCache)"
    }

    # ES reachability (for endpoint cleanup while stack is still up)
    $inv.ES8Reachable = Test-LabElasticHealth -Port $Config.ES8Port -Password $Config.ES8Password
    if ($inv.ES8Reachable) {
        Write-LabFound "Elasticsearch 8.x reachable -- inference endpoints can be removed"
    } else {
        Write-LabInfo "Elasticsearch 8.x not reachable -- endpoint cleanup will be skipped"
    }

    return $inv
}

# =============================================================================
# Private -- Removal steps
# =============================================================================

function _Remove-InferenceEndpoints {
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 1 -- Remove AI Inference Endpoints"

    if (-not $Inv.ES8Reachable) {
        Write-LabInfo "Elasticsearch 8.x not reachable -- skipping (wiped with volumes)"
        return
    }

    foreach ($ep in @(
        @{ Label="ELSER";                    Method="DELETE"; Uri="http://localhost:$($Config.ES8Port)/_inference/sparse_embedding/$($Config.ElserInferenceId)" },
        @{ Label="Ollama (completion)";      Method="DELETE"; Uri="http://localhost:$($Config.ES8Port)/_inference/completion/$($Config.OllamaInferenceId)" },
        @{ Label="Ollama (chat_completion)"; Method="DELETE"; Uri="http://localhost:$($Config.ES8Port)/_inference/chat_completion/$($Config.OllamaInferenceId)" },
        @{ Label="ELSER deployment stop";    Method="POST";   Uri="http://localhost:$($Config.ES8Port)/_ml/trained_models/$($Config.ElserModelId)/deployment/_stop" }
    )) {
        $r = Invoke-LabElasticApi -Method $ep.Method -Uri $ep.Uri -Password $Config.ES8Password
        if ($r -and $r.StatusCode -eq 200) { Write-LabOK "Removed: $($ep.Label)" }
        else                               { Write-LabInfo "Not found or already removed: $($ep.Label)" }
    }
}

function _Remove-Stacks {
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 2 -- Stop and Remove Containers + Volumes"

    if (-not ($Inv.Containers -or $Inv.Volumes -or $Inv.ComposeProjects)) {
        Write-LabInfo "No lab containers, volumes, or compose projects -- skipping"
        return
    }

    # Tear down Fleet stacks first (they depend on ES network, must go before ES)
    foreach ($stack in @("fleet8","fleet9")) {
        $stackPath = Join-Path $Config.LabRoot $stack
        if (Test-Path (Join-Path $stackPath "docker-compose.yml")) {
            Write-Host "`n  Tearing down $stack..." -ForegroundColor White
            Push-Location $stackPath
            docker compose --profile agent down --remove-orphans 2>&1 | ForEach-Object { Write-LabInfo $_ }
            if ($LASTEXITCODE -eq 0) { Write-LabOK "$stack removed" }
            else { Write-LabWarn "$stack compose down reported issues (may already be stopped)" }
            Pop-Location
        } else {
            Write-LabInfo "No compose file for $stack -- skipping"
        }
    }

    # Tear down ES stacks (volumes wiped with -v)
    foreach ($stack in @("elastic8","elastic9")) {
        $stackPath = Join-Path $Config.LabRoot $stack
        if (Test-Path (Join-Path $stackPath "docker-compose.yml")) {
            Write-Host "`n  Tearing down $stack..." -ForegroundColor White
            Push-Location $stackPath
            docker compose --profile kibana down -v --remove-orphans 2>&1 | ForEach-Object { Write-LabInfo $_ }
            if ($LASTEXITCODE -eq 0) { Write-LabOK "$stack removed" }
            else { Write-LabWarn "$stack compose down reported issues (may already be stopped)" }
            Pop-Location
        } else {
            Write-LabInfo "No compose file for $stack -- skipping"
        }
    }
}

function _Remove-Containers {
    param([hashtable]$Inv)

    Write-LabStep "Step 3 -- Force Remove Remaining Containers"

    if (-not $Inv.Containers) { Write-LabInfo "No containers to force-remove" ; return }

    foreach ($c in $Inv.Containers) {
        docker rm -f $c 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed: $c" }
        else                     { Write-LabWarn "Could not remove: $c" }
    }
}

function _Remove-Volumes {
    param([hashtable]$Inv)

    Write-LabStep "Step 4 -- Remove Docker Volumes"

    if (-not $Inv.Volumes) { Write-LabInfo "No volumes to remove" ; return }

    foreach ($v in $Inv.Volumes) {
        # Check if still exists before attempting removal
        $exists = docker volume ls --format "{{.Name}}" 2>&1 | Where-Object { $_ -eq $v }
        if (-not $exists) {
            Write-LabOK "Already removed: $v"
            continue
        }
        docker volume rm $v 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed: $v" }
        else                     { Write-LabWarn "Could not remove: $v" }
    }
}

function _Remove-Networks {
    param([hashtable]$Inv)

    Write-LabStep "Step 5 -- Remove Docker Networks"

    if (-not $Inv.Networks) { Write-LabInfo "No networks to remove" ; return }

    foreach ($n in $Inv.Networks) {
        # Check if still exists before attempting removal
        $exists = docker network ls --format "{{.Name}}" 2>&1 | Where-Object { $_ -eq $n }
        if (-not $exists) {
            Write-LabOK "Already removed: $n"
            continue
        }
        docker network rm $n 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed: $n" }
        else                     { Write-LabWarn "Could not remove: $n" }
    }
}

function _Remove-Images {
    param([hashtable]$Inv)

    Write-LabStep "Step 6 -- Remove Docker Images"

    if (-not $Inv.Images) { Write-LabInfo "No lab Docker images found -- skipping" ; return }

    Write-Host ""
    Write-Host "  Found $($Inv.Images.Count) image(s) (~$($Inv.ImageSizeEst) GB)." -ForegroundColor Yellow
    Write-Host "  Removing requires re-downloading on next setup." -ForegroundColor Yellow
    $choice = Read-Host "  Remove Docker images? (yes/no)"

    if ($choice -eq "yes") {
        foreach ($i in $Inv.Images) {
            docker rmi $i 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed: $i" }
            else                     { Write-LabWarn "Could not remove: $i" }
        }
    } else {
        Write-LabInfo "Docker images kept -- will be reused on next setup"
    }
}

function _Remove-ElserFiles {
    <#
    .SYNOPSIS Returns $true if the user chose to KEEP the ELSER files, $false if removed.#>
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 7 -- Remove ELSER Model Files"

    if (-not $Inv.ElserFilesOnDisk) {
        Write-LabInfo "No ELSER model files found -- skipping"
        return $false
    }

    Write-Host ""
    Write-Host "  Found ELSER model files ($($Inv.ElserFileSizeMB) MB) at: $($Config.ElserModelDir)" -ForegroundColor Yellow
    Write-Host "  Keeping them avoids a slow re-download on next setup." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    (a) Remove files only" -ForegroundColor Yellow
    Write-Host "    (b) Remove files + delete trained model record from Elasticsearch" -ForegroundColor Yellow
    Write-Host "    (n) Keep files" -ForegroundColor Yellow
    $choice = Read-Host "  ELSER removal: (a) files only  (b) files + ES model  (n) keep"

    if ($choice -notin @("a","b")) {
        Write-LabInfo "ELSER model files kept at $($Config.ElserModelDir)"
        return $true
    }

    if ($choice -eq "b" -and $Inv.ES8Reachable) {
        Write-Host "`n  Deleting ELSER trained model from Elasticsearch..." -ForegroundColor White
        $r = Invoke-LabElasticApi -Method DELETE `
            -Uri "http://localhost:$($Config.ES8Port)/_ml/trained_models/$($Config.ElserModelId)" `
            -Password $Config.ES8Password
        if ($r -and $r.StatusCode -eq 200) { Write-LabOK "Deleted trained model: $($Config.ElserModelId)" }
        else                               { Write-LabInfo "Trained model not found or already deleted" }
    } elseif ($choice -eq "b") {
        Write-LabWarn "Elasticsearch not reachable -- skipping ES model deletion"
    }

    Remove-Item -Path $Config.ElserModelDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $Config.ElserModelDir)) {
        Write-LabOK "Removed ELSER model directory ($($Inv.ElserFileSizeMB) MB freed)"
        return $false
    } else {
        Write-LabWarn "Could not fully remove $($Config.ElserModelDir) -- check file handles"
        return $true
    }
}

function _Stop-OllamaProcesses {
    <#
    .SYNOPSIS Stops the Ollama Windows service and any running Ollama processes. #>
    param([hashtable]$Inv)

    $svc = Get-Service -Name "ollama" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Stop-Service -Name "ollama" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Write-LabOK "Ollama service stopped"
    }
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function _Remove-OllamaModel {
    <#
    .SYNOPSIS Starts Ollama briefly, removes the configured model, then stops Ollama again. #>
    param([hashtable]$Config, [hashtable]$Inv)

    if (-not $Inv.OllamaInstalled) { return }

    Write-Host "`n  Removing model '$($Config.OllamaModel)'..." -ForegroundColor White

    $svc = Get-Service -Name "ollama" -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service -Name "ollama" -ErrorAction SilentlyContinue ; Start-Sleep -Seconds 4
    } else {
        Start-Process -FilePath $Inv.OllamaExe -ArgumentList "serve" -WindowStyle Hidden `
            -RedirectStandardOutput "$env:TEMP\ollama-cleanup.log" `
            -RedirectStandardError  "$env:TEMP\ollama-cleanup-err.log"
        Start-Sleep -Seconds 5
    }

    $modelList = & $Inv.OllamaExe list 2>&1
    if ($modelList -match $Config.OllamaModel) {
        & $Inv.OllamaExe rm $Config.OllamaModel 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed model: $($Config.OllamaModel)" }
        else                     { Write-LabWarn "Could not remove model: $($Config.OllamaModel)" }
    } else {
        Write-LabInfo "Model '$($Config.OllamaModel)' not found -- already removed"
    }

    # Stop again before any uninstall step
    _Stop-OllamaProcesses -Inv $Inv
}

function _Remove-OllamaInstaller {
    <#
    .SYNOPSIS Prompts whether to remove the cached Ollama installer, then removes it if confirmed. #>
    param([hashtable]$Config, [hashtable]$Inv)

    if (-not $Inv.OllamaInstallerFound) { return }

    Write-Host ""
    Write-Host "  Cached installer: $($Config.OllamaInstallerPath) ($($Inv.OllamaInstallerSizeMB) MB)" -ForegroundColor Yellow
    Write-Host "  Keeping it avoids a re-download if you re-run setup." -ForegroundColor Yellow
    $choice = Read-Host "  Remove cached installer? (yes/no)"

    if ($choice -eq "yes") {
        Remove-Item -Path $Config.OllamaInstallerPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $Config.OllamaInstallerPath)) { Write-LabOK "Removed cached installer" }
        else                                               { Write-LabWarn "Could not remove cached installer" }
    } else {
        Write-LabInfo "Cached installer kept: $($Config.OllamaInstallerPath)"
    }
}

function _Uninstall-OllamaApplication {
    <#
    .SYNOPSIS Uninstalls the Ollama application via winget or the bundled uninstaller. #>
    param()

    Write-Host "`n  Uninstalling Ollama application..." -ForegroundColor White
    $uninstalled = $false

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id Ollama.Ollama --silent --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Uninstalled via winget" ; $uninstalled = $true }
        else                     { Write-LabInfo "winget did not find Ollama -- trying direct uninstaller" }
    }

    if (-not $uninstalled) {
        $uninstallerExe = @(
            "$env:LOCALAPPDATA\Programs\Ollama\unins000.exe",
            "$env:ProgramFiles\Ollama\unins000.exe",
            "$env:ProgramFiles\Ollama\Uninstall.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($uninstallerExe) {
            $proc = Start-Process -FilePath $uninstallerExe `
                -ArgumentList "/VERYSILENT /NORESTART /CLOSEAPPLICATIONS" -Wait -PassThru
            if ($proc.ExitCode -eq 0) { Write-LabOK "Ollama uninstalled" }
            else                      { Write-LabWarn "Uninstaller exited with code $($proc.ExitCode)" }
        } else {
            Write-LabWarn "Could not locate uninstaller -- remove manually via Settings -> Apps"
        }
    }
}

function _Remove-OllamaDataFolders {
    <#
    .SYNOPSIS Removes Ollama application data folders from the user profile. #>
    param([hashtable]$Inv)

    Write-Host "`n  Removing Ollama data folders..." -ForegroundColor White
    foreach ($path in $Inv.OllamaDataPaths) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $path)) { Write-LabOK "Removed: $path" }
        else                        { Write-LabWarn "Could not fully remove: $path -- may clear after reboot" }
    }
}

function _Remove-OllamaServiceRegistration {
    <#
    .SYNOPSIS Removes the Ollama Windows service registration via sc.exe. #>
    param()

    $svc = Get-Service -Name "ollama" -ErrorAction SilentlyContinue
    if ($svc) {
        sc.exe delete ollama 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Removed Ollama service registration" }
        else                     { Write-LabWarn "Could not remove service -- may clear after reboot" }
    }
}

function _Remove-Ollama {
    <#
    .SYNOPSIS
        Orchestrates Ollama removal. Prompts for removal level then calls
        the appropriate unit functions.
    #>
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 8 -- Remove Ollama"

    if (-not ($Inv.OllamaInstalled -or $Inv.OllamaDataPaths)) {
        Write-LabInfo "Ollama not found -- skipping"
        return
    }

    Write-Host ""
    if ($Inv.OllamaInstalled)      { Write-Host "  Ollama application is installed." -ForegroundColor Yellow }
    if ($Inv.OllamaModelFound)     { Write-Host "  Model '$($Config.OllamaModel)' is pulled." -ForegroundColor Yellow }
    if ($Inv.OllamaInstallerFound) { Write-Host "  Cached installer: $($Config.OllamaInstallerPath) ($($Inv.OllamaInstallerSizeMB) MB)" -ForegroundColor Yellow }
    if ($Inv.OllamaDataPaths)      { Write-Host "  Data folders: $($Inv.OllamaDataPaths -join ', ')" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "    (a) Remove model only -- keeps Ollama installed" -ForegroundColor Yellow
    Write-Host "    (b) Full uninstall -- model, data folders, application" -ForegroundColor Yellow
    Write-Host "    (n) Keep Ollama" -ForegroundColor Yellow
    $choice = Read-Host "  Ollama removal: (a) model only  (b) full uninstall  (n) keep"

    if ($choice -notin @("a","b")) {
        Write-LabInfo "Ollama kept"
        return
    }

    _Stop-OllamaProcesses    -Inv $Inv
    _Remove-OllamaModel      -Config $Config -Inv $Inv
    _Remove-OllamaInstaller  -Config $Config -Inv $Inv

    if ($choice -eq "b") {
        _Uninstall-OllamaApplication
        _Remove-OllamaDataFolders        -Inv $Inv
        _Remove-OllamaServiceRegistration
        Write-LabOK "Ollama full removal complete"
    }
}

function _Remove-LabFolder {
    param([hashtable]$Config, [hashtable]$Inv, [bool]$KeepElser)

    Write-LabStep "Step 10 -- Remove Lab Folder"

    if (-not $Inv.LabFolderExists) {
        Write-LabInfo "Lab folder not found -- skipping"
        return
    }

    # Determine which artifact paths inside LabRoot are being kept
    $preservedPaths = [System.Collections.Generic.List[string]]::new()

    # Ollama installer
    $installerPresent = Test-Path $Config.OllamaInstallerPath
    if ($installerPresent) { $preservedPaths.Add($Config.OllamaInstallerPath) }

    # ELSER model
    $elserPresent = (Test-Path $Config.ElserModelDir) -and
                    (Get-ChildItem $Config.ElserModelDir -ErrorAction SilentlyContinue)
    if ($elserPresent -and $KeepElser) { $preservedPaths.Add($Config.ElserModelDir) }

    # Vagrant boxes
    if (Test-Path $Inv.VagrantBoxDir) {
        $remaining = Get-ChildItem $Inv.VagrantBoxDir -Directory -ErrorAction SilentlyContinue
        if ($remaining) { $preservedPaths.Add($Inv.VagrantBoxDir) }
    }

    # Agent installers
    if ($Inv.AgentCacheFiles -and (Test-Path $Inv.AgentCacheDir)) {
        $remaining = Get-ChildItem $Inv.AgentCacheDir -File -ErrorAction SilentlyContinue
        if ($remaining) { $preservedPaths.Add($Inv.AgentCacheDir) }
    }

    # If anything is kept inside artifacts\, preserve the artifacts folder itself
    $artifactsDir = $Config.ArtifactsDir
    $anyKeptInArtifacts = $preservedPaths | Where-Object { $_.StartsWith($artifactsDir) }
    if ($anyKeptInArtifacts) { $preservedPaths.Add($artifactsDir) }

    $anyKept = $preservedPaths.Count -gt 0

    Write-Host ""
    Write-Host "  Lab folder: $($Config.LabRoot)" -ForegroundColor Yellow

    if ($anyKept) {
        Write-Host ""
        Write-Host "  NOTE: The following items inside this folder are being kept:" -ForegroundColor Cyan
        foreach ($p in $preservedPaths) {
            Write-Host "        $p" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "  Answering YES removes all other contents but preserves the above." -ForegroundColor Yellow
    }

    $suffix = if ($anyKept) { " contents (kept artifacts will be preserved)" } else { "" }
    Write-Host ""
    $choice = Read-Host "  Delete lab folder${suffix}? (yes/no)"

    if ($choice -ne "yes") {
        Write-LabInfo "Lab folder kept: $($Config.LabRoot)"
        return
    }

    if ($anyKept) {
        Write-Host "`n  Removing lab folder contents -- preserving kept artifacts..." -ForegroundColor White
        Get-ChildItem -Path $Config.LabRoot -ErrorAction SilentlyContinue |
            Where-Object {
                $item = $_.FullName
                # Skip if this item IS a preserved path or is a PARENT of one
                $isPreserved = $preservedPaths | Where-Object {
                    $_ -eq $item -or $_.StartsWith($item + "\")
                }
                -not $isPreserved
            } |
            ForEach-Object {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $_.FullName)) { Write-LabOK "Removed: $($_.Name)" }
                else                              { Write-LabWarn "Could not remove: $($_.Name)" }
            }
        foreach ($p in $preservedPaths) {
            if (Test-Path $p) { Write-LabOK "Preserved: $p" }
        }
        Write-LabInfo "Lab folder kept (contains preserved artifacts): $($Config.LabRoot)"
    } else {
        Remove-Item -Path $Config.LabRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $Config.LabRoot)) { Write-LabOK "Deleted: $($Config.LabRoot)" }
        else                                  { Write-LabWarn "Could not fully delete -- check file handles" }
    }
}

function _Remove-VagrantBoxes {
    <#
    .SYNOPSIS
        Optionally removes cached Vagrant boxes.
        Kept by default -- re-downloading Windows boxes takes ~6 GB.
        Prompts per-box so you can selectively remove specific ones.
    #>
    param([hashtable]$Config, [hashtable]$Inv)

    if (-not $Inv.VagrantBoxes -or $Inv.VagrantBoxes.Count -eq 0) {
        Write-LabInfo "No Vagrant boxes cached -- skipping"
        return
    }

    $totalMB = [Math]::Round((Get-ChildItem $Inv.VagrantBoxDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB, 0)

    Write-Host ""
    Write-Host "  Vagrant box cache: $($Inv.VagrantBoxDir)" -ForegroundColor Yellow
    Write-Host "  $($Inv.VagrantBoxes.Count) box(es), $totalMB MB total" -ForegroundColor Yellow
    Write-Host "  Keeping boxes avoids re-downloading on next build (Windows ~6 GB, Linux ~600 MB)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    (a) Remove ALL boxes   (n) Keep ALL boxes" -ForegroundColor Yellow
    $choice = Read-Host "  Remove Vagrant boxes"

    if ($choice -eq "a") {
        foreach ($box in $Inv.VagrantBoxes) {
            $boxMB = [Math]::Round((Get-ChildItem $box.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1MB, 0)
            Remove-Item -Path $box.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $box.FullName)) {
                Write-LabOK "Removed box: $($box.Name) ($boxMB MB freed)"
            } else {
                Write-LabWarn "Could not fully remove: $($box.Name)"
            }
        }
    } else {
        Write-LabInfo "Vagrant boxes kept: $($Inv.VagrantBoxDir)"
    }
}

function _Remove-AgentCache {
    <#
    .SYNOPSIS
        Optionally removes cached Elastic Agent installers.
        Kept by default -- they survive cleanup to avoid re-downloading
        on the next build run. Clearing frees ~1-2 GB per version pair.
    #>
    param([hashtable]$Config, [hashtable]$Inv)

    if (-not $Inv.AgentCacheFiles -or $Inv.AgentCacheFiles.Count -eq 0) {
        Write-LabInfo "Agent installer cache is empty -- skipping"
        return
    }

    $totalMB = [Math]::Round(($Inv.AgentCacheFiles | Measure-Object Length -Sum).Sum / 1MB, 0)
    Write-Host ""
    Write-Host "  Agent installer cache: $($Inv.AgentCacheDir)" -ForegroundColor Yellow
    Write-Host "  $($Inv.AgentCacheFiles.Count) file(s), $totalMB MB total" -ForegroundColor Yellow
    Write-Host "  Keeping these avoids re-downloading (~500 MB per version) on the next build." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    (y) Clear cache   (n) Keep files" -ForegroundColor Yellow
    $choice = Read-Host "  Clear agent installer cache"

    if ($choice -eq "y") {
        Remove-Item -Path $Inv.AgentCacheDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $Inv.AgentCacheDir)) {
            Write-LabOK "Agent installer cache cleared ($totalMB MB freed)"
        } else {
            Write-LabWarn "Could not fully clear cache -- check file handles"
        }
    } else {
        Write-LabInfo "Agent installer cache kept: $($Inv.AgentCacheDir)"
    }
}

function _Remove-VMs {
    <#
    .SYNOPSIS
        Tears down lab VMs -- Vagrant destroy for Vagrant-managed VMs,
        Stop-VM + Remove-VM for native Hyper-V VMs.
        Uses vagrant global-status as a fallback when the VM directory
        has already been removed by a prior lab folder cleanup.
    #>
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 9 -- Remove Lab VMs"

    if (-not $Inv.VagrantDirs -and -not $Inv.HyperVVMs) {
        Write-LabInfo "No lab VMs found -- skipping"
        return
    }

    # Build a map of VM name -> global-status ID for directory-less fallback
    $globalIds = @{}
    if (Get-Command vagrant -ErrorAction SilentlyContinue) {
        $globalOut = vagrant global-status 2>&1
        foreach ($line in $globalOut) {
            # Lines look like: "abc1234  default  hyperv  running  C:\path\to\vm"
            if ($line -match "^([0-9a-f]{7,})\s+\S+\s+\S+\s+\S+\s+(.+)$") {
                $id   = $Matches[1].Trim()
                $path = $Matches[2].Trim()
                $name = Split-Path $path -Leaf
                $globalIds[$name] = $id
            }
        }
    }

    # Vagrant-managed VMs
    foreach ($dir in $Inv.VagrantDirs) {
        $vmName = Split-Path $dir -Leaf
        Write-Host "`n  Destroying Vagrant VM: $vmName..." -ForegroundColor White

        if (Test-Path $dir) {
            # Directory exists -- use normal vagrant destroy
            Push-Location $dir
            vagrant destroy -f 2>&1 | ForEach-Object { Write-LabInfo $_ }
            $ok = ($LASTEXITCODE -eq 0)
            Pop-Location
        } elseif ($globalIds.ContainsKey($vmName)) {
            # Directory gone but VM still registered -- destroy by global ID
            $id = $globalIds[$vmName]
            Write-LabInfo "Directory gone -- using global-status ID: $id"
            vagrant destroy -f $id 2>&1 | ForEach-Object { Write-LabInfo $_ }
            $ok = ($LASTEXITCODE -eq 0)
        } else {
            Write-LabInfo "$vmName -- directory gone and not found in global-status, skipping"
            $ok = $true
        }

        if ($ok) { Write-LabOK "Vagrant VM destroyed: $vmName" }
        else     { Write-LabWarn "vagrant destroy reported issues for: $vmName" }
    }

    # Native Hyper-V VMs
    foreach ($vmName in $Inv.HyperVVMs) {
        Write-Host "`n  Removing Hyper-V VM: $vmName..." -ForegroundColor White
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { Write-LabInfo "$vmName not found -- skipping" ; continue }

        if ($vm.State -ne "Off") {
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        $vhdPaths = (Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue).Path
        Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
        Write-LabOK "Removed Hyper-V VM: $vmName"

        foreach ($vhd in $vhdPaths) {
            if (Test-Path $vhd) {
                Remove-Item -Path $vhd -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $vhd)) { Write-LabOK "Removed VHD: $vhd" }
                else                       { Write-LabWarn "Could not remove VHD: $vhd" }
            }
        }
    }
}

function _Show-CleanupVerification {
    param([hashtable]$Config, [hashtable]$Inv)

    Write-LabStep "Step 11 -- Verify Cleanup"

    $allClear = $true

    $rem = docker ps -a --format "{{.Names}}" 2>&1 | Where-Object {
        $_ -match "^(es8|es9|kibana8|kibana9|elser-repo|fleet8|fleet9|linux8|linux9|agent8|agent9)"
    }
    if ($rem) { foreach ($r in $rem) { Write-LabWarn "Container still present: $r" } ; $allClear = $false }
    else      { Write-LabOK "No lab containers remaining" }

    $remVols = docker volume ls --format "{{.Name}}" 2>&1 | Where-Object { $_ -match "elastic8|elastic9" }
    if ($remVols) { foreach ($v in $remVols) { Write-LabWarn "Volume still present: $v" } ; $allClear = $false }
    else          { Write-LabOK "No lab volumes remaining" }

    $remNets = docker network ls --format "{{.Name}}" 2>&1 | Where-Object { $_ -match "elastic8_elastic8-net|elastic9_elastic9-net" }
    if ($remNets) { foreach ($n in $remNets) { Write-LabWarn "Network still present: $n" } ; $allClear = $false }
    else          { Write-LabOK "No lab networks remaining" }

    # Vagrant VMs
    if ($Inv.VagrantDirs) {
        foreach ($dir in $Inv.VagrantDirs) {
            $vmName = Split-Path $dir -Leaf
            if (Test-Path $dir) {
                Push-Location $dir
                $status = vagrant status 2>&1 | Select-String "running"
                Pop-Location
                if ($status) {
                    Write-LabWarn "Vagrant VM still running: $vmName"
                    $allClear = $false
                } else {
                    Write-LabOK "Vagrant VM stopped/removed: $vmName"
                }
            } else {
                # Directory gone -- check global-status
                $globalCheck = vagrant global-status 2>&1 | Select-String $vmName
                if ($globalCheck) {
                    Write-LabWarn "Vagrant VM still registered in global-status: $vmName"
                    $allClear = $false
                } else {
                    Write-LabOK "Vagrant VM removed: $vmName"
                }
            }
        }
    }

    # Hyper-V VMs
    if ($Inv.HyperVVMs -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($vmName in $Inv.HyperVVMs) {
            $stillExists = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($stillExists) {
                Write-LabWarn "Hyper-V VM still exists: $vmName"
                $allClear = $false
            } else {
                Write-LabOK "Hyper-V VM removed: $vmName"
            }
        }
    }

    if ($Inv.VagrantBoxes -and (Test-Path $Inv.VagrantBoxDir)) {
        $remainingBoxes = Get-ChildItem $Inv.VagrantBoxDir -Directory -ErrorAction SilentlyContinue
        if ($remainingBoxes) {
            $remainMB = [Math]::Round((Get-ChildItem $Inv.VagrantBoxDir -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1MB, 0)
            Write-LabInfo "Vagrant boxes kept: $($Inv.VagrantBoxDir) ($remainMB MB, $($remainingBoxes.Count) box(es))"
        } else {
            Write-LabOK "Vagrant box cache cleared"
        }
    }

    if (Test-Path $Config.AgentInstallerCache) {
        $cacheFiles = Get-ChildItem $Config.AgentInstallerCache -ErrorAction SilentlyContinue
        if ($cacheFiles) {
            $cacheMB = [Math]::Round(($cacheFiles | Measure-Object Length -Sum).Sum / 1MB, 0)
            Write-LabInfo "Agent cache kept: $($Config.AgentInstallerCache) ($cacheMB MB, $($cacheFiles.Count) files)"
        }
    } else {
        Write-LabOK "Agent installer cache cleared"
    }

    if (Test-Path $Config.ElserModelDir) {
        $elserRem = Get-ChildItem -Path $Config.ElserModelDir -ErrorAction SilentlyContinue
        if ($elserRem) {
            Write-LabInfo "ELSER model files kept ($([Math]::Round(($elserRem | Measure-Object -Property Length -Sum).Sum / 1MB, 1)) MB): $($Config.ElserModelDir)"
        } else {
            Write-LabInfo "ELSER model directory empty"
        }
    } else { Write-LabOK "ELSER model directory removed" }
    $ollamaExeCheck = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    $ollamaStill    = (Test-Path $ollamaExeCheck) -or [bool](Get-Command ollama -ErrorAction SilentlyContinue)
    if ($ollamaStill) { Write-LabInfo "Ollama still installed (kept by choice)" }
    else              { Write-LabOK "Ollama not found -- fully removed" }

    if (Get-Process -Name "ollama" -ErrorAction SilentlyContinue) {
        if (-not $ollamaStill) {
            Write-LabWarn "Ollama process still running after removal -- run: Stop-Process -Name ollama -Force"
            $allClear = $false
        } else {
            Write-LabInfo "Ollama process running (Ollama kept by choice)"
        }
    } else { Write-LabOK "No Ollama processes running" }

    if (Test-Path $Config.OllamaInstallerPath) {
        Write-LabInfo "Cached installer kept: $($Config.OllamaInstallerPath)"
    } else { Write-LabOK "Ollama cached installer removed" }

    if (Test-Path $Config.LabRoot) {
        $keptItems = @()
        if ((Test-Path $Config.OllamaInstallerPath) -and $Config.OllamaInstallerPath.StartsWith($Config.LabRoot)) { $keptItems += "Ollama installer" }
        if ((Test-Path $Config.ElserModelDir) -and (Get-ChildItem $Config.ElserModelDir -ErrorAction SilentlyContinue)) { $keptItems += "ELSER model files" }
        if ($keptItems) { Write-LabInfo "Lab folder kept -- preserved: $($keptItems -join ', ')" }
        else            { Write-LabInfo "Lab folder still present (kept by choice)" }
    } else { Write-LabOK "Lab folder removed" }

    Write-Host "`n"
    if ($allClear) {
        Write-Host "===============================================" -ForegroundColor Green
        Write-Host "  Cleanup complete -- lab fully removed." -ForegroundColor Green
        Write-Host "  Run Invoke-ElasticLab.ps1 to rebuild." -ForegroundColor Green
        Write-Host "===============================================" -ForegroundColor Green
    } else {
        Write-Host "===============================================" -ForegroundColor Yellow
        Write-Host "  Cleanup complete with warnings." -ForegroundColor Yellow
        Write-Host "  Review [!!] items before re-running build." -ForegroundColor Yellow
        Write-Host "===============================================" -ForegroundColor Yellow
    }
    Write-Host ""
}

Export-ModuleMember -Function Invoke-LabCleanup
