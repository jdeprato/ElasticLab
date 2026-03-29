# =============================================================================
# ElasticLab.Core.psm1
# Shared helper functions used by all other ElasticLab modules.
# Handles UI output, HTTP communication with Elasticsearch and Kibana,
# and common utility checks.
# =============================================================================

# -- Module-level log collector ------------------------------------------------
# All warnings and errors are appended here during execution.
# Invoke-ElasticLab.ps1 reads this at the end to produce the summary.
$script:LabLogEntries = [System.Collections.Generic.List[hashtable]]::new()

function Add-LabLogEntry {
    param([string]$Level, [string]$Message)
    $script:LabLogEntries.Add(@{
        Time    = (Get-Date -Format "HH:mm:ss")
        Level   = $Level
        Message = $Message
    })
}

function Get-LabLogEntries { return $script:LabLogEntries }

# -- Output helpers ------------------------------------------------------------

function Write-LabStep {
    param([string]$Message)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "  [$ts]  $Message" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
}

function Write-LabOK {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [OK]  [$ts]  $m" -ForegroundColor Green
}

function Write-LabWarn {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [!!]  [$ts]  $m" -ForegroundColor Yellow
    Add-LabLogEntry -Level "WARN" -Message $m
}

function Write-LabFail {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [ERR] [$ts]  $m" -ForegroundColor Red
    Add-LabLogEntry -Level "ERROR" -Message $m
}

function Write-LabInfo {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [--]  [$ts]  $m" -ForegroundColor Gray
}

function Write-LabSkip {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [--]  [$ts]  SKIP: $m" -ForegroundColor DarkGray
}

function Write-LabFound {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [>>]  [$ts]  $m" -ForegroundColor Magenta
}

function Write-LabMissing {
    param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "  [  ]  [$ts]  $m" -ForegroundColor DarkGray
}

# -- Utility -------------------------------------------------------------------

function Test-LabCommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-LabBasicAuthHeader {
    param([string]$Password)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:$Password"))
    return @{ Authorization = "Basic $encoded" }
}

# -- Elasticsearch communication -----------------------------------------------

