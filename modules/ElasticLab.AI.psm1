# =============================================================================
# ElasticLab.AI.psm1
# AI tooling: ELSER model file download, ELSER inference endpoint deployment,
# Ollama model pull, and Ollama inference endpoint registration.
# Both ELSER and Ollama are registered on all active stacks.
# =============================================================================

function Invoke-LabElserDownload {
    <#
    .SYNOPSIS
        Ensures the three ELSER model files are present in ElserModelDir.
        Skips any files already downloaded. Sets Config.SetupElser = $false
        if a download fails, preventing downstream steps from attempting deployment.
    #>
    param([hashtable]$Config)

    if (-not $Config.SetupElser) {
        Write-LabSkip "ELSER model download (AITool = $($Config.AITool))"
        return $Config
    }

    Write-LabStep "ELSER -- Download Model Files"

    $files = @(
        "$($Config.ElserModelFile).metadata.json",
        "$($Config.ElserModelFile).pt",
        "$($Config.ElserModelFile).vocab.json"
    )

    $allPresent = $true
    foreach ($file in $files) {
        $dest = Join-Path $Config.ElserModelDir $file
        if (Test-Path $dest) {
            Write-LabOK "[ELSER] Present: $file ($([Math]::Round((Get-Item $dest).Length / 1MB, 1)) MB)"
        } else {
            $allPresent = $false
        }
    }

    if ($allPresent) {
        Write-LabInfo "[ELSER] All model files already present -- download skipped"
        return $Config
    }

    Write-Host "`n  [ELSER] Downloading missing model files..." -ForegroundColor White
    Write-LabInfo "[ELSER] Air-gapped: copy files to $($Config.ElserModelDir) and re-run"

    $failed = $false
    foreach ($file in $files) {
        $dest = Join-Path $Config.ElserModelDir $file
        if (Test-Path $dest) { continue }

        $url = "$($Config.ElserModelBase)/$file"
        Write-Host "  [ELSER] Downloading: $file" -ForegroundColor White
        try {
            $null = Invoke-WebRequest -Uri $url -OutFile $dest `
                -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
            Write-LabOK "[ELSER] Downloaded: $file ($([Math]::Round((Get-Item $dest).Length / 1MB, 1)) MB)"
        } catch {
            Write-LabWarn "[ELSER] Failed to download $file : $_"
            $failed = $true
        }
    }

    if ($failed) {
        Write-LabWarn "[ELSER] One or more files could not be downloaded -- skipping ELSER this run"
        $Config.SetupElser = $false
        return $Config
    }

    # Pull nginx:alpine needed for the local model repo container
    Write-Host "`n  [ELSER] Pulling nginx:alpine for local model repo..." -ForegroundColor White
    docker pull nginx:alpine 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LabWarn "[ELSER] Failed to pull nginx:alpine -- skipping ELSER this run"
        $Config.SetupElser = $false
    }

    return $Config
}

function Invoke-LabOllamaModelPull {
    <#
    .SYNOPSIS
        Waits for the Ollama API to respond and pulls the configured model.
    #>
    param([hashtable]$Config)

    if (-not $Config.SetupOllama) {
        Write-LabSkip "Ollama model pull (AITool = $($Config.AITool))"
        return
    }

    Write-LabStep "Ollama -- Pull Model"

    Write-Host "  [Ollama] Checking API on port $($Config.OllamaPort)..." -ForegroundColor White
    $waited   = 0
    $ollamaUp = $false

    while ($waited -lt 30) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$($Config.OllamaPort)/api/tags" `
                -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $ollamaUp = ($r.StatusCode -eq 200)
            if ($ollamaUp) { break }
        } catch {}
        Start-Sleep -Seconds 3 ; $waited += 3
        Write-Host "  [${waited}s] Waiting for Ollama API..." -ForegroundColor DarkGray
    }

    if (-not $ollamaUp) {
        Write-LabWarn "[Ollama] API did not respond within 30s -- model pull skipped"
        Write-LabWarn "[Ollama] Run manually: ollama pull $($Config.OllamaModel)"
        return
    }

    Write-LabOK "[Ollama] API responding on port $($Config.OllamaPort)"

    $ollamaExe = if (Test-Path "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe") {
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    } else { "ollama" }

    Write-Host "  [Ollama] Pulling model '$($Config.OllamaModel)'..." -ForegroundColor White
    & $ollamaExe pull $Config.OllamaModel
    if ($LASTEXITCODE -eq 0) {
        Write-LabOK "[Ollama] Model '$($Config.OllamaModel)' ready"
    } else {
        Write-LabWarn "[Ollama] Model pull returned exit code $LASTEXITCODE"
        Write-LabWarn "[Ollama] Run manually: ollama pull $($Config.OllamaModel)"
    }
}

