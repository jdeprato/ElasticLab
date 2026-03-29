# =============================================================================
# ElasticLab.VMs.psm1
# VM provisioning: Hyper-V checks, Vagrant install, gateway resolution,
# enrollment token retrieval, directory creation, provisioner script
# generation (content and write are separate), Vagrantfile generation
# (content and write are separate), VM start, and enrollment verification.
# Each function does exactly one thing.
# =============================================================================

# =============================================================================
# Pre-flight unit functions
# =============================================================================

function Install-LabHyperVPowerShell {
    <#
    .SYNOPSIS
        Ensures the Hyper-V PowerShell management tools are installed.
        Vagrant requires these even when Hyper-V itself is already enabled
        by Docker Desktop. Checks first, only installs if missing.
        Returns $true if available (whether pre-existing or just installed).
    #>
    param()

    # Check first -- return immediately if already present
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        Write-LabOK "Hyper-V PowerShell module is available"
        return $true
    }

    Write-LabWarn "Hyper-V PowerShell module not found -- Vagrant requires it"
    Write-Host "  Attempting to install Hyper-V PowerShell management tools..." -ForegroundColor White

    # Try all known feature names across Windows 10/11/Server editions
    $featureNames = @(
        "Microsoft-Hyper-V-Management-PowerShell",
        "Microsoft-Hyper-V-Tools-All",
        "Microsoft-Hyper-V-Management-Clients",
        "Microsoft-Hyper-V-All",
        "Microsoft-Hyper-V"
    )

    foreach ($name in $featureNames) {
        $feature = Get-WindowsOptionalFeature -FeatureName $name -Online -ErrorAction SilentlyContinue
        if (-not $feature) { continue }
        if ($feature.State -eq "Enabled") {
            Write-LabOK "Feature '$name' is already enabled -- checking for Get-VM again..."
            # Refresh module path and retry
            $env:PSModulePath = [System.Environment]::GetEnvironmentVariable("PSModulePath","Machine") + ";" +
                                [System.Environment]::GetEnvironmentVariable("PSModulePath","User")
            if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
                Write-LabOK "Hyper-V PowerShell module is now available"
                return $true
            }
            continue
        }
        try {
            Write-Host "  Trying: Enable-WindowsOptionalFeature -FeatureName $name" -ForegroundColor DarkGray
            $null = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
            Write-LabOK "Hyper-V PowerShell tools installed via '$name'"
            Write-LabWarn "A reboot is required before Vagrant can use the Hyper-V module"
            Write-LabWarn "After rebooting, re-run: .\Invoke-ElasticLab.ps1 -Phase VMs"
            return $true
        } catch {
            Write-Host "  Feature '$name': $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor DarkGray
        }
    }

    # DISM fallback
    Write-Host "  Trying DISM fallback..." -ForegroundColor DarkGray
    $null = dism /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-Management-PowerShell /All /NoRestart 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-LabOK "Hyper-V PowerShell tools installed via DISM"
        Write-LabWarn "A reboot is required -- re-run: .\Invoke-ElasticLab.ps1 -Phase VMs"
        return $true
    }

    # All automatic paths failed -- show exactly what Hyper-V features ARE available
    Write-LabFail "Could not install Hyper-V PowerShell tools automatically"
    Write-Host ""
    Write-Host "  Available Hyper-V related features on this system:" -ForegroundColor Yellow
    Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.FeatureName -match "Hyper" } |
        ForEach-Object { Write-Host "    $($_.FeatureName.PadRight(55)) [$($_.State)]" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  Manual fix options:" -ForegroundColor White
    Write-Host "  Option 1 (recommended):" -ForegroundColor Cyan
    Write-Host "    Press Win+R -> optionalfeatures.exe -> expand 'Hyper-V'" -ForegroundColor White
    Write-Host "    Check 'Hyper-V Management Tools' -> OK -> reboot" -ForegroundColor White
    Write-Host "  Option 2 (PowerShell as Admin):" -ForegroundColor Cyan
    Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All" -ForegroundColor White
    Write-Host "  Option 3 (if running Windows Server):" -ForegroundColor Cyan
    Write-Host "    Install-WindowsFeature -Name Hyper-V-PowerShell" -ForegroundColor White
    Write-Host ""
    return $false
}

function Install-LabVirtualBox {
    <#
    .SYNOPSIS
        Installs VirtualBox silently via winget if not already present.
        VirtualBox works on all Windows editions including Home.
        Returns $true if available after the call.
    #>
    param()

    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
        Write-LabOK "VirtualBox already installed: $(VBoxManage --version 2>&1)"
        return $true
    }

    Write-Host "  Installing VirtualBox via winget..." -ForegroundColor White

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-LabFail "winget not available -- install VirtualBox manually: https://www.virtualbox.org/wiki/Downloads"
        return $false
    }

    winget install --id Oracle.VirtualBox --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-LabFail "VirtualBox install failed -- install manually: https://www.virtualbox.org/wiki/Downloads"
        return $false
    }

    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
        Write-LabOK "VirtualBox installed: $(VBoxManage --version 2>&1)"
        return $true
    }

    Write-LabWarn "VirtualBox installed but VBoxManage not yet on PATH"
    Write-LabWarn "Close and re-open PowerShell as Administrator then re-run"
    return $false
}

function Test-LabHyperV {
    <#
    .SYNOPSIS
        Checks whether Hyper-V is enabled and usable.
        Tries multiple detection methods since feature names vary across
        Windows 10, Windows 11, and Windows Server editions.
        Returns $true if Hyper-V is available, $false if not.
    #>
    param()

    # Method 1: check if Hyper-V PowerShell module is present and Get-VM works
    # Docker Desktop enables Hyper-V but the optional feature may show odd state
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        try {
            $null = Get-VM -ErrorAction Stop
            Write-LabOK "Hyper-V is available (Get-VM succeeded)"
            return $true
        } catch {
            # Get-VM exists but failed -- Hyper-V may still be usable
        }
    }

    # Method 2: check known feature names across Windows editions
    $featureNames = @(
        "Microsoft-Hyper-V-All",
        "Microsoft-Hyper-V",
        "HypervisorPlatform"
    )

    foreach ($name in $featureNames) {
        $feature = Get-WindowsOptionalFeature -FeatureName $name -Online -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -eq "Enabled") {
            Write-LabOK "Hyper-V is enabled (feature: $name)"
            return $true
        }
    }

    # Method 3: check via registry key that Docker Desktop sets
    $hvPresent = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization" `
        -ErrorAction SilentlyContinue
    if ($hvPresent) {
        Write-LabOK "Hyper-V is available (virtualization registry key present)"
        return $true
    }

    # Not found -- attempt to enable the most likely feature name
    Write-LabWarn "Hyper-V not detected -- attempting to enable..."
    $enabled = $false
    foreach ($name in @("Microsoft-Hyper-V-All", "Microsoft-Hyper-V")) {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
            Write-LabWarn "Hyper-V enabled via '$name' -- a reboot may be required"
            $enabled = $true
            break
        } catch {
            # Try next name
        }
    }

    if (-not $enabled) {
        Write-LabWarn "Could not enable Hyper-V automatically"
        Write-LabWarn "Ensure Hyper-V is enabled -- Docker Desktop should have done this already"
        Write-LabWarn "If Docker Desktop is running, Hyper-V is likely available despite detection failure"
    }

    return $false
}