function Test-LabElasticHealth {
    <#
    .SYNOPSIS
        Returns $true if Elasticsearch is reachable and responding on the given port.
    #>
    param([int]$Port, [string]$Password)
    try {
        $headers = Get-LabBasicAuthHeader -Password $Password
        $r = Invoke-WebRequest -Uri "http://localhost:$Port" `
            -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return $r.StatusCode -eq 200
    } catch { return $false }
}

function Test-LabKibanaHealth {
    <#
    .SYNOPSIS
        Returns $true if Kibana is reachable and its overall status is 'available'.
    #>
    param([int]$Port)
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/status" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            return ($r.Content | ConvertFrom-Json).status.overall.level -eq "available"
        }
        return $false
    } catch { return $false }
}

function Invoke-LabElasticApi {
    <#
    .SYNOPSIS
        Calls the Elasticsearch REST API. Returns the WebResponseObject or $null on failure.
        Errors are silently swallowed -- callers check the return value.
    #>
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Password,
        [string]$Body = $null
    )
    $headers = Get-LabBasicAuthHeader -Password $Password
    $headers["Content-Type"] = "application/json"
    try {
        $params = @{
            Method          = $Method
            Uri             = $Uri
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = 30
            ErrorAction     = "Stop"
        }
        if ($Body) { $params.Body = $Body }
        return Invoke-WebRequest @params
    } catch { return $null }
}

function Invoke-LabElasticApiWithError {
    <#
    .SYNOPSIS
        Like Invoke-LabElasticApi but surfaces the full ES error body on failure.
        Returns a hashtable with keys: Response (WebResponseObject or $null),
        StatusCode (int), ErrorType (string), ErrorReason (string).
    #>
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Password,
        [string]$Body = $null
    )
    $result = @{ Response = $null; StatusCode = 0; ErrorType = ""; ErrorReason = "" }
    $headers = Get-LabBasicAuthHeader -Password $Password
    $headers["Content-Type"] = "application/json"
    try {
        $params = @{
            Method          = $Method
            Uri             = $Uri
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = 30
            ErrorAction     = "Stop"
        }
        if ($Body) { $params.Body = $Body }
        $result.Response   = Invoke-WebRequest @params
        $result.StatusCode = $result.Response.StatusCode
    } catch {
        $result.StatusCode = $_.Exception.Response.StatusCode.value__

        # PS 5.1: error body is in ErrorDetails.Message
        $errorBody = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errorBody = $_.ErrorDetails.Message
        }
        if (-not $errorBody) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $errorBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {}
        }
        if ($errorBody) {
            try {
                $parsed             = $errorBody | ConvertFrom-Json
                $result.ErrorType   = $parsed.error.type
                $result.ErrorReason = $parsed.error.reason
            } catch {
                $result.ErrorReason = $errorBody.Substring(0, [Math]::Min(300, $errorBody.Length))
            }
        }
    }
    return $result
}

function Invoke-LabKibanaApi {
    <#
    .SYNOPSIS
        Calls the Kibana REST API. Returns the WebResponseObject or $null on failure.
    #>
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Password,
        [string]$Body = $null
    )
    $headers = Get-LabBasicAuthHeader -Password $Password
    $headers["Content-Type"] = "application/json"
    $headers["kbn-xsrf"]     = "true"
    try {
        $params = @{
            Method          = $Method
            Uri             = $Uri
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = 30
            ErrorAction     = "Stop"
        }
        if ($Body) { $params.Body = $Body }
        return Invoke-WebRequest @params
    } catch { return $null }
}

function Invoke-LabKibanaApiWithError {
    <#
    .SYNOPSIS
        Like Invoke-LabKibanaApi but surfaces the full response body on failure.
        Returns a hashtable: Response, StatusCode, ErrorMessage.
    #>
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Password,
        [string]$Body = $null
    )
    $result = @{ Response = $null; StatusCode = 0; ErrorMessage = "" }
    $headers = Get-LabBasicAuthHeader -Password $Password
    $headers["Content-Type"] = "application/json"
    $headers["kbn-xsrf"]     = "true"
    try {
        $params = @{
            Method          = $Method
            Uri             = $Uri
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = 60
            ErrorAction     = "Stop"
        }
        if ($Body) { $params.Body = $Body }
        $result.Response   = Invoke-WebRequest @params
        $result.StatusCode = $result.Response.StatusCode
    } catch {
        $result.StatusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errorBody = $_.ErrorDetails.Message
        }
        if (-not $errorBody) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $errorBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {}
        }
        $result.ErrorMessage = if ($errorBody) {
            $errorBody.Substring(0, [Math]::Min(500, $errorBody.Length))
        } else { $_.Exception.Message }
    }
    return $result
}

# -- Config helpers ------------------------------------------------------------

function Resolve-LabConfig {
    <#
    .SYNOPSIS
        Takes a raw config hashtable from Import-PowerShellDataFile and resolves
        all derived values (computed paths, stack flags, AI flags).
        Returns an enriched hashtable safe to pass to all other functions.
    #>
    param([hashtable]$Config)

    $c = $Config.Clone()

    # Resolve derived paths
    # -- Artifacts folder -- all large downloads live here --------------------
    $artifactsDir         = Join-Path $c.LabRoot "artifacts"
    $c.ArtifactsDir       = $artifactsDir
    $c.ElserModelDir      = Join-Path $artifactsDir "elser-model"
    $c.OllamaInstallerPath = Join-Path $c.LabRoot $c.OllamaInstallerSubPath
    $c.AgentInstallerCache = Join-Path $artifactsDir "agent-installers"
    $c.VagrantHome         = Join-Path $artifactsDir ".vagrant.d"

    # VagrantProvider resolution
    # "auto" detects Windows edition and picks the appropriate provider.
    # Explicit "hyperv" or "virtualbox" override detection entirely.
    if (-not $c.VagrantProvider -or $c.VagrantProvider -eq "auto") {
        $regPath    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        $regInfo    = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
        $editionId  = $regInfo.EditionID   # e.g. "Core", "CoreSingleLanguage", "Professional"
        $productName= $regInfo.ProductName # e.g. "Windows 11 Home", "Windows 11 Pro"

        # Check ProductName first -- always contains "Home" for all Home SKUs
        # regardless of EditionID variant (Core, CoreSingleLanguage, CoreN, etc.)
        $isHome = $productName -match "Home" -or $editionId -match "^Core"
        $isProOrAbove = -not $isHome -and ($editionId -match "Professional|Enterprise|Education|Server")

        if ($isProOrAbove) {
            $c.VagrantProvider = "hyperv"
            $c.VagrantProviderSource = "auto (detected: $productName -> Hyper-V)"
        } else {
            $c.VagrantProvider = "virtualbox"
            $c.VagrantProviderSource = "auto (detected: $productName -> VirtualBox)"
        }
    } else {
        $c.VagrantProviderSource = "config (VagrantProvider = '$($c.VagrantProvider)')"
    }

    # Resolve host IP -- used for Fleet Server host URL so external agents
    # (Vagrant VMs, physical machines) can reach Fleet Server via the host's
    # exposed port rather than the Docker container name.
    # Prefer a non-loopback, non-APIPA, non-virtual adapter IP.
    $hostIP = $null
    $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch "^127\." -and
            $_.IPAddress -notmatch "^169\.254\." -and
            $_.PrefixOrigin -ne "WellKnown" -and
            $_.InterfaceAlias -notmatch "vEthernet|Loopback|Tunnel|isatap"
        } | Sort-Object { $_.InterfaceMetric } | Select-Object -First 1
    if ($adapters) { $hostIP = $adapters.IPAddress }
    if (-not $hostIP) {
        # Fallback: first non-loopback non-APIPA IP on any adapter
        $hostIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch "^127\.|^169\.254\." } |
            Select-Object -First 1).IPAddress
    }
    if (-not $hostIP) { $hostIP = "127.0.0.1" }
    $c.HostIP = $hostIP

    if (-not $c.VMDirPrefix)        { $c.VMDirPrefix        = "vm" }
    if (-not $c.HyperVVMPrefix)     { $c.HyperVVMPrefix     = "elastic-lab" }
    if (-not $c.VMHostnamePrefix)   { $c.VMHostnamePrefix   = "elab" }
    if (-not $c.VMLogSubfolder)     { $c.VMLogSubfolder     = "logs" }
    if (-not $c.WindowsProvisionerGuestPath) {
        $c.WindowsProvisionerGuestPath = 'C:\Windows\Temp\provision-agent.ps1'
    }


    # Derive VM directory names and Hyper-V VM names from config
    # e.g. VMDirPrefix=vm, HyperVVMPrefix=elastic-lab ->
    #   vm-windows-8, elastic-lab-windows-8
    $c.VMDefs = @(
        @{ DirName = "$($c.VMDirPrefix)-windows-8"; VMName = "$($c.HyperVVMPrefix)-windows-8"
           Hostname = "$($c.VMHostnamePrefix)-win-8"; Stack = "ES8"; OS = "windows"; Label = "Windows ES8" },
        @{ DirName = "$($c.VMDirPrefix)-windows-9"; VMName = "$($c.HyperVVMPrefix)-windows-9"
           Hostname = "$($c.VMHostnamePrefix)-win-9"; Stack = "ES9"; OS = "windows"; Label = "Windows ES9" },
        @{ DirName = "$($c.VMDirPrefix)-linux-8";   VMName = "$($c.HyperVVMPrefix)-linux-8"
           Hostname = "$($c.VMHostnamePrefix)-linux-8"; Stack = "ES8"; OS = "linux"; Label = "Linux ES8" },
        @{ DirName = "$($c.VMDirPrefix)-linux-9";   VMName = "$($c.HyperVVMPrefix)-linux-9"
           Hostname = "$($c.VMHostnamePrefix)-linux-9"; Stack = "ES9"; OS = "linux"; Label = "Linux ES9" }
    )
    # Resolve full paths
    foreach ($vm in $c.VMDefs) {
        $vm.Dir    = Join-Path $c.LabRoot $vm.DirName
        $vm.LogDir = Join-Path $vm.Dir $c.VMLogSubfolder
    }


    # Stack flags
    $c.SetupES8 = $c.StackMode -in @("8", "Both")
    $c.SetupES9 = $c.StackMode -in @("9", "Both")

    # AI flags
    $c.SetupElser  = $c.AITool -in @("ELSER",  "Both")
    $c.SetupOllama = $c.AITool -in @("Ollama", "Both")

    # Active stacks as an array for easy iteration
    $c.ActiveStacks = @()
    if ($c.SetupES8) {
        $c.ActiveStacks += @{
            Label           = "ES8"
            ESPort          = $c.ES8Port
            KibanaPort      = $c.Kibana8Port
            Password        = $c.ES8Password
            Version         = $c.ES8Version
            ESContainer     = "es8"
            KibanaContainer = "kibana8"
            ElserRepo       = "elser-repo"
            ComposeDir      = Join-Path $c.LabRoot "elastic8"
            NetworkName     = "elastic8_elastic8-net"
            VolumeName      = "elastic8_es8-data"
            FleetPort       = $c.FleetServer8Port
            AgentPolicyId   = $c.FleetAgentPolicyId8
            HostIP          = $c.HostIP
            HostFleetUrl    = "http://$($c.HostIP):$($c.FleetServer8Port)"
            HostESUrl       = "http://$($c.HostIP):$($c.ES8Port)"
        }
    }
    if ($c.SetupES9) {
        $c.ActiveStacks += @{
            Label           = "ES9"
            ESPort          = $c.ES9Port
            KibanaPort      = $c.Kibana9Port
            Password        = $c.ES9Password
            Version         = $c.ES9Version
            ESContainer     = "es9"
            KibanaContainer = "kibana9"
            ElserRepo       = "elser-repo9"
            ComposeDir      = Join-Path $c.LabRoot "elastic9"
            NetworkName     = "elastic9_elastic9-net"
            VolumeName      = "elastic9_es9-data"
            FleetPort       = $c.FleetServer9Port
            AgentPolicyId   = $c.FleetAgentPolicyId9
            HostIP          = $c.HostIP
            HostFleetUrl    = "http://$($c.HostIP):$($c.FleetServer9Port)"
            HostESUrl       = "http://$($c.HostIP):$($c.ES9Port)"
        }
    }

    return $c
}

Export-ModuleMember -Function *