function Invoke-LabElserDeployment {
    <#
    .SYNOPSIS
        Creates ELSER inference endpoints on each active stack and polls until
        the model reaches 'started' state (up to 10 minutes per stack).
        Skipped for any stack where the trial license was not successfully activated.
    #>
    param([hashtable]$Config, [hashtable]$LicenseResults)

    if (-not $Config.SetupElser) {
        Write-LabSkip "ELSER deployment (AITool = $($Config.AITool))"
        return
    }

    Write-LabStep "ELSER -- Deploy Inference Endpoints"

    foreach ($stack in $Config.ActiveStacks) {
        if (-not $LicenseResults[$stack.Label]) {
            Write-LabWarn "[$($stack.Label)] Skipping ELSER -- license not active"
            continue
        }
        _Deploy-ElserOnStack -Stack $stack -Config $Config
    }
}

function Invoke-LabOllamaEndpointRegistration {
    <#
    .SYNOPSIS
        Registers the Ollama inference endpoint on each active stack.
        Surfaces the full Elasticsearch error body on failure, with specific
        guidance for HTTP 403 (license restriction).
    #>
    param([hashtable]$Config, [hashtable]$LicenseResults)

    if (-not $Config.SetupOllama) {
        Write-LabSkip "Ollama endpoint registration (AITool = $($Config.AITool))"
        return
    }

    Write-LabStep "Ollama -- Register Inference Endpoints"

    # Confirm Ollama is running before attempting registration
    $ollamaUp = $false
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$($Config.OllamaPort)" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $ollamaUp = ($r.StatusCode -eq 200)
    } catch {}

    if (-not $ollamaUp) {
        Write-LabWarn "[Ollama] API not responding on port $($Config.OllamaPort)"
        Write-LabWarn "[Ollama] Start Ollama from the system tray or run: ollama serve"
        return
    }
    Write-LabOK "[Ollama] Running on port $($Config.OllamaPort)"

    foreach ($stack in $Config.ActiveStacks) {
        if (-not $LicenseResults[$stack.Label]) {
            Write-LabWarn "[$($stack.Label)] Skipping Ollama endpoint -- license not active"
            continue
        }
        _Register-OllamaOnStack -Stack $stack -Config $Config
    }
}

# -- Private: ELSER -- three separate units -------------------------------------

function _New-ElserEndpoint {
    <#
    .SYNOPSIS Creates the ELSER sparse_embedding inference endpoint. Returns $true on success. #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label = $Stack.Label
    $infId = $Config.ElserInferenceId

    $existing = Invoke-LabElasticApi -Method GET `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/sparse_embedding/$infId" `
        -Password $Stack.Password
    if ($existing -and $existing.StatusCode -eq 200) {
        Write-LabOK "[$label] ELSER endpoint '$infId' already exists -- skipping"
        return $true
    }

    Write-Host "  [$label] Creating ELSER endpoint '$infId'..." -ForegroundColor White
    $r = Invoke-LabElasticApi -Method PUT `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/sparse_embedding/$infId" `
        -Password $Stack.Password `
        -Body '{"service":"elser","service_settings":{"num_allocations":1,"num_threads":1}}'

    if ($r -and $r.StatusCode -eq 200) {
        Write-LabOK "[$label] ELSER endpoint created -- model loading from local nginx repo"
        return $true
    }
    Write-LabWarn "[$label] ELSER endpoint creation failed -- check license"
    return $false
}

function Wait-LabElserModel {
    <#
    .SYNOPSIS Polls until the ELSER model reaches 'started' state. Returns $true on success. #>
    param([hashtable]$Stack, [hashtable]$Config, [int]$TimeoutSec = 600)

    $label   = $Stack.Label
    $modelId = $Config.ElserModelId

    Write-Host "`n  [$label] Waiting for ELSER model (up to $([int]($TimeoutSec/60)) min)..." -ForegroundColor White
    $waited = 0

    while ($waited -lt $TimeoutSec) {
        Start-Sleep -Seconds 15 ; $waited += 15
        $s = Invoke-LabElasticApi -Method GET `
            -Uri "http://localhost:$($Stack.ESPort)/_ml/trained_models/$modelId/_stats" `
            -Password $Stack.Password
        if ($s -and $s.StatusCode -eq 200) {
            $ds     = ($s.Content | ConvertFrom-Json).trained_model_stats[0].deployment_stats
            $state  = $ds.state
            $alloc  = $ds.allocation_status.allocation_count
            $target = $ds.allocation_status.target_allocation_count
            Write-Host "  [${waited}s] [$label] State: $state  Allocations: $alloc/$target" -ForegroundColor DarkGray
            if ($state -eq "started" -and $alloc -ge 1) {
                Write-LabOK "[$label] ELSER model fully deployed and allocated"
                return $true
            }
        } else {
            Write-Host "  [${waited}s] [$label] Stats not yet available..." -ForegroundColor DarkGray
        }
    }
    Write-LabWarn "[$label] ELSER did not reach 'started' within ${TimeoutSec}s -- may still be loading"
    Write-LabWarn "[$label] Check: GET http://localhost:$($Stack.ESPort)/_ml/trained_models/$modelId/_stats"
    return $false
}