function Test-LabHyperVSwitch {
    <#
    .SYNOPSIS Verifies the named Hyper-V virtual switch exists. #>
    param([string]$SwitchName)

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($switch) {
        Write-LabOK "Hyper-V switch found: $SwitchName"
        return $true
    }
    Write-LabFail "Hyper-V switch '$SwitchName' not found"
    Write-LabFail "Open Hyper-V Manager -> Virtual Switch Manager -> create an External switch named '$SwitchName'"
    return $false
}

function Test-LabVagrantInstalled {
    <#
    .SYNOPSIS Returns $true if Vagrant is found on known paths or PATH. #>
    param()

    return (Test-Path "C:\HashiCorp\Vagrant\bin\vagrant.exe") -or
           (Test-Path "$env:ProgramFiles\Vagrant\bin\vagrant.exe") -or
           [bool](Get-Command vagrant -ErrorAction SilentlyContinue)
}

function Install-LabVagrant {
    <#
    .SYNOPSIS Installs Vagrant silently via winget. Refreshes PATH. Exits if unsuccessful. #>
    param()

    Write-Host "  Installing Vagrant via winget..." -ForegroundColor White

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-LabFail "winget not available -- install Vagrant manually: https://www.vagrantup.com/downloads"
        exit 1
    }

    winget install --id HashiCorp.Vagrant --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-LabFail "Vagrant install failed -- install manually: https://www.vagrantup.com/downloads"
        exit 1
    }
    Write-LabOK "Vagrant installed"

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
        Write-LabWarn "Vagrant not yet on PATH -- close and re-open PowerShell as Administrator then re-run"
        exit 0
    }
    Write-LabOK "Vagrant on PATH: $(vagrant --version 2>&1)"
}

function Get-LabHyperVGateway {
    <#
    .SYNOPSIS
        Resolves the IP address the host presents to Hyper-V VMs on the
        Default Switch -- the address VMs use to reach Fleet Server.
        Tries multiple methods since the interface alias varies by system.
        Returns the IP string, falling back to a detected host IP with a warning.
    #>
    param()

    # Method 1: exact alias "vEthernet (Default Switch)"
    $ip = (Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" `
        -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip) {
        Write-LabOK "Hyper-V Default Switch gateway: $ip"
        return $ip
    }

    # Method 2: any vEthernet interface with "Default" in the alias
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -match "vEthernet.*Default" } |
        Select-Object -First 1).IPAddress
    if ($ip) {
        Write-LabOK "Hyper-V Default Switch gateway: $ip (alias: $(
            (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $ip }).InterfaceAlias
        ))"
        return $ip
    }

    # Method 3: look up the Default Switch in Hyper-V and find its adapter
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $switch = Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue
        if ($switch) {
            $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "vEthernet" -and $_.Status -eq "Up" } |
                Select-Object -First 1
            if ($adapter) {
                $ip = (Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                    -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
                if ($ip) {
                    Write-LabOK "Hyper-V Default Switch gateway: $ip (via adapter: $($adapter.Name))"
                    return $ip
                }
            }
        }
    }

    # Method 4: use the first non-loopback, non-APIPA IPv4 on any adapter
    # that looks like a Hyper-V virtual adapter
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch "^127\." -and
            $_.IPAddress -notmatch "^169\.254\." -and
            $_.InterfaceAlias -match "vEthernet|Hyper-V|Virtual"
        } | Select-Object -First 1).IPAddress
    if ($ip) {
        Write-LabOK "Hyper-V gateway (fallback detection): $ip"
        return $ip
    }

    # All methods failed
    Write-LabWarn "Could not detect Default Switch gateway automatically"
    Write-LabWarn "VMs will not be able to reach Fleet Server with the fallback IP"
    Write-LabWarn "After VMs start, find the correct IP with:"
    Write-LabWarn "  Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -match vEthernet"
    Write-LabWarn "Then update Fleet URL in Kibana: Fleet -> Settings -> Fleet Server hosts"
    return "192.168.0.1"
}

