# =============================================================================
# ElasticLab.Invoke.psm1
# Top-level invoke functions -- one per lab phase.
# Each function owns a complete phase sequence from start to summary.
# The driver script (Invoke-ElasticLab.ps1) calls these directly.
# =============================================================================

function Invoke-ElasticLabBuild {
    <#
    .SYNOPSIS
        Builds the core Elastic stack: Elasticsearch + Kibana + ELSER + Ollama.
        This phase must always run first -- all other phases depend on it.

    .OUTPUTS
        Returns the resolved config hashtable with version information populated.
        Pass the returned config to subsequent invoke functions.
    #>
    param([hashtable]$Config)

    Write-Host "`n"
    Write-Host "  +==============================================+" -ForegroundColor Cyan
    Write-Host "  |       PHASE 1 -- ELASTIC STACK BUILD          |" -ForegroundColor Cyan
    Write-Host "  |  Stack: $($Config.StackMode.PadRight(6))  AI: $($Config.AITool.PadRight(18))|" -ForegroundColor Cyan
    Write-Host "  +==============================================+" -ForegroundColor Cyan

    # Pre-flight returns enriched config with resolved versions
    [hashtable]$Config = Invoke-LabPreflight -Config $Config

    New-LabFolderStructure -Config $Config
    Set-LabWslConfig       -Config $Config

    # Returns config with SetupElser = $false if download fails
    [hashtable]$Config = Invoke-LabElserDownload -Config $Config

    Invoke-LabImagePull    -Config $Config
    New-LabComposeFiles    -Config $Config
    Start-LabElasticsearch -Config $Config

    [hashtable]$healthResults   = Wait-LabElasticsearch       -Config $Config
    [hashtable]$passwordResults = Set-LabKibanaSystemPassword -Config $Config -HealthResults $healthResults

    Start-LabKibana           -Config $Config -PasswordResults $passwordResults
    Invoke-LabOllamaModelPull -Config $Config

    [hashtable]$kibanaResults  = Wait-LabKibana            -Config $Config -PasswordResults $passwordResults
    [hashtable]$licenseResults = Invoke-LabTrialActivation -Config $Config

    Invoke-LabElserDeployment            -Config $Config -LicenseResults $licenseResults
    Invoke-LabOllamaEndpointRegistration -Config $Config -LicenseResults $licenseResults

    # Phase summary
    Write-LabStep "Phase 1 Complete -- Elastic Stack"

    $elserNote  = if ($Config.SetupElser)  { "$($Config.ElserInferenceId)  (sparse_embedding)" } else { "not configured" }
    $ollamaNote = if ($Config.SetupOllama) { "$($Config.OllamaInferenceId)  (completion)  model: $($Config.OllamaModel)" } else { "not configured" }

    $stackLines = ""
    foreach ($stack in $Config.ActiveStacks) {
        $stackLines += @"

  |  $($stack.Label) -- version $($stack.Version)
  |  Elasticsearch : http://localhost:$($stack.ESPort)
  |  Kibana        : http://localhost:$($stack.KibanaPort)
  |  Credentials   : elastic / $($stack.Password)
  +=============================================================+
"@
    }

    Write-Host @"

  +=============================================================+
$stackLines
  |  AI TOOLS                                                   |
  |  ELSER  : $elserNote
  |  Ollama : $ollamaNote
  +=============================================================+

  USEFUL COMMANDS:
    docker ps                    -- list running containers
    docker logs es8 -f           -- ES8 log stream
    docker logs es9 -f           -- ES9 log stream
    docker logs kibana8 -f       -- Kibana8 log stream
    docker logs kibana9 -f       -- Kibana9 log stream

"@ -ForegroundColor White

    return $Config
}

function Invoke-ElasticFleetBuild {
    <#
    .SYNOPSIS
        Builds Fleet Server infrastructure on top of a running Elastic stack.
        Invoke-ElasticLabBuild must have completed successfully before calling this.
    #>
    param([hashtable]$Config)

    Write-Host "`n"
    Write-Host "  +==============================================+" -ForegroundColor Cyan
    Write-Host "  |       PHASE 2 -- FLEET SERVER BUILD           |" -ForegroundColor Cyan
    Write-Host "  +==============================================+" -ForegroundColor Cyan

    Invoke-LabFleetSetup -Config $Config
}

function Invoke-ElasticVMBuild {
    <#
    .SYNOPSIS
        Provisions Windows and Linux VMs with Elastic Agent enrolled into Fleet.
        Both Invoke-ElasticLabBuild and Invoke-ElasticFleetBuild must have
        completed successfully before calling this.
    #>
    param([hashtable]$Config)

    Write-Host "`n"
    Write-Host "  +==============================================+" -ForegroundColor Cyan
    Write-Host "  |       PHASE 3 -- VM PROVISIONING              |" -ForegroundColor Cyan
    Write-Host "  |  Mode: $($Config.ProvisioningMode.PadRight(37))|" -ForegroundColor Cyan
    Write-Host "  +==============================================+" -ForegroundColor Cyan

    Invoke-LabVMSetup -Config $Config
}

function Invoke-ElasticLabCleanup {
    <#
    .SYNOPSIS
        Tears down the entire Elastic lab.
        Inventories all components first and only prompts for items found.
        Large downloaded artifacts (ELSER files, Ollama installer, Docker images)
        can each be individually preserved to save re-download time.
    #>
    param([hashtable]$Config)

    Write-Host "`n"
    Write-Host "  +==============================================+" -ForegroundColor Red
    Write-Host "  |           LAB TEARDOWN                       |" -ForegroundColor Red
    Write-Host "  +==============================================+" -ForegroundColor Red

    Invoke-LabCleanup -Config $Config
}

Export-ModuleMember -Function Invoke-ElasticLabBuild, Invoke-ElasticFleetBuild,
                              Invoke-ElasticVMBuild, Invoke-ElasticLabCleanup
