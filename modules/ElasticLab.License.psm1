# =============================================================================
# ElasticLab.License.psm1
# Programmatic trial license activation via POST /_license/start_trial.
# Required before ELSER or Ollama inference endpoints can be registered.
# =============================================================================

function Invoke-LabTrialActivation {
    <#
    .SYNOPSIS
        Activates a 30-day trial license on each active Elasticsearch stack.
        - Skips if a qualifying license (trial/enterprise/platinum/gold) is already active.
        - Checks trial eligibility before attempting activation.
        - Uses POST /_license/start_trial?acknowledge=true (no UI interaction needed).
        Returns a hashtable of Label -> bool indicating activation success.
    #>
    param([hashtable]$Config)

    Write-LabStep "License -- Activate 30-Day Trial"

    $results = @{}

    foreach ($stack in $Config.ActiveStacks) {
        $results[$stack.Label] = _Start-StackTrial -Stack $stack
    }

    return $results
}

# -- Private -------------------------------------------------------------------

function _Start-StackTrial {
    param([hashtable]$Stack)

    $label    = $Stack.Label
    $port     = $Stack.ESPort
    $password = $Stack.Password

    # Check current license
    $licenseResp = Invoke-LabElasticApi -Method GET `
        -Uri "http://localhost:$port/_license" `
        -Password $password

    if ($licenseResp -and $licenseResp.StatusCode -eq 200) {
        $license = ($licenseResp.Content | ConvertFrom-Json).license
        $type    = $license.type
        $status  = $license.status

        if ($type -in @("trial","enterprise","platinum","gold") -and $status -eq "active") {
            Write-LabOK "[$label] License already active: $type ($status) -- no action needed"
            return $true
        }
        Write-LabInfo "[$label] Current license: $type ($status) -- attempting trial activation"
    }

    # Check trial eligibility
    $trialStatus = Invoke-LabElasticApi -Method GET `
        -Uri "http://localhost:$port/_license/trial_status" `
        -Password $password

    if ($trialStatus -and $trialStatus.StatusCode -eq 200) {
        $eligible = ($trialStatus.Content | ConvertFrom-Json).eligible_to_start_trial
        if (-not $eligible) {
            Write-LabWarn "[$label] Trial already used on this major version"
            Write-LabWarn "[$label] Inference API requires Enterprise or active trial"
            Write-LabWarn "[$label] ELSER and Ollama registration will be skipped for $label"
            return $false
        }
    }

    # Activate trial -- acknowledge=true bypasses UI confirmation
    Write-Host "  [$label] Starting 30-day trial license..." -ForegroundColor White
    $r = Invoke-LabElasticApi -Method POST `
        -Uri "http://localhost:$port/_license/start_trial?acknowledge=true" `
        -Password $password

    if ($r -and $r.StatusCode -eq 200) {
        $result = $r.Content | ConvertFrom-Json
        if ($result.trial_was_started) {
            Write-LabOK "[$label] 30-day trial activated -- all subscription features now available"
            return $true
        }
        Write-LabWarn "[$label] Trial not started: $($r.Content)"
        return $false
    }

    Write-LabWarn "[$label] Failed to activate trial license"
    return $false
}

Export-ModuleMember -Function Invoke-LabTrialActivation