function Get-LabLinuxVHDX {
    <#
    .SYNOPSIS
        Ensures the Ubuntu 22.04 cloud VHDX is present at the given path.
        Downloads it if not already present.
    #>
    param([string]$VHDXPath)

    if (Test-Path $VHDXPath) {
        Write-LabOK "Linux VHDX already present: $VHDXPath"
        return $true
    }

    New-Item -ItemType Directory -Path (Split-Path $VHDXPath) -Force | Out-Null
    $url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.vhdx"
    Write-Host "  Downloading Ubuntu 22.04 cloud VHDX..." -ForegroundColor White
    try {
        Invoke-WebRequest -Uri $url -OutFile $VHDXPath `
            -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        Write-LabOK "Ubuntu VHDX downloaded: $VHDXPath"
        return $true
    } catch {
        Write-LabFail "Failed to download Ubuntu VHDX: $_"
        Write-LabFail "Download manually from: $url"
        Write-LabFail "Save to: $VHDXPath"
        return $false
    }
}

# =============================================================================
# Directory creation
# =============================================================================

function New-LabVMDirectories {
    <#
    .SYNOPSIS
        Creates VM working directories and log subdirectories under LabRoot.
        Derives all paths from Config.VMDefs set by Resolve-LabConfig.
    #>
    param([hashtable]$Config)

    foreach ($vm in $Config.VMDefs) {
        New-Item -ItemType Directory -Path $vm.Dir    -Force | Out-Null
        New-Item -ItemType Directory -Path $vm.LogDir -Force | Out-Null
        Write-LabOK "Created: $($vm.Dir)"
    }
}

# =============================================================================
# Provisioner content builders (pure functions -- no disk writes)
# =============================================================================

function New-LabWindowsAgentProvisionerContent {
    <#
    .SYNOPSIS
        Builds and returns the PowerShell provisioner script content for a Windows VM.
        If PreStagedZip is provided the script skips the download and uses the
        pre-copied file instead. Does not write to disk.
    #>
    param(
        [string]$Stack,
        [string]$AgentVersion,
        [string]$FleetUrl,
        [string]$EnrollToken,
        [string]$PreStagedZip = ""   # Guest path if pre-staged, empty to download
    )

    $tokenValue = if ($EnrollToken) { $EnrollToken } else { "NONE" }

    # Build the download-or-use-staged block
    if ($PreStagedZip) {
        $downloadBlock = @"
`$zipDest = "$PreStagedZip"
if (Test-Path `$zipDest) {
    Write-Host "  Using pre-staged installer: `$zipDest" -ForegroundColor Green
    Write-Host "  Size: `$([Math]::Round((Get-Item `$zipDest).Length / 1MB, 1)) MB" -ForegroundColor Green
} else {
    Write-Host "  Pre-staged file not found at `$zipDest -- downloading..." -ForegroundColor Yellow
    `$zipUrl = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-`$AgentVersion-windows-x86_64.zip"
    try {
        Invoke-WebRequest -Uri `$zipUrl -OutFile `$zipDest -UseBasicParsing -TimeoutSec 600
        Write-Host "  Downloaded (`$([Math]::Round((Get-Item `$zipDest).Length / 1MB, 1)) MB)" -ForegroundColor Green
    } catch {
        Write-Host "  FAILED to download: `$_" -ForegroundColor Red ; exit 1
    }
}
"@
    } else {
        $downloadBlock = @"
`$zipUrl  = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-`$AgentVersion-windows-x86_64.zip"
`$zipDest = "C:\Windows\Temp\elastic-agent-`$AgentVersion.zip"
Write-Host "  Downloading Elastic Agent `$AgentVersion..." -ForegroundColor White
try {
    Invoke-WebRequest -Uri `$zipUrl -OutFile `$zipDest -UseBasicParsing -TimeoutSec 600
    Write-Host "  Downloaded (`$([Math]::Round((Get-Item `$zipDest).Length / 1MB, 1)) MB)" -ForegroundColor Green
} catch {
    Write-Host "  FAILED to download: `$_" -ForegroundColor Red ; exit 1
}
"@
    }

    return @"
# Elastic Agent provisioner for Windows Server VM -- $Stack
# Generated by ElasticLab
`$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

`$AgentVersion   = "$AgentVersion"
`$FleetUrl       = "$FleetUrl"
`$EnrollToken    = "$tokenValue"
`$Stack          = "$Stack"
`$extractDir     = "C:\Windows\Temp\elastic-agent-extract"

Write-Host "`n=== Elastic Agent Install (`$Stack) ===" -ForegroundColor Cyan

if (`$EnrollToken -eq "NONE") {
    Write-Host "  No enrollment token provided -- skipping agent install" -ForegroundColor Yellow
    Write-Host "  Get a token from Kibana -> Fleet -> Enrollment Tokens" -ForegroundColor Yellow
    Write-Host "  Then run: vagrant provision" -ForegroundColor Yellow
    exit 0
}

if (Get-Service -Name "Elastic Agent" -ErrorAction SilentlyContinue) {
    Write-Host "  Elastic Agent service already present -- skipping install" -ForegroundColor Yellow
    exit 0
}

$downloadBlock

Write-Host "  Extracting..." -ForegroundColor White
New-Item -ItemType Directory -Path `$extractDir -Force | Out-Null
Expand-Archive -Path `$zipDest -DestinationPath `$extractDir -Force

`$agentExe = Get-ChildItem -Path `$extractDir -Filter "elastic-agent.exe" -Recurse | Select-Object -First 1
if (-not `$agentExe) {
    Write-Host "  ERROR: elastic-agent.exe not found after extraction" -ForegroundColor Red ; exit 1
}

Write-Host "  Installing and enrolling into `$FleetUrl..." -ForegroundColor White
& `$agentExe.FullName install ``
    --url=`$FleetUrl ``
    --enrollment-token=`$EnrollToken ``
    --insecure ``
    --non-interactive ``
    --tag="windows-lab,vagrant,`$Stack"

if (`$LASTEXITCODE -eq 0) { Write-Host "  [OK] Elastic Agent installed and enrolled" -ForegroundColor Green }
else                       { Write-Host "  [--] Agent install exit code `$LASTEXITCODE (service restart is normal)" -ForegroundColor Yellow }

Remove-Item `$zipDest  -Force -ErrorAction SilentlyContinue
Remove-Item `$extractDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "=== Windows Agent Provisioning Complete ===" -ForegroundColor Cyan
exit 0
"@
}

function New-LabLinuxAgentProvisionerContent {
    <#
    .SYNOPSIS
        Builds and returns the bash provisioner script content for a Linux VM.
        Uses a single-quoted here-string so bash constructs like $() and ${} are
        never evaluated by PowerShell. The four PS variables are substituted
        via -replace after the here-string is captured.
        Does not write to disk -- caller passes to Write-LabLinuxAgentProvisioner.
    #>
    param(
        [string]$Stack,
        [string]$AgentVersion,
        [string]$FleetUrl,
        [string]$EnrollToken,
        [string]$PreStagedTarball = ""   # Guest path if pre-staged, empty to download
    )

    $tokenValue = if ($EnrollToken) { $EnrollToken } else { "NONE" }

    # Build download-or-use-staged block as a placeholder for substitution
    if ($PreStagedTarball) {
        $downloadBlock = @'
TARBALL="__TARBALL_NAME__"
# File was pre-copied by Vagrant file provisioner to /tmp/$TARBALL
if [ -f "/tmp/$TARBALL" ]; then
  echo "  Using pre-staged installer: /tmp/$TARBALL"
else
  echo "  Pre-staged file not found -- downloading..."
  wget -q "https://artifacts.elastic.co/downloads/beats/elastic-agent/$TARBALL" -O "/tmp/$TARBALL"
fi
'@
        $tgzName = Split-Path $PreStagedTarball -Leaf
        $downloadBlock = $downloadBlock `
            -replace "__TARBALL_NAME__", $tgzName
    } else {
        $downloadBlock = @'
TARBALL="elastic-agent-__AGENT_VERSION__-linux-x86_64.tar.gz"
echo "  Downloading Elastic Agent __AGENT_VERSION__..."
wget -q "https://artifacts.elastic.co/downloads/beats/elastic-agent/$TARBALL" -O "/tmp/$TARBALL"
'@
        $downloadBlock = $downloadBlock -replace "__AGENT_VERSION__", $AgentVersion
    }

    # Single-quoted here-string -- PowerShell will NOT expand anything inside.
    # Placeholders are substituted below.
    $template = @'
#!/bin/bash
# Elastic Agent provisioner for Linux VM -- __STACK__
# Generated by ElasticLab

AGENT_VERSION="__AGENT_VERSION__"
FLEET_URL="__FLEET_URL__"
ENROLL_TOKEN="__ENROLL_TOKEN__"
STACK="__STACK__"

echo ""
echo "=== Elastic Agent Install ($STACK) ==="

if [ "$ENROLL_TOKEN" = "NONE" ]; then
    echo "  No enrollment token provided -- skipping"
    echo "  Get a token from Kibana -> Fleet -> Enrollment Tokens"
    echo "  Then run: vagrant provision"
    exit 0
fi

if systemctl is-active --quiet elastic-agent 2>/dev/null; then
    echo "  Elastic Agent already running -- skipping install"
    exit 0
fi

__DOWNLOAD_BLOCK__
echo "  Downloaded: $(du -sh /tmp/$TARBALL | cut -f1)"

echo "  Extracting..."
cd /tmp
tar -xzf "$TARBALL"
EXTRACT_DIR="${TARBALL%.tar.gz}"

echo "  Installing and enrolling into $FLEET_URL..."
cd "/tmp/$EXTRACT_DIR"
./elastic-agent install \
    --url="$FLEET_URL" \
    --enrollment-token="$ENROLL_TOKEN" \
    --insecure \
    --non-interactive \
    --tag="linux-lab,vagrant,$STACK"

echo "  [OK] Elastic Agent installed and enrolled"

cd /tmp
rm -rf "/tmp/$EXTRACT_DIR" "/tmp/$TARBALL"
echo "=== Linux Agent Provisioning Complete ==="
exit 0
'@

    return $template `
        -replace '__STACK__',          $Stack `
        -replace '__AGENT_VERSION__',  $AgentVersion `
        -replace '__FLEET_URL__',      $FleetUrl `
        -replace '__ENROLL_TOKEN__',   $tokenValue `
        -replace '__DOWNLOAD_BLOCK__', $downloadBlock
}

function New-LabVagrantfileContent {
    <#
    .SYNOPSIS
        Builds and returns the Vagrantfile content for one VM.
        Supports both hyperv and virtualbox providers.
        Does not write to disk -- caller passes to Write-LabVagrantfile.
    #>
    param(
        [string]$Box,
        [string]$Hostname,
        [string]$VMName,
        [int]   $MemoryMB,
        [int]   $CPUs,
        [string]$Communicator,
        [string]$ProvisionerSrc,
        [string]$ProvisionerDst,
        [string]$RunCommand,
        [string]$VagrantUser,
        [string]$VagrantPassword,
        [string]$Provider = "hyperv",
        [string]$ExtraProvisionBlock = "",
        [bool]  $EnableNestedVirt = $false
    )

    $winrmBlock = ""
    if ($Communicator -eq "winrm") {
        $winrmBlock = @"
  config.vm.communicator    = "winrm"
  config.winrm.username     = "$VagrantUser"
  config.winrm.password     = "$VagrantPassword"
  config.winrm.timeout      = 300
  config.winrm.retry_limit  = 20
  config.vm.boot_timeout    = 900
"@
    }

    $nestedVirtRuby = if ($EnableNestedVirt) { "true" } else { "false" }

    $hypervBlock = @"
  config.vm.provider "hyperv" do |h|
    h.vmname        = "$VMName"
    h.memory        = $MemoryMB
    h.maxmemory     = $MemoryMB
    h.cpus          = $CPUs
    h.enable_virtualization_extensions = $nestedVirtRuby
    h.linked_clone  = false
    h.auto_start_action = "Nothing"
    h.auto_stop_action  = "ShutDown"
  end
"@

    $vboxBlock = @"
  config.vm.provider "virtualbox" do |v|
    v.name   = "$VMName"
    v.memory = $MemoryMB
    v.cpus   = $CPUs
    v.gui    = false
    v.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
  end
"@

    $providerBlock = if ($Provider -eq "virtualbox") { $vboxBlock } else { $hypervBlock }

    $networkLine = if ($Provider -eq "hyperv") {
        '  config.vm.network "public_network", bridge: "Default Switch"'
    } else {
        '  config.vm.network "private_network", type: "dhcp"'
    }

    return @"
# -*- mode: ruby -*-
# Elastic Lab VM -- $VMName
# Generated by ElasticLab

Vagrant.configure("2") do |config|
  config.vm.box      = "$Box"
  config.vm.hostname = "$Hostname"

$providerBlock

$networkLine
  config.vm.synced_folder ".", "/vagrant", disabled: true

$winrmBlock
$ExtraProvisionBlock

  config.vm.provision "file",
    source:      "$ProvisionerSrc",
    destination: "$ProvisionerDst"

  config.vm.provision "shell",
    privileged: true,
    inline:     "$RunCommand; exit 0"

end
"@
}

# =============================================================================
# Provisioner and Vagrantfile writers (disk write -- separate from content build)
# =============================================================================

function Write-LabWindowsAgentProvisioner {
    <#
    .SYNOPSIS Writes Windows provisioner script content to disk. #>
    param([string]$Content, [string]$OutputPath)

    Set-Content -Path $OutputPath -Value $Content
    Write-LabOK "Windows provisioner written: $OutputPath"
}

function Write-LabLinuxAgentProvisioner {
    <#
    .SYNOPSIS Writes Linux provisioner script content to disk with LF line endings. #>
    param([string]$Content, [string]$OutputPath)

    Set-Content -Path $OutputPath -Value $Content
    # Normalise to LF line endings for bash compatibility
    (Get-Content $OutputPath -Raw) -replace "`r`n","`n" | Set-Content $OutputPath -NoNewline
    Write-LabOK "Linux provisioner written: $OutputPath"
}

function Write-LabVagrantfile {
    <#
    .SYNOPSIS
        Writes Vagrantfile content to disk.
        Always overwrites -- if content changed and VM is running,
        warns that vagrant provision or destroy+up is needed.
    #>
    param([string]$Content, [string]$Dir)

    $path = Join-Path $Dir "Vagrantfile"

    # Check if content changed from what's on disk
    if (Test-Path $path) {
        $existing = Get-Content $path -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Trim() -ne $Content.Trim()) {
            Write-LabWarn "Vagrantfile changed -- if VM is running, run: vagrant destroy -f && vagrant up"
        }
    }

    Set-Content -Path $path -Value $Content
    Write-LabOK "Vagrantfile written: $path"
}

# =============================================================================
# Hyper-V native VM creation (one function per concern)
# =============================================================================

function New-LabHyperVDisk {
    <#
    .SYNOPSIS Creates a dynamic VHDX disk for a VM. Returns the path. #>
    param([string]$VMName, [string]$DiskDir, [int]$SizeGB = 60)

    $path = Join-Path $DiskDir "$VMName.vhdx"
    if (-not (Test-Path $path)) {
        New-VHD -Path $path -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
        Write-LabOK "Created VHDX: $path"
    } else {
        Write-LabInfo "VHDX already exists: $path"
    }
    return $path
}

function New-LabHyperVWindowsVM {
    <#
    .SYNOPSIS
        Creates a Windows VM from ISO via Hyper-V cmdlets.
        Attaches DVD, sets boot order, disables Secure Boot.
    #>
    param(
        [string]$VMName,
        [string]$VHDXPath,
        [string]$ISOPath,
        [string]$SwitchName,
        [int]   $MemoryMB,
        [int]   $CPUs
    )

    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabInfo "VM already exists: $VMName -- skipping creation"
        return
    }

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) `
        -VHDPath $VHDXPath -Generation 2 -SwitchName $SwitchName | Out-Null

    Set-VM -Name $VMName -ProcessorCount $CPUs -DynamicMemory:$false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

    Add-VMDvdDrive -VMName $VMName -Path $ISOPath

    $dvd  = Get-VMDvdDrive      -VMName $VMName
    $disk = Get-VMHardDiskDrive -VMName $VMName
    Set-VMFirmware -VMName $VMName -BootOrder $dvd, $disk
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

    Write-LabOK "Windows VM created: $VMName"
}

function New-LabHyperVLinuxVM {
    <#
    .SYNOPSIS
        Creates a Linux VM from a cloud VHDX via Hyper-V cmdlets.
        Copies the base VHDX so each VM has its own disk, then starts the VM.
    #>
    param(
        [string]$VMName,
        [string]$BaseVHDXPath,
        [string]$DiskDir,
        [string]$SwitchName,
        [int]   $MemoryMB,
        [int]   $CPUs
    )

    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabInfo "VM already exists: $VMName -- skipping creation"
        return
    }

    $vmVHDX = Join-Path $DiskDir "$VMName.vhdx"
    if (-not (Test-Path $vmVHDX)) {
        Copy-Item -Path $BaseVHDXPath -Destination $vmVHDX
        Write-LabOK "Copied cloud image to $vmVHDX"
    }

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) `
        -VHDPath $vmVHDX -Generation 1 -SwitchName $SwitchName | Out-Null

    Set-VM -Name $VMName -ProcessorCount $CPUs -DynamicMemory:$false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

    Start-VM -Name $VMName
    Write-LabOK "Linux VM created and started: $VMName"
}

# =============================================================================
# VM start functions
# =============================================================================

function Invoke-VagrantUp {
    <#
    .SYNOPSIS
        Runs vagrant up with --machine-readable output, tailing the log file
        in real time and translating CSV lines into friendly status messages.
        Uses Start-Process with -WorkingDirectory so vagrant finds the Vagrantfile.
        Returns $true if vagrant exited with code 0.
    #>
    param([string]$Provider, [string]$Label, [string]$Dir)

    $logFile = Join-Path $Dir "vagrant-up.log"
    $errFile = Join-Path $Dir "vagrant-up-err.log"

    $stageMap = [ordered]@{
        "Bringing machine"            = "Starting VM..."
        "Importing a Hyper-V"         = "Importing Hyper-V box image..."
        "Importing base box"          = "Importing VirtualBox base box..."
        "Preparing SMB"               = "Preparing SMB shared folders..."
        "Mounting SMB"                = "Mounting shared folders..."
        "Waiting for the machine"     = "Waiting for VM to get an IP address..."
        "Waiting for machine to boot" = "Waiting for VM to boot and WinRM/SSH..."
        "Machine booted"              = "VM booted and communicator ready"
        "Setting hostname"            = "Setting VM hostname..."
        "Configuring and enabling"    = "Configuring network interfaces..."
        "Running provisioner"         = "Running provisioner scripts..."
        "Running: inline"             = "Running inline provisioner..."
        "Uploading"                   = "Uploading provisioner file to VM..."
        "Machine already running"     = "VM is already running"
        "successfully provisioned"    = "Provisioning complete"
    }

    $lastStage = ""; $downloadActive = $false

    $proc = Start-Process -FilePath "vagrant" `
        -ArgumentList "up --provider $Provider --machine-readable" `
        -WorkingDirectory $Dir `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError  $errFile

    $pos = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $logFile)) { continue }
        $raw = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        if (-not $raw -or $raw.Length -le $pos) { continue }
        $newContent = $raw.Substring($pos); $pos = $raw.Length

        foreach ($line in ($newContent -split "`n")) {
            $line = $line.Trim(); if (-not $line) { continue }
            $parts = $line -split ",", 5
            if ($parts.Count -lt 4) { continue }
            $type = $parts[2].Trim()
            $data = ($parts[3..($parts.Count-1)] -join ",") `
                -replace "%!\(VAGRANT_COMMA\)!", "," `
                -replace "\\n", " " -replace "\\r", ""

            switch ($type) {
                "ui" {
                    $uiParts = $data -split ",", 2
                    $msg = if ($uiParts.Count -gt 1) { $uiParts[1].Trim() } else { $data.Trim() }
                    if (-not $msg) { continue }

                    if ($msg -match "\d+[\.,]\d+\s*(MB|KB|GB|%|M\/s|bytes)") {
                        if (-not $downloadActive) {
                            Write-Host "  [$Label] Downloading box..." -ForegroundColor DarkCyan
                            $downloadActive = $true
                        }
                        Write-Host "`r  [$Label] $msg" -NoNewline -ForegroundColor DarkGray
                        continue
                    }
                    if ($downloadActive) { Write-Host ""; $downloadActive = $false }

                    $matched = $false
                    foreach ($pattern in $stageMap.Keys) {
                        if ($msg -match [regex]::Escape($pattern)) {
                            $friendly = $stageMap[$pattern]
                            if ($friendly -ne $lastStage) {
                                Write-Host "  [$Label] $friendly" -ForegroundColor DarkCyan
                                $lastStage = $friendly
                            }
                            $matched = $true; break
                        }
                    }
                    if (-not $matched -and $msg.Length -gt 3 -and $msg -notmatch "^==>") {
                        Write-Host "  [$Label] $msg" -ForegroundColor DarkGray
                    }
                }
                "state" {
                    $state = $data.Trim()
                    if ($state -eq "running") {
                        Write-Host "  [$Label] VM is running" -ForegroundColor Green
                    }
                }
                "error-exit" {
                    if ($downloadActive) { Write-Host ""; $downloadActive = $false }
                    Write-Host "  [$Label] [!!] $data" -ForegroundColor Red
                }
            }
        }
    }
    if ($downloadActive) { Write-Host "" }
    $proc.WaitForExit()

    # Check exit code -- but also inspect the log for known success indicators.
    # The Elastic Agent installer restarts its daemon as a final step, which
    # abruptly closes the WinRM/SSH session causing vagrant to report a non-zero
    # exit code even though the agent installed and enrolled successfully.
    $vagrantExitOk = ($proc.ExitCode -eq 0)

    if (-not $vagrantExitOk -and (Test-Path $logFile)) {
        $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        $successIndicators = @(
            "Elastic Agent has been successfully installed",
            "Successfully enrolled the Elastic Agent",
            "Agent Provisioning Complete"
        )
        $foundSuccess = $false
        foreach ($indicator in $successIndicators) {
            if ($logContent -match [regex]::Escape($indicator)) {
                $foundSuccess = $true
                break
            }
        }
        if ($foundSuccess) {
            Write-LabOK "$Label -- agent installed and enrolled (exit code ignored -- daemon restart)"
            return $true
        }
    }

    return $vagrantExitOk
}

