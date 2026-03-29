# =============================================================================
# ElasticLab.psd1 -- Module Manifest
# =============================================================================
@{
    ModuleVersion     = "1.0.0"
    GUID              = "a4f2e8c1-3b7d-4e9f-82a1-c5d6e7f80912"
    Author            = "Elastic Lab"
    Description       = "PowerShell module for building and tearing down an Elastic home lab"
    PowerShellVersion = "5.1"
    RootModule        = "ElasticLab.psm1"

    FunctionsToExport = @(
        # Core
        "Write-LabStep", "Write-LabOK", "Write-LabWarn", "Write-LabFail",
        "Write-LabInfo", "Write-LabSkip", "Write-LabFound", "Write-LabMissing",
        "Test-LabCommandExists", "Test-LabElasticHealth", "Test-LabKibanaHealth",
        "Invoke-LabElasticApi", "Invoke-LabElasticApiWithError", "Invoke-LabKibanaApi", "Invoke-LabKibanaApiWithError",
        "Resolve-LabConfig",
        # Preflight
        "Invoke-LabPreflight",
        # Docker
        "Set-LabWslConfig", "New-LabFolderStructure", "Invoke-LabImagePull",
        "New-LabComposeFiles", "Start-LabElasticsearch",
        "Wait-LabElasticsearch", "Set-LabKibanaSystemPassword",
        "Start-LabKibana", "Wait-LabKibana",
        # License
        "Invoke-LabTrialActivation",
        # AI
        "Invoke-LabElserDownload", "Invoke-LabOllamaModelPull",
        "Invoke-LabElserDeployment", "Invoke-LabOllamaEndpointRegistration",
        "Wait-LabElserModel", "Test-LabElserSmoke", "Test-LabOllamaSmoke",
        # Fleet
        "Invoke-LabFleetSetup", "Invoke-LabFleetSetupApi", "Invoke-LabFleetImagePull",
        "Test-LabWindowsContainerSupport", "New-LabFleetFolders",
        "New-LabFleetComposeFile", "New-LabFleetServiceToken",
        "New-LabFleetServerPolicy", "New-LabFleetAgentPolicy",
        "Add-LabFleetServerIntegration", "Set-LabFleetServerHost", "Set-LabFleetOutput",
        "Write-LabFleetEnv", "Start-LabFleetContainers",
        "Wait-LabFleetServer", "Get-LabFleetEnrollmentToken",
        "Start-LabFleetAgent", "Test-LabFleetAgentEnrollment",
        # VMs
        "Invoke-LabVMSetup",
        "Install-LabHyperVPowerShell", "Install-LabVirtualBox",
        "Test-LabHyperV", "Test-LabHyperVSwitch",
        "Test-LabVagrantInstalled", "Install-LabVagrant",
        "Get-LabHyperVGateway", "Get-LabLinuxVHDX",
        "New-LabVMDirectories",
        "New-LabWindowsAgentProvisionerContent", "New-LabLinuxAgentProvisionerContent",
        "New-LabVagrantfileContent",
        "Write-LabWindowsAgentProvisioner", "Write-LabLinuxAgentProvisioner",
        "Write-LabVagrantfile",
        "New-LabHyperVDisk", "New-LabHyperVWindowsVM", "New-LabHyperVLinuxVM",
        "Start-LabVagrantVM", "Test-LabVMAgentEnrollment",
        # Invoke -- top-level phase orchestration
        "Invoke-ElasticLabBuild", "Invoke-ElasticFleetBuild",
        "Invoke-ElasticVMBuild", "Invoke-ElasticLabCleanup",
        # Cleanup
        "Invoke-LabCleanup"
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
