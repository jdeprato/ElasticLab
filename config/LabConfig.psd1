# =============================================================================
# LabConfig.psd1 -- Elastic Lab Master Configuration
# PowerShell Data File -- contains only data, no executable code.
# Loaded by Invoke-ElasticLab.ps1 via Import-PowerShellDataFile.
#
# BEFORE RUNNING:
#   1. Change ES8Password and ES9Password to secure values of your choice.
#   2. Adjust ports if any conflict with existing services on your machine.
#   3. Adjust WindowsVMMemoryMB / LinuxVMMemoryMB to suit your available RAM.
#      Recommended total RAM: 32 GB or more.
#      Minimum total RAM:     24 GB.
# =============================================================================
@{
    # -- Stack selection -------------------------------------------------------
    # Controls which Elasticsearch version(s) to deploy.
    #   "Both" -- Deploy ES8 and ES9 simultaneously (recommended for comparison)
    #   "8"    -- Deploy ES8 only
    #   "9"    -- Deploy ES9 only
    # Can be overridden at runtime with: .\Invoke-ElasticLab.ps1 -Stack 8
    StackMode        = "Both"

    # -- Core paths ------------------------------------------------------------
    # All lab data, containers, VMs, and artifacts live under LabRoot.
    # Ensure the drive has at least 40 GB free (60 GB recommended).
    LabRoot          = "C:\elastic-lab"

    # -- Artifacts folder ------------------------------------------------------
    # All large downloaded artifacts live under LabRoot\artifacts\.
    # Cleanup manages this folder -- each artifact type has a keep/remove prompt
    # so you can preserve what you need across rebuilds.
    #
    #   artifacts\
    #     .vagrant.d\        -- Vagrant box cache (~6 GB Windows, ~600 MB Linux)
    #     agent-installers\  -- Elastic Agent installers (~500 MB each)
    #     installers\        -- Ollama installer (~1.8 GB)
    #     elser-model\       -- ELSER model files (~262 MB)
    #
    # Paths are resolved relative to LabRoot at runtime by Resolve-LabConfig.

    # -- Elasticsearch versions ------------------------------------------------
    # Leave as "8.17.0" / "9.0.0" or pin to specific versions.
    # Set VersionMode = "latest" to auto-resolve the latest available version.
    ES8Version       = "8.17.0"
    ES9Version       = "9.0.0"

    # -- Version selection -----------------------------------------------------
    #   "latest" -- Resolve latest available version from Elastic registry
    #   "pinned" -- Use the versions specified above exactly
    VersionMode      = "latest"

    # -- Credentials -----------------------------------------------------------
    # IMPORTANT: Change these before running. Use strong passwords.
    # These are the passwords for the built-in 'elastic' superuser account.
    ES8Password      = "CHANGE_ME_8"
    ES9Password      = "CHANGE_ME_9"

    # -- Ports -----------------------------------------------------------------
    # External (host) ports Docker maps to each service.
    # Change these if any conflict with existing services on your machine.
    # Internal container ports are always 9200 (ES), 5601 (Kibana), 8220 (Fleet).
    ES8Port          = 9208
    ES9Port          = 9209
    Kibana8Port      = 5601
    Kibana9Port      = 5602
    FleetServer8Port = 8220
    FleetServer9Port = 8221

    # -- Docker registry -------------------------------------------------------
    DockerRegistry   = "docker.elastic.co"

    # -- AI tool selection -----------------------------------------------------
    #   "Both"  -- Deploy ELSER and Ollama
    #   "ELSER" -- Deploy ELSER only (semantic search ML model)
    #   "Ollama" -- Deploy Ollama only (local LLM)
    #   "None"  -- Skip AI tools
    AITool           = "Both"

    # -- ELSER settings --------------------------------------------------------
    ElserModelId     = ".elser_model_2_linux-x86_64"
    ElserModelFile   = "elser_model_2_linux-x86_64"
    ElserModelBase   = "https://ml-models.elastic.co"
    ElserInferenceId = "elser-local"

    # -- Ollama settings -------------------------------------------------------
    OllamaModel           = "llama3.2"
    OllamaPort            = 11434
    OllamaInferenceId     = "ollama-local"
    OllamaInstallerSubPath = "artifacts\installers\OllamaSetup.exe"

    # -- Fleet settings --------------------------------------------------------
    FleetAgentPolicyId8  = "agent-policy-ES8"
    FleetAgentPolicyId9  = "agent-policy-ES9"
    FleetLinuxImage      = "ubuntu:22.04"
    FleetWindowsImage    = "mcr.microsoft.com/windows/servercore:ltsc2022"

    # -- VM provisioning settings ----------------------------------------------
    #   "vagrant"  -- Recommended. Fully automated via Vagrant + Hyper-V.
    #                 Vagrant is installed automatically if winget is available.
    #   "hyperv"   -- Native Hyper-V cmdlets. Requires a Windows Server 2022 ISO.
    #                 Set WindowsISOPath below if using this mode.
    ProvisioningMode     = "vagrant"

    #   "auto"       -- Detect provider at runtime (Hyper-V on Pro/Ent/Edu,
    #                   VirtualBox on Home)
    #   "hyperv"     -- Force Hyper-V
    #   "virtualbox" -- Force VirtualBox
    VagrantProvider      = "auto"

    VagrantWindowsBox    = "gusztavvargadr/windows-server-2022-standard"
    VagrantLinuxBox      = "generic/ubuntu2204"

    # -- VM resource allocation ------------------------------------------------
    # Adjust to match your available RAM.
    # Two Windows VMs + two Linux VMs = ~10 GB total VM RAM at these defaults.
    WindowsVMMemoryMB    = 4096
    WindowsVMCPUs        = 2
    LinuxVMMemoryMB      = 1024
    LinuxVMCPUs          = 1

    # -- Native Hyper-V ISO path (only used when ProvisioningMode = "hyperv") --
    # Download Windows Server 2022 Evaluation ISO from:
    # https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022
    WindowsISOPath       = "C:\ISOs\WindowsServer2022.iso"

    HyperVSwitch         = "Default Switch"

    # -- VM naming -------------------------------------------------------------
    VMDirPrefix          = "vm"
    HyperVVMPrefix       = "elastic-lab"
    VMHostnamePrefix     = "elab"
    VMLogSubfolder       = "logs"

    # -- Windows provisioner staging path (inside the guest VM) ---------------
    WindowsProvisionerGuestPath = 'C:\Windows\Temp\provision-agent.ps1'
}