function Start-LabVagrantVM {
    <#
    .SYNOPSIS
        Runs vagrant up for one VM directory using the configured provider.
        If the VM is already running, skips start. Returns $true on success.
    #>
    param([string]$Dir, [string]$Label, [string]$Provider = "hyperv", [string]$VagrantHome = "")

    Write-Host "`n  Starting $Label..." -ForegroundColor White

    if (-not (Test-Path $Dir)) {
        Write-LabWarn "$Label -- VM directory not found: $Dir"
        return $false
    }

    # Set VAGRANT_HOME so boxes are cached inside the project folder.
    # Set at Machine scope so it persists and is inherited by all child processes
    # including those launched via Start-Process.
    if ($VagrantHome) {
        New-Item -ItemType Directory -Path $VagrantHome -Force | Out-Null
        [System.Environment]::SetEnvironmentVariable("VAGRANT_HOME", $VagrantHome, "Machine")
        $env:VAGRANT_HOME = $VagrantHome
    }

    # Check if already running using machine-readable status
    Push-Location $Dir
    $statusOutput = vagrant status --machine-readable 2>&1
    Pop-Location
    $isRunning = $statusOutput | Select-String ",state,running"

    if ($isRunning) {
        Write-LabOK "$Label is already running -- skipping vagrant up"
        return $true
    }

    $ok = Invoke-VagrantUp -Provider $Provider -Label $Label -Dir $Dir

    if ($ok) {
        Write-LabOK "$Label started and provisioned"
    } else {
        Write-LabWarn "$Label -- vagrant up exited with non-zero code"
        Write-LabWarn "Common issues:"
        if ($Provider -eq "hyperv") {
            Write-LabWarn "  - SMB credentials prompt: enter your Windows host credentials"
            Write-LabWarn "  - Hyper-V PowerShell module: reboot after installing tools"
        } elseif ($Provider -eq "virtualbox") {
            Write-LabWarn "  - VirtualBox not installed or VBoxManage not on PATH"
        }
        Write-LabWarn "  - Token expired: re-run or use: vagrant provision"
        Write-LabWarn "  - Full log: $logFile"
    }
    return $ok
}