function Test-LabElserSmoke {
    <#
    .SYNOPSIS Sends a test inference request to verify the ELSER endpoint is responding. #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label = $Stack.Label
    $infId = $Config.ElserInferenceId

    Write-Host "  [$label] Running ELSER smoke test..." -ForegroundColor White
    $r = Invoke-LabElasticApi -Method POST `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/sparse_embedding/$infId" `
        -Password $Stack.Password `
        -Body '{"input":"How many errors occurred yesterday?"}'

    if ($r -and $r.StatusCode -eq 200) { Write-LabOK "[$label] ELSER smoke test passed" }
    else { Write-LabWarn "[$label] ELSER smoke test inconclusive -- check Kibana ML page" }
}

function _Deploy-ElserOnStack {
    <#
    .SYNOPSIS Orchestrates ELSER deployment for one stack using the three unit functions. #>
    param([hashtable]$Stack, [hashtable]$Config)

    if (-not (Test-LabElasticHealth -Port $Stack.ESPort -Password $Stack.Password)) {
        Write-LabWarn "[$($Stack.Label)] Elasticsearch not reachable -- skipping ELSER deployment"
        return
    }

    $created = _New-ElserEndpoint -Stack $Stack -Config $Config
    if (-not $created) { return }

    $ready = Wait-LabElserModel -Stack $Stack -Config $Config
    if ($ready) { Test-LabElserSmoke -Stack $Stack -Config $Config }
}

# -- Private: Ollama -- two separate units --------------------------------------

function _New-OllamaEndpoint {
    <#
    .SYNOPSIS Registers the Ollama completion inference endpoint. Returns $true on success. #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label = $Stack.Label
    $infId = $Config.OllamaInferenceId
    $model = $Config.OllamaModel
    $oPort = $Config.OllamaPort

    $existing = Invoke-LabElasticApi -Method GET `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/completion/$infId" `
        -Password $Stack.Password
    if ($existing -and $existing.StatusCode -eq 200) {
        Write-LabOK "[$label] Ollama endpoint '$infId' already exists -- skipping"
        return $true
    }

    Write-Host "  [$label] Registering Ollama endpoint '$infId'..." -ForegroundColor White

    $body = @"
{
    "service": "openai",
    "service_settings": {
        "api_key":  "ollama",
        "model_id": "$model",
        "url":      "http://host.docker.internal:$oPort/v1/chat/completions"
    }
}
"@

    $result = Invoke-LabElasticApiWithError -Method PUT `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/completion/$infId" `
        -Password $Stack.Password -Body $body

    if ($result.Response -and $result.Response.StatusCode -eq 200) {
        Write-LabOK "[$label] Ollama endpoint '$infId' registered"
        return $true
    }

    Write-LabWarn "[$label] Failed to register Ollama endpoint (HTTP $($result.StatusCode))"
    if ($result.ErrorType)   { Write-LabWarn "[$label] ES error type   : $($result.ErrorType)" }
    if ($result.ErrorReason) { Write-LabWarn "[$label] ES error reason : $($result.ErrorReason)" }

    if ($result.StatusCode -eq 403) {
        Write-LabWarn "[$label] HTTP 403 = license restriction -- trial must be active"
        Write-LabWarn "[$label] Kibana -> Stack Management -> License Management -> Start Trial"
    } else {
        Write-LabWarn "[$label] Ollama not running, model not pulled, or host.docker.internal unreachable"
    }
    return $false
}

function Test-LabOllamaSmoke {
    <#
    .SYNOPSIS Sends a test inference request to verify the Ollama endpoint is responding. #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label = $Stack.Label
    $infId = $Config.OllamaInferenceId

    Write-Host "  [$label] Running Ollama smoke test..." -ForegroundColor White
    $result = Invoke-LabElasticApiWithError -Method POST `
        -Uri "http://localhost:$($Stack.ESPort)/_inference/completion/$infId" `
        -Password $Stack.Password `
        -Body '{"input":"Reply with one word: working"}'

    if ($result.Response -and $result.Response.StatusCode -eq 200) {
        Write-LabOK "[$label] Ollama smoke test passed"
    } else {
        Write-LabWarn "[$label] Ollama smoke test inconclusive -- endpoint registered but Ollama may not be responding"
    }
}

function _Register-OllamaOnStack {
    <#
    .SYNOPSIS Orchestrates Ollama registration for one stack using the two unit functions. #>
    param([hashtable]$Stack, [hashtable]$Config)

    if (-not (Test-LabElasticHealth -Port $Stack.ESPort -Password $Stack.Password)) {
        Write-LabWarn "[$($Stack.Label)] Elasticsearch not reachable -- skipping Ollama registration"
        return
    }

    $registered = _New-OllamaEndpoint -Stack $Stack -Config $Config
    if ($registered) { Test-LabOllamaSmoke -Stack $Stack -Config $Config }
}

Export-ModuleMember -Function Invoke-LabElserDownload, Invoke-LabOllamaModelPull,
                              Invoke-LabElserDeployment, Invoke-LabOllamaEndpointRegistration,
                              Wait-LabElserModel, Test-LabElserSmoke, Test-LabOllamaSmoke