# =============================================================================
# Enrollment verification
# =============================================================================

function Test-LabVMAgentEnrollment {
    <#
    .SYNOPSIS
        Queries Kibana Fleet to verify VM-based agents are enrolled for one stack.
    #>
    param([hashtable]$Stack)

    $label = $Stack.Label
    $r = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/agents?perPage=100" `
        -Password $Stack.Password

    if (-not ($r -and $r.StatusCode -eq 200)) {
        Write-LabWarn "[$label] Could not query Fleet agents API"
        return
    }

    $agents    = ($r.Content | ConvertFrom-Json).items
    $vmAgents  = $agents | Where-Object {
        $_.tags -contains "windows-lab" -or $_.tags -contains "linux-lab"
    }
    $total = ($agents | Measure-Object).Count

    if ($vmAgents) {
        Write-LabOK "[$label] $($vmAgents.Count) VM agent(s) enrolled:"
        foreach ($a in $vmAgents) {
            Write-LabOK "  -> $($a.local_metadata.host.hostname) ($($a.local_metadata.os.name)) -- $($a.status)"
        }
    } else {
        Write-LabWarn "[$label] No VM agents visible yet ($total total in Fleet)"
        Write-LabWarn "[$label] Agents may still be starting -- check Kibana in a few minutes"
    }
}

# =============================================================================
# Orchestration function
# =============================================================================

function Invoke-LabVMSetup {
    <#
    .SYNOPSIS
        Orchestrates the full VM setup for all active stacks.
        Handles both Vagrant and native Hyper-V provisioning modes.
        Calls each unit function in the correct order.
    #>
    param([hashtable]$Config)

    Write-LabStep "VMs -- Pre-flight"

    if ($Config.ProvisioningMode -notin @("vagrant","hyperv")) {
        Write-LabFail "Invalid ProvisioningMode '$($Config.ProvisioningMode)'. Must be 'vagrant' or 'hyperv'."
        exit 1
    }
    Write-LabInfo "Provisioning mode: $($Config.ProvisioningMode)"


    # Report which provider is in use and why
    Write-LabInfo "Vagrant provider: $($Config.VagrantProvider) [$($Config.VagrantProviderSource)]"

    # Provider-specific pre-flight
    if ($Config.ProvisioningMode -eq "vagrant" -and $Config.VagrantProvider -eq "hyperv") {
        $hvOk = Test-LabHyperV
        if (-not $hvOk) {
            Write-LabWarn "Hyper-V detection was inconclusive"
            Write-LabWarn "If Docker Desktop is running, Hyper-V is available -- continuing"
        }

        # Check if Hyper-V PowerShell module is available BEFORE attempting install
        $moduleAvailableBefore = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)

        $psModuleOk = Install-LabHyperVPowerShell
        if (-not $psModuleOk) {
            Write-LabFail "Hyper-V PowerShell module unavailable -- Vagrant cannot start VMs"
            Write-LabFail "Enable 'Hyper-V Management Tools' in Windows Features and reboot, then re-run"
            Write-LabFail "Or set VagrantProvider = 'virtualbox' in LabConfig.psd1 to use VirtualBox instead"
            exit 1
        }

        # If module was not available before but Install returned true, it was
        # just installed this session -- a reboot is required before Vagrant can use it
        $moduleAvailableNow = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
        if (-not $moduleAvailableBefore -and -not $moduleAvailableNow) {
            Write-Host ""
            Write-Host "  +==============================================+" -ForegroundColor Yellow
            Write-Host "  |         REBOOT REQUIRED                      |" -ForegroundColor Yellow
            Write-Host "  |                                              |" -ForegroundColor Yellow
            Write-Host "  |  Hyper-V PowerShell tools were installed     |" -ForegroundColor Yellow
            Write-Host "  |  but require a reboot to activate.           |" -ForegroundColor Yellow
            Write-Host "  |                                              |" -ForegroundColor Yellow
            Write-Host "  |  After rebooting, re-run:                   |" -ForegroundColor Yellow
            Write-Host "  |    .\Invoke-ElasticLab.ps1 -Phase VMs       |" -ForegroundColor Yellow
            Write-Host "  +==============================================+" -ForegroundColor Yellow
            Write-Host ""
            exit 0
        }
    } elseif ($Config.ProvisioningMode -eq "vagrant" -and $Config.VagrantProvider -eq "virtualbox") {
        $vbOk = Install-LabVirtualBox
        if (-not $vbOk) { exit 1 }
    }

    foreach ($stack in $Config.ActiveStacks) {
        if (-not (Test-LabElasticHealth -Port $stack.ESPort -Password $stack.Password)) {
            Write-LabFail "[$($stack.Label)] Elasticsearch not reachable -- run Invoke-BuildElasticLab.ps1 first"
            exit 1
        }
        Write-LabOK "[$($stack.Label)] Elasticsearch reachable"

        try {
            Invoke-WebRequest -Uri "http://localhost:$($stack.FleetPort)/api/status" `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            Write-LabOK "[$($stack.Label)] Fleet Server reachable on port $($stack.FleetPort)"
        } catch {
            Write-LabWarn "[$($stack.Label)] Fleet Server not reachable -- agents will need manual enrollment"
        }
    }

    if ($Config.ProvisioningMode -eq "hyperv") {
        if (-not (Test-Path $Config.WindowsISOPath)) {
            Write-LabFail "Windows Server ISO not found at: $($Config.WindowsISOPath)"
            Write-LabFail "Download: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022"
            exit 1
        }
        Write-LabOK "Windows ISO found: $($Config.WindowsISOPath)"
        if (-not (Test-LabHyperVSwitch -SwitchName $Config.HyperVSwitch)) { exit 1 }
    }

    # Set VAGRANT_HOME early so all vagrant calls in this phase use the project folder
    if ($Config.VagrantHome) {
        New-Item -ItemType Directory -Path $Config.VagrantHome -Force | Out-Null
        [System.Environment]::SetEnvironmentVariable("VAGRANT_HOME", $Config.VagrantHome, "Machine")
        $env:VAGRANT_HOME = $Config.VagrantHome
        Write-LabInfo "VAGRANT_HOME set to: $($Config.VagrantHome)"
    }

    # Step 1 -- Retrieve enrollment tokens and resolve Fleet URLs
    Write-LabStep "VMs -- Retrieve Enrollment Tokens"

    $gateway  = $Config.HostIP
    $tokens   = @{}
    $fleetUrls = @{}

    # Re-apply fleet-default-output fix here as a safety net.
    # Fleet Server may have reset fleet-default-output after the Fleet phase completed.
    # VM agents pick up their output config at enrollment time so this must be
    # correct before any VM starts enrolling.
    Write-LabStep "VMs -- Verify Fleet Outputs"
    foreach ($stack in $Config.ActiveStacks) {
        Set-LabFleetOutput -Stack $stack -Config $Config
    }

    Write-LabInfo "Host IP for VM Fleet enrollment: $gateway"
    foreach ($stack in $Config.ActiveStacks) {
        $fleetUrls[$stack.Label] = "http://${gateway}:$($stack.FleetPort)"
        Write-LabInfo "[$($stack.Label)] Fleet URL from VM: $($fleetUrls[$stack.Label])"

        $r = Invoke-LabKibanaApi -Method GET `
            -Uri "http://localhost:$($stack.KibanaPort)/api/fleet/enrollment_api_keys" `
            -Password $stack.Password
        if ($r -and $r.StatusCode -eq 200) {
            $token = ($r.Content | ConvertFrom-Json).items |
                Where-Object { $_.policy_id -eq $stack.AgentPolicyId } |
                Select-Object -First 1
            if ($token) {
                $tokens[$stack.Label] = $token.api_key
                Write-LabOK "[$($stack.Label)] Enrollment token retrieved"
            } else {
                Write-LabWarn "[$($stack.Label)] No token for policy '$($stack.AgentPolicyId)' -- agents will need manual enrollment"
            }
        }
    }

    # Step 2 -- Vagrant install or VHDX download
    Write-LabStep "VMs -- Prepare Provisioning Tools"

    if ($Config.ProvisioningMode -eq "vagrant") {
        if (Test-LabVagrantInstalled) {
            Write-LabOK "Vagrant already installed: $(vagrant --version 2>&1)"
        } else {
            Install-LabVagrant
        }
    } else {
        $linuxVHDXPath = Join-Path $Config.LabRoot "vm-images\ubuntu-22.04-cloudimg.vhdx"
        if (-not (Get-LabLinuxVHDX -VHDXPath $linuxVHDXPath)) { exit 1 }
    }

    # Step 3 -- Create VM directories
    Write-LabStep "VMs -- Create Directories"
    New-LabVMDirectories -Config $Config

    # Step 3b -- Pre-download agent installers on the host
    # Avoids slow in-VM downloads through Hyper-V NAT -- files are
    # copied into VMs via Vagrant file provisioner instead.
    Write-LabStep "VMs -- Pre-download Agent Installers"
    $agentCacheDir = $Config.AgentInstallerCache
    New-Item -ItemType Directory -Path $agentCacheDir -Force | Out-Null
    Write-LabInfo "Agent installer cache: $agentCacheDir"

    # Prune any cached installers that don't match an active stack version
    $activeFiles = @()
    foreach ($stack in $Config.ActiveStacks) {
        $activeFiles += "elastic-agent-$($stack.Version)-windows-x86_64.zip"
        $activeFiles += "elastic-agent-$($stack.Version)-linux-x86_64.tar.gz"
    }
    $cachedFiles = Get-ChildItem $agentCacheDir -File -ErrorAction SilentlyContinue
    foreach ($f in $cachedFiles) {
        if ($f.Name -notin $activeFiles) {
            $staleMB = [Math]::Round($f.Length / 1MB, 1)
            Write-LabInfo "Removing stale cached installer: $($f.Name) ($staleMB MB)"
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $downloadedInstallers = @{}
    foreach ($stack in $Config.ActiveStacks) {
        $version = $stack.Version
        $winZip   = "elastic-agent-$version-windows-x86_64.zip"
        $linuxTgz = "elastic-agent-$version-linux-x86_64.tar.gz"

        foreach ($pkg in @(@{File=$winZip;OS="windows"}, @{File=$linuxTgz;OS="linux"})) {
            $destPath = Join-Path $agentCacheDir $pkg.File
            if (Test-Path $destPath) {
                $sizeMB = [Math]::Round((Get-Item $destPath).Length / 1MB, 1)
                Write-LabOK "Already cached: $($pkg.File) ($sizeMB MB)"
                $downloadedInstallers["$($stack.Label)-$($pkg.OS)"] = $destPath
                continue
            }

            $url = "https://artifacts.elastic.co/downloads/beats/elastic-agent/$($pkg.File)"
            Write-Host "  Downloading $($pkg.File)..." -ForegroundColor White

            # Run download in a background job so we can poll progress
            $job = Start-Job -ScriptBlock {
                param($u, $d)
                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($u, $d)
            } -ArgumentList $url, $destPath

            # Poll the partial file size while downloading
            while ($job.State -eq "Running") {
                Start-Sleep -Seconds 3
                if (Test-Path $destPath) {
                    $mb = [Math]::Round((Get-Item $destPath).Length / 1MB, 0)
                    Write-Host "`r  $mb MB downloaded..." -NoNewline -ForegroundColor DarkGray
                }
            }
            Write-Host ""
            Receive-Job $job -ErrorVariable dlErr | Out-Null
            Remove-Job $job

            if ($dlErr) {
                Write-LabWarn "Could not download $($pkg.File): $dlErr -- VMs will download internally"
                if (Test-Path $destPath) { Remove-Item $destPath -Force }
            } elseif (Test-Path $destPath) {
                $sizeMB = [Math]::Round((Get-Item $destPath).Length / 1MB, 1)
                Write-LabOK "Downloaded: $($pkg.File) ($sizeMB MB)"
                $downloadedInstallers["$($stack.Label)-$($pkg.OS)"] = $destPath
            } else {
                Write-LabWarn "Download completed but file not found -- VMs will download internally"
            }
        }
    }

    foreach ($vm in $Config.VMDefs) {
        $stackDef = $Config.ActiveStacks | Where-Object { $_.Label -eq $vm.Stack }
        if (-not $stackDef) { continue }

        $vmDir    = $vm.Dir
        $fleetUrl = $fleetUrls[$vm.Stack]
        $token    = $tokens[$vm.Stack]
        $version  = $stackDef.Version

        # Ensure log directory exists
        New-Item -ItemType Directory -Path $vm.LogDir -Force | Out-Null

        if ($vm.OS -eq "windows") {
            # Check if we have a pre-staged installer to copy in
            $hostZip   = $downloadedInstallers["$($vm.Stack)-windows"]
            $guestZip  = ""
            if ($hostZip) {
                $zipName  = Split-Path $hostZip -Leaf
                $guestZip = "C:/Windows/Temp/$zipName"
            }

            $content = New-LabWindowsAgentProvisionerContent `
                -Stack $vm.Stack -AgentVersion $version `
                -FleetUrl $fleetUrl -EnrollToken $token `
                -PreStagedZip $guestZip
            Write-LabWindowsAgentProvisioner -Content $content `
                -OutputPath (Join-Path $vmDir "provision-agent.ps1")

            if ($Config.ProvisioningMode -eq "vagrant") {
                $guestPathRuby  = $Config.WindowsProvisionerGuestPath -replace "\\", "\\\\"
                $guestPathFwd   = $Config.WindowsProvisionerGuestPath -replace "\\", "/"
                $runCommand     = "PowerShell -ExecutionPolicy Bypass -File $guestPathFwd"

                # Extra file provisioner block to copy pre-staged installer if available
                $installerProvBlock = ""
                if ($hostZip) {
                    $zipName = Split-Path $hostZip -Leaf
                    $hostZipFwd = $hostZip -replace "\\", "/"
                    $installerProvBlock = @"

  config.vm.provision "file",
    source:      "$hostZipFwd",
    destination: "C:\\\\Windows\\\\Temp\\\\$zipName"
"@
                }

                $vfContent = New-LabVagrantfileContent `
                    -Box $Config.VagrantWindowsBox `
                    -Hostname $vm.Hostname `
                    -VMName   $vm.VMName `
                    -MemoryMB $Config.WindowsVMMemoryMB -CPUs $Config.WindowsVMCPUs `
                    -Communicator "winrm" `
                    -ProvisionerSrc "provision-agent.ps1" `
                    -ProvisionerDst $guestPathRuby `
                    -RunCommand $runCommand `
                    -VagrantUser "vagrant" -VagrantPassword "vagrant" `
                    -Provider $Config.VagrantProvider `
                    -ExtraProvisionBlock $installerProvBlock `
                    -EnableNestedVirt $true
                Write-LabVagrantfile -Content $vfContent -Dir $vmDir
            }
        } else {
            $hostTgz  = $downloadedInstallers["$($vm.Stack)-linux"]
            $guestTgz = ""
            if ($hostTgz) {
                $tgzName  = Split-Path $hostTgz -Leaf
                $guestTgz = "/tmp/$tgzName"
            }

            $content = New-LabLinuxAgentProvisionerContent `
                -Stack $vm.Stack -AgentVersion $version `
                -FleetUrl $fleetUrl -EnrollToken $token `
                -PreStagedTarball $guestTgz
            Write-LabLinuxAgentProvisioner -Content $content `
                -OutputPath (Join-Path $vmDir "provision-agent.sh")

            if ($Config.ProvisioningMode -eq "vagrant") {
                $installerProvBlock = ""
                if ($hostTgz) {
                    $tgzName    = Split-Path $hostTgz -Leaf
                    $hostTgzFwd = $hostTgz -replace "\\", "/"
                    $installerProvBlock = @"

  config.vm.provision "file",
    source:      "$hostTgzFwd",
    destination: "/tmp/$tgzName"
"@
                }

                $vfContent = New-LabVagrantfileContent `
                    -Box $Config.VagrantLinuxBox `
                    -Hostname $vm.Hostname `
                    -VMName   $vm.VMName `
                    -MemoryMB $Config.LinuxVMMemoryMB -CPUs $Config.LinuxVMCPUs `
                    -Communicator "ssh" `
                    -ProvisionerSrc "provision-agent.sh" `
                    -ProvisionerDst "/tmp/provision-agent.sh" `
                    -RunCommand "bash /tmp/provision-agent.sh" `
                    -VagrantUser "" -VagrantPassword "" `
                    -Provider $Config.VagrantProvider `
                    -ExtraProvisionBlock $installerProvBlock
                Write-LabVagrantfile -Content $vfContent -Dir $vmDir
            }
        }
    }

    # Step 5 -- Start VMs
    Write-LabStep "VMs -- Start VMs"

    if ($Config.ProvisioningMode -eq "vagrant") {
        Write-Host "  Windows boxes: ~6 GB download on first run (cached afterwards)." -ForegroundColor Yellow
        Write-Host "  Linux boxes  : ~600 MB download on first run (cached afterwards)." -ForegroundColor Yellow

        foreach ($vm in $Config.VMDefs) {
            $stackDef = $Config.ActiveStacks | Where-Object { $_.Label -eq $vm.Stack }
            if (-not $stackDef) { continue }
            $vmOk = Start-LabVagrantVM -Dir $vm.Dir -Label $vm.Label -Provider $Config.VagrantProvider -VagrantHome $Config.VagrantHome
        }
    } else {
        $diskDir       = Join-Path $Config.LabRoot "vm-disks"
        $linuxVHDXPath = Join-Path $Config.LabRoot "vm-images\ubuntu-22.04-cloudimg.vhdx"
        New-Item -ItemType Directory -Path $diskDir -Force | Out-Null

        foreach ($vm in $Config.VMDefs) {
            $stackDef = $Config.ActiveStacks | Where-Object { $_.Label -eq $vm.Stack }
            if (-not $stackDef) { continue }

            if ($vm.OS -eq "windows") {
                $vhdx = New-LabHyperVDisk -VMName $vm.VMName -DiskDir $diskDir -SizeGB 60
                New-LabHyperVWindowsVM -VMName $vm.VMName -VHDXPath $vhdx `
                    -ISOPath $Config.WindowsISOPath -SwitchName $Config.HyperVSwitch `
                    -MemoryMB $Config.WindowsVMMemoryMB -CPUs $Config.WindowsVMCPUs
                Write-LabWarn "$($vm.Label) requires manual OS setup:"
                Write-LabWarn "  1. Start-VM -Name '$($vm.VMName)'"
                Write-LabWarn "  2. vmconnect.exe localhost '$($vm.VMName)'"
                Write-LabWarn "  3. Complete Windows Server setup wizard"
                Write-LabWarn "  4. winrm quickconfig -y"
                Write-LabWarn "  5. Run: $($vm.Dir)\provision-agent.ps1"
            } else {
                New-LabHyperVLinuxVM -VMName $vm.VMName -BaseVHDXPath $linuxVHDXPath `
                    -DiskDir $diskDir -SwitchName $Config.HyperVSwitch `
                    -MemoryMB $Config.LinuxVMMemoryMB -CPUs $Config.LinuxVMCPUs
                Write-LabWarn "$($vm.Label) -- connect via Hyper-V console (ubuntu/ubuntu)"
                Write-LabWarn "  Then run: sudo bash /tmp/provision-agent.sh"
            }
        }
    }

    # Step 6 -- Verify enrollment
    Write-LabStep "VMs -- Verify Agent Enrollment"
    Write-Host "  Waiting 45 seconds for agents to register..." -ForegroundColor White
    Start-Sleep -Seconds 45

    foreach ($stack in $Config.ActiveStacks) {
        Test-LabVMAgentEnrollment -Stack $stack
    }

    # Summary
    Write-LabStep "VM Setup Complete"

    $modeNote = if ($Config.ProvisioningMode -eq "vagrant") {
        "Vagrant + Hyper-V (automated)"
    } else {
        "Native Hyper-V (Windows VMs require manual OS setup)"
    }

    Write-Host "  Mode: $modeNote" -ForegroundColor White
    Write-Host ""
    foreach ($stack in $Config.ActiveStacks) {
        Write-Host "  [$($stack.Label)] Verify agents: http://localhost:$($stack.KibanaPort)/app/fleet" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  VM layout:" -ForegroundColor Gray
    foreach ($vm in $Config.VMDefs) {
        $stackDef = $Config.ActiveStacks | Where-Object { $_.Label -eq $vm.Stack }
        if ($stackDef) {
            Write-Host "    $($vm.DirName.PadRight(20)) -> Fleet Server $($vm.Stack)  [$($vm.VMName)]" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

Export-ModuleMember -Function Invoke-LabVMSetup,
                              Install-LabHyperVPowerShell,
                              Install-LabVirtualBox,
                              Test-LabHyperV, Test-LabHyperVSwitch,
                              Test-LabVagrantInstalled, Install-LabVagrant,
                              Get-LabHyperVGateway, Get-LabLinuxVHDX,
                              New-LabVMDirectories,
                              New-LabWindowsAgentProvisionerContent,
                              New-LabLinuxAgentProvisionerContent,
                              New-LabVagrantfileContent,
                              Write-LabWindowsAgentProvisioner,
                              Write-LabLinuxAgentProvisioner,
                              Write-LabVagrantfile,
                              New-LabHyperVDisk,
                              New-LabHyperVWindowsVM,
                              New-LabHyperVLinuxVM,
                              Start-LabVagrantVM, Invoke-VagrantUp,
                              Test-LabVMAgentEnrollment
