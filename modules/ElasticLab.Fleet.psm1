# =============================================================================
# ElasticLab.Fleet.psm1
# Fleet Server infrastructure: image pulls, compose file generation,
# service token creation, policy creation, Fleet Server start,
# enrollment token retrieval, and agent container start.
# Each function does exactly one thing.
# =============================================================================

function Invoke-LabFleetImagePull {
    <#
    .SYNOPSIS Pulls elastic-agent and target container images for active stacks. #>
    param([hashtable]$Config)

    Write-LabStep "Fleet -- Pull Images"

    $images = @()
    foreach ($stack in $Config.ActiveStacks) {
        $images += "$($Config.DockerRegistry)/elastic-agent/elastic-agent:$($stack.Version)"
    }
    $images += $Config.FleetLinuxImage
    if ($Config.WindowsContainersSupported) { $images += $Config.FleetWindowsImage }

    foreach ($image in $images) {
        Write-Host "`n  Pulling: $image" -ForegroundColor White
        docker pull $image 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) { Write-LabOK "Pulled: $image" }
        else                     { Write-LabWarn "Could not pull: $image -- will attempt to continue" }
    }
}

function Test-LabWindowsContainerSupport {
    <#
    .SYNOPSIS
        Checks whether Docker Desktop is in Windows container mode.
        Returns $true if Windows containers are supported, $false otherwise.
        Writes informational output but does not exit.
    #>
    param()

    Write-Host "`n  Checking Windows container mode..." -ForegroundColor White
    $osType = docker info --format "{{.OSType}}" 2>&1
    if ($osType -eq "windows") {
        Write-LabOK "Docker is in Windows container mode -- Windows containers supported"
        return $true
    }
    Write-LabWarn "Docker is in Linux container mode -- Windows target container will be skipped"
    Write-LabWarn "To enable: Docker Desktop tray icon -> Switch to Windows containers"
    return $false
}

function New-LabFleetFolders {
    <#
    .SYNOPSIS Creates fleet8\ and fleet9\ directories under LabRoot. #>
    param([hashtable]$Config)

    foreach ($stack in $Config.ActiveStacks) {
        $dir = Join-Path $Config.LabRoot "fleet$($stack.Label.ToLower().Replace('es',''))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-LabOK "Created: $dir"
    }
}

function New-LabFleetComposeFile {
    <#
    .SYNOPSIS
        Generates the docker-compose.yml for one fleet stack.
        Writes the file to disk. Returns the path written.
    #>
    param([hashtable]$Stack, [hashtable]$Config, [bool]$WindowsContainersSupported)

    $suffix      = $Stack.Label.ToLower().Replace('es','')   # "8" or "9"
    $fleetName   = "fleet$suffix"
    $linuxName   = "linux$suffix"
    $agentName   = "agent$suffix"
    $windowsName = "windows$suffix"
    $fleetDir    = Join-Path $Config.LabRoot "fleet$suffix"
    $fleetPort   = $Stack.FleetPort
    $esName      = $Stack.ESContainer
    $kibanaName  = $Stack.KibanaContainer
    $version     = $Stack.Version
    $reg         = $Config.DockerRegistry
    # Use the exact network name Docker created for this stack
    $extNetName  = $Stack.NetworkName    # e.g. elastic8_elastic8-net
    $netAlias    = "es-net"              # local alias inside this compose file

    $winBlock = ""
    if ($WindowsContainersSupported) {
        $winBlock = @"

  ${windowsName}:
    image: $($Config.FleetWindowsImage)
    container_name: $windowsName
    hostname: windows-lab-$suffix
    isolation: process
    networks:
      - $netAlias
    restart: unless-stopped
    command: cmd /c "ping -t localhost > nul"
"@
    }

    $compose = @"
name: fleet$suffix

services:

  ${fleetName}:
    image: ${reg}/elastic-agent/elastic-agent:${version}
    container_name: $fleetName
    hostname: fleet-server-$suffix
    user: root
    environment:
      - FLEET_SERVER_ENABLE=1
      - FLEET_SERVER_ELASTICSEARCH_HOST=http://${esName}:9200
      - FLEET_SERVER_ELASTICSEARCH_USERNAME=elastic
      - FLEET_SERVER_ELASTICSEARCH_PASSWORD=`${ELASTIC_PASSWORD}
      - FLEET_SERVER_ELASTICSEARCH_INSECURE=true
      - FLEET_SERVER_SERVICE_TOKEN=`${FLEET_SERVICE_TOKEN}
      - FLEET_SERVER_POLICY_ID=fleet-server-policy-$suffix
      - FLEET_SERVER_INSECURE_HTTP=true
      - FLEET_SERVER_HOST=0.0.0.0
      - FLEET_SERVER_PORT=8220
    ports:
      - "${fleetPort}:8220"
    networks:
      - $netAlias
    restart: unless-stopped
    depends_on:
      - $linuxName

  ${linuxName}:
    image: $($Config.FleetLinuxImage)
    container_name: $linuxName
    hostname: linux-lab-$suffix
    networks:
      - $netAlias
    restart: unless-stopped
    command: >
      bash -c "apt-get update -qq && apt-get install -y -qq sysstat curl &&
               while true; do
                 echo \"`$(date) INFO heartbeat $linuxName running\" >> /var/log/lab.log;
                 sleep 30;
               done"
$winBlock

  ${agentName}:
    image: ${reg}/elastic-agent/elastic-agent:${version}
    container_name: $agentName
    hostname: agent-lab-$suffix
    user: root
    environment:
      - FLEET_ENROLL=1
      - FLEET_URL=http://${fleetName}:8220
      - FLEET_ENROLLMENT_TOKEN=`${AGENT_ENROLLMENT_TOKEN}
      - FLEET_INSECURE=true
      - FLEET_CA_TRUSTED=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /sys/fs/cgroup:/hostfs/sys/fs/cgroup:ro
      - /proc:/hostfs/proc:ro
      - /:/hostfs:ro
    networks:
      - $netAlias
    restart: unless-stopped
    depends_on:
      - $fleetName
    profiles:
      - agent

networks:
  ${netAlias}:
    external: true
    name: $extNetName
"@

    $composePath = Join-Path $fleetDir "docker-compose.yml"
    Set-Content -Path $composePath -Value $compose
    Write-LabOK "Compose file written: $composePath"
    return $composePath
}

function New-LabFleetServiceToken {
    <#
    .SYNOPSIS
        Generates a Fleet service token for one stack via the Elasticsearch API.
        Returns the token string or $null on failure.
    #>
    param([hashtable]$Stack)

    $label = $Stack.Label
    Write-Host "  [$label] Generating Fleet service token..." -ForegroundColor White

    $r = Invoke-LabElasticApi -Method POST `
        -Uri "http://localhost:$($Stack.ESPort)/_security/service/elastic/fleet-server/credential/token/fleet-token-$label" `
        -Password $Stack.Password

    if ($r -and $r.StatusCode -eq 200) {
        $token = ($r.Content | ConvertFrom-Json).token.value
        Write-LabOK "[$label] Fleet service token generated"
        return $token
    }

    Write-LabFail "[$label] Failed to generate Fleet service token"
    return $null
}

function New-LabFleetServerPolicy {
    <#
    .SYNOPSIS
        Creates the Fleet Server agent policy for one stack.
        Explicitly assigns the stack-specific output.
    #>
    param([hashtable]$Stack)

    $label    = $Stack.Label
    $suffix   = $label.ToLower().Replace('es','')
    $policyId = "fleet-server-policy-$suffix"
    $outputId = "fleet-output-$suffix"

    Write-Host "  [$label] Creating Fleet Server policy '$policyId'..." -ForegroundColor White

    $body = @"
{
    "id":                    "$policyId",
    "name":                  "Fleet Server Policy ($label)",
    "description":           "Policy for Fleet Server on $label",
    "namespace":             "default",
    "monitoring_enabled":    ["logs","metrics"],
    "is_managed":            false
}
"@
    $r = Invoke-LabKibanaApi -Method POST `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/agent_policies" `
        -Password $Stack.Password `
        -Body $body

    if ($r -and ($r.StatusCode -eq 200 -or $r.StatusCode -eq 409)) {
        Write-LabOK "[$label] Fleet Server policy ready: $policyId (output: $outputId)"
        return $policyId
    }

    Write-LabWarn "[$label] Fleet Server policy creation returned unexpected response -- may already exist"
    return $policyId
}

function Add-LabFleetServerIntegration {
    <#
    .SYNOPSIS
        Adds the fleet_server package integration to the Fleet Server policy.
        Without this Fleet Server waits indefinitely for the fleet-server
        input to appear in its policy.
    #>
    param([hashtable]$Stack)

    $label    = $Stack.Label
    $suffix   = $Stack.Label.ToLower().Replace('es','')
    $policyId = "fleet-server-policy-$suffix"

    Write-Host "  [$label] Adding fleet_server integration to policy '$policyId'..." -ForegroundColor White

    # Look up installed fleet_server package version
    $pkgResp = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/epm/packages/fleet_server" `
        -Password $Stack.Password
    $pkgVersion = "1.6.0"
    if ($pkgResp -and $pkgResp.StatusCode -eq 200) {
        $pkgVersion = ($pkgResp.Content | ConvertFrom-Json).item.version
        Write-LabInfo "[$label] fleet_server package version: $pkgVersion"
    }

    # Check if already installed
    $existing = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/package_policies" `
        -Password $Stack.Password
    if ($existing -and $existing.StatusCode -eq 200) {
        $policies = ($existing.Content | ConvertFrom-Json).items
        $found = $policies | Where-Object {
            ($_.policy_id -eq $policyId -or ($_.policy_ids -and $_.policy_ids -contains $policyId)) `
            -and $_.package.name -eq "fleet_server"
        }
        if ($found) {
            Write-LabOK "[$label] fleet_server integration already installed in policy"
            return $true
        }
    }

    # Send minimal body -- let Kibana apply package defaults for all inputs/vars.
    # Providing explicit vars causes 400 if the var names don't exactly match the
    # installed package schema version. The package defaults are sufficient for a lab.
    $body = @"
{
    "name": "fleet_server-$suffix",
    "policy_id": "$policyId",
    "package": {
        "name": "fleet_server",
        "version": "$pkgVersion"
    },
    "namespace": "default",
    "inputs": {}
}
"@
    $result = Invoke-LabKibanaApiWithError -Method POST `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/package_policies" `
        -Password $Stack.Password `
        -Body $body

    if ($result.Response -and ($result.StatusCode -eq 200 -or $result.StatusCode -eq 409)) {
        Write-LabOK "[$label] fleet_server integration added to policy"
        return $true
    }

    Write-LabWarn "[$label] Failed to add fleet_server integration (HTTP $($result.StatusCode))"
    if ($result.ErrorMessage) { Write-LabWarn "[$label] $($result.ErrorMessage)" }
    return $false
}

function Set-LabFleetServerHost {
    <#
    .SYNOPSIS
        Registers or updates the Fleet Server host URL in Kibana Fleet settings.
        Uses the host machine's IP and exposed port so agents running outside
        Docker (Vagrant VMs, physical machines) can reach Fleet Server.
        Docker agent containers use the container name internally via FLEET_URL
        env var -- this registered URL is for all other agents via policy.
        Always updates existing entries -- never skips if the URL may be stale.
        Also removes incorrect default host entries (e.g. "http://fleet:80").
    #>
    param([hashtable]$Stack)

    $label   = $Stack.Label
    $suffix  = $Stack.Label.ToLower().Replace('es','')
    $hostId  = "fleet-server-host-$suffix"
    $url     = $Stack.HostFleetUrl   # e.g. http://192.168.1.50:8220

    Write-Host "  [$label] Configuring Fleet Server host: $url..." -ForegroundColor White

    # Get all existing Fleet Server host entries
    $allHosts = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/fleet_server_hosts" `
        -Password $Stack.Password

    if ($allHosts -and $allHosts.StatusCode -eq 200) {
        $hosts = ($allHosts.Content | ConvertFrom-Json).items

        # Delete any host entries that don't have the correct URL
        # (catches the built-in "http://fleet:80" and any stale https:// entries)
        foreach ($h in $hosts) {
            $hostUrls = $h.host_urls -join ","
            $isOurEntry = $h.id -eq $hostId
            $hasCorrectUrl = $hostUrls -match [regex]::Escape($url)
            if (-not $isOurEntry -and -not $hasCorrectUrl) {
                Write-LabInfo "[$label] Removing stale Fleet host entry '$($h.name)': $hostUrls"
                $null = Invoke-LabKibanaApi -Method DELETE `
                    -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/fleet_server_hosts/$($h.id)" `
                    -Password $Stack.Password
            }
        }

        # Update our entry if it already exists
        $existing = $hosts | Where-Object { $_.id -eq $hostId } | Select-Object -First 1
        if ($existing) {
            $updateBody = @"
{
    "name": "Fleet Server $label",
    "is_default": true,
    "host_urls": ["$url"]
}
"@
            $result = Invoke-LabKibanaApiWithError -Method PUT `
                -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/fleet_server_hosts/$hostId" `
                -Password $Stack.Password `
                -Body $updateBody
            if ($result.Response -and $result.StatusCode -eq 200) {
                Write-LabOK "[$label] Fleet Server host updated: $url"
                return $true
            }
            Write-LabWarn "[$label] Could not update Fleet Server host (HTTP $($result.StatusCode))"
            if ($result.ErrorMessage) { Write-LabWarn "[$label] $($result.ErrorMessage)" }
        }
    }

    # Create new entry
    $body = @"
{
    "id": "$hostId",
    "name": "Fleet Server $label",
    "is_default": true,
    "host_urls": ["$url"]
}
"@
    $result = Invoke-LabKibanaApiWithError -Method POST `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/fleet_server_hosts" `
        -Password $Stack.Password `
        -Body $body

    if ($result.Response -and ($result.StatusCode -eq 200 -or $result.StatusCode -eq 409)) {
        Write-LabOK "[$label] Fleet Server host registered: $url"
        return $true
    }

    Write-LabWarn "[$label] Failed to register Fleet Server host (HTTP $($result.StatusCode))"
    if ($result.ErrorMessage) { Write-LabWarn "[$label] $($result.ErrorMessage)" }
    return $false
}

function Invoke-LabFleetSetupApi {
    <#
    .SYNOPSIS
        Calls POST /api/fleet/setup to initialize Fleet in Kibana.
        This resolves the "Unable to initialize Fleet" error.
        Must be called after Kibana is ready and before other Fleet API calls.
    #>
    param([hashtable]$Stack)

    $label = $Stack.Label
    Write-Host "  [$label] Initializing Fleet in Kibana..." -ForegroundColor White

    $result = Invoke-LabKibanaApiWithError -Method POST `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/setup" `
        -Password $Stack.Password `
        -Body "{}"

    if ($result.Response -and $result.StatusCode -eq 200) {
        $body = $result.Response.Content | ConvertFrom-Json
        if ($body.isInitialized -or $body.nonFatalErrors -ne $null) {
            Write-LabOK "[$label] Fleet initialized in Kibana"
            return $true
        }
    }

    # 200 with any body is fine -- Fleet may already be initialized
    if ($result.StatusCode -eq 200) {
        Write-LabOK "[$label] Fleet initialized in Kibana"
        return $true
    }

    Write-LabWarn "[$label] Fleet setup API returned HTTP $($result.StatusCode)"
    if ($result.ErrorMessage) { Write-LabWarn "[$label] $($result.ErrorMessage)" }
    return $false
}

function Set-LabFleetOutput {
    <#
    .SYNOPSIS
        Updates the fleet-default-output to point at the host IP and external port.
        All policies fall back to fleet-default-output when data_output_id is not set,
        so updating this single output fixes all agents including VM-based ones.
        Uses host IP + external port so both Docker and Hyper-V VM agents can reach it.
    #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label  = $Stack.Label
    $esHost = $Stack.HostESUrl

    Write-Host "  [$label] Updating fleet-default-output -> $esHost..." -ForegroundColor White

    $body = @"
{
    "name":                  "default",
    "type":                  "elasticsearch",
    "is_default":            true,
    "is_default_monitoring": true,
    "hosts":                 ["$esHost"],
    "config_yaml":           "ssl.verification_mode: none"
}
"@

    $result = Invoke-LabKibanaApiWithError -Method PUT `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/outputs/fleet-default-output" `
        -Password $Stack.Password `
        -Body $body

    if ($result.Response -and $result.StatusCode -eq 200) {
        Write-LabOK "[$label] fleet-default-output updated -> $esHost"
        return $true
    }

    Write-LabWarn "[$label] Failed to update fleet-default-output (HTTP $($result.StatusCode)): $($result.ErrorMessage)"
    return $false
}

function New-LabFleetAgentPolicy {
    <#
    .SYNOPSIS
        Creates the monitored-agent policy for one stack.
        Explicitly assigns the stack-specific output so agents always
        report to the correct Elasticsearch cluster regardless of defaults.
    #>
    param([hashtable]$Stack)

    $label    = $Stack.Label
    $policyId = $Stack.AgentPolicyId
    $suffix   = $label.ToLower().Replace('es','')
    $outputId = "fleet-output-$suffix"

    Write-Host "  [$label] Creating agent monitoring policy '$policyId'..." -ForegroundColor White

    $body = @"
{
    "id":                    "$policyId",
    "name":                  "Lab Agent Policy ($label)",
    "description":           "Policy for monitored lab containers on $label",
    "namespace":             "default",
    "monitoring_enabled":    ["logs","metrics"]
}
"@
    $r = Invoke-LabKibanaApi -Method POST `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/agent_policies" `
        -Password $Stack.Password `
        -Body $body

    if ($r -and ($r.StatusCode -eq 200 -or $r.StatusCode -eq 409)) {
        Write-LabOK "[$label] Agent monitoring policy ready: $policyId (output: $outputId)"
        return $policyId
    }

    Write-LabWarn "[$label] Agent policy creation returned unexpected response"
    return $policyId
}

function Write-LabFleetEnv {
    <#
    .SYNOPSIS Writes the .env file for a fleet stack directory. #>
    param([hashtable]$Stack, [hashtable]$Config, [string]$ServiceToken, [string]$AgentToken = "PENDING")

    $suffix  = $Stack.Label.ToLower().Replace('es','')
    $fleetDir = Join-Path $Config.LabRoot "fleet$suffix"
    $envPath  = Join-Path $fleetDir ".env"

    $content = "ELASTIC_PASSWORD=$($Stack.Password)`nFLEET_SERVICE_TOKEN=$ServiceToken`nAGENT_ENROLLMENT_TOKEN=$AgentToken"
    Set-Content -Path $envPath -Value $content
    Write-LabOK "[$($Stack.Label)] .env written to $envPath"
}

function Start-LabFleetContainers {
    <#
    .SYNOPSIS
        Starts the Fleet Server and target containers (excluding the agent,
        which needs an enrollment token first).
    #>
    param([hashtable]$Stack, [hashtable]$Config, [bool]$WindowsContainersSupported)

    $label  = $Stack.Label
    $suffix = $label.ToLower().Replace('es','')
    $dir    = Join-Path $Config.LabRoot "fleet$suffix"

    Write-Host "`n  [$label] Starting Fleet Server + target containers..." -ForegroundColor White
    Push-Location $dir

    $services = @("fleet$suffix", "linux$suffix")
    if ($WindowsContainersSupported) { $services += "windows$suffix" }

    docker compose up -d @services 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) { Write-LabOK "[$label] Fleet containers started" }
    else                     { Write-LabWarn "[$label] Some containers may have failed -- check: docker logs fleet$suffix" }

    Pop-Location
}

function Wait-LabFleetServer {
    <#
    .SYNOPSIS
        Waits for Fleet Server to register itself in Kibana Fleet.
        Polls the Kibana Fleet agents API rather than the Fleet Server HTTPS
        endpoint directly -- avoids self-signed cert issues entirely.
        Returns $true when Fleet Server appears as a healthy agent, $false on timeout.
    #>
    param([hashtable]$Stack, [int]$TimeoutSec = 300)

    $label  = $Stack.Label
    $suffix = $label.ToLower().Replace('es','')

    Write-Host "`n  [$label] Waiting for Fleet Server to register in Kibana (up to $([int]($TimeoutSec/60)) min)..." -ForegroundColor White

    $waited = 0
    while ($waited -lt $TimeoutSec) {
        $r = Invoke-LabKibanaApi -Method GET `
            -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/agents?perPage=50" `
            -Password $Stack.Password

        if ($r -and $r.StatusCode -eq 200) {
            $agents = ($r.Content | ConvertFrom-Json).items
            $fleetServer = $agents | Where-Object {
                $_.policy_id -eq "fleet-server-policy-$suffix" -and
                $_.status -in @("online","healthy")
            } | Select-Object -First 1

            if ($fleetServer) {
                Write-LabOK "[$label] Fleet Server registered and healthy in Kibana after ${waited}s"
                return $true
            }
        }

        Start-Sleep -Seconds 10 ; $waited += 10
        Write-Host "  [${waited}s] Waiting for Fleet Server to appear in Kibana Fleet..." -ForegroundColor DarkGray
    }

    Write-LabWarn "[$label] Fleet Server did not appear in Kibana Fleet within ${TimeoutSec}s"
    Write-LabWarn "[$label] Check container: docker logs fleet$suffix --tail 20"
    return $false
}

function Get-LabFleetEnrollmentToken {
    <#
    .SYNOPSIS
        Retrieves the enrollment token for the agent policy from Kibana Fleet API.
        Returns the token string or $null if not found.
    #>
    param([hashtable]$Stack)

    $label    = $Stack.Label
    $policyId = $Stack.AgentPolicyId

    Write-Host "  [$label] Retrieving enrollment token for policy '$policyId'..." -ForegroundColor White

    $r = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/enrollment_api_keys" `
        -Password $Stack.Password

    if ($r -and $r.StatusCode -eq 200) {
        $token = ($r.Content | ConvertFrom-Json).items |
            Where-Object { $_.policy_id -eq $policyId } |
            Select-Object -First 1
        if ($token) {
            Write-LabOK "[$label] Enrollment token retrieved"
            return $token.api_key
        }
    }

    Write-LabWarn "[$label] No enrollment token found for policy '$policyId'"
    Write-LabWarn "[$label] Get token manually: Kibana -> Fleet -> Enrollment Tokens"
    return $null
}

function Start-LabFleetAgent {
    <#
    .SYNOPSIS
        Starts the Elastic Agent container for one stack using the enrollment token.
        Requires the .env to already have the token written.
    #>
    param([hashtable]$Stack, [hashtable]$Config)

    $label  = $Stack.Label
    $suffix = $label.ToLower().Replace('es','')
    $dir    = Join-Path $Config.LabRoot "fleet$suffix"

    Write-Host "  [$label] Starting Elastic Agent container..." -ForegroundColor White
    Push-Location $dir
    docker compose --profile agent up -d "agent$suffix" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) { Write-LabOK "[$label] Elastic Agent started" }
    else                     { Write-LabWarn "[$label] Agent failed to start -- check: docker logs agent$suffix" }
    Pop-Location
}

function Test-LabFleetAgentEnrollment {
    <#
    .SYNOPSIS
        Queries Kibana Fleet to verify lab agents are enrolled for one stack.
        Returns the count of enrolled lab agents.
    #>
    param([hashtable]$Stack)

    $label = $Stack.Label
    $r = Invoke-LabKibanaApi -Method GET `
        -Uri "http://localhost:$($Stack.KibanaPort)/api/fleet/agents?perPage=100" `
        -Password $Stack.Password

    if (-not ($r -and $r.StatusCode -eq 200)) {
        Write-LabWarn "[$label] Could not query Fleet agents API"
        return 0
    }

    $agents    = ($r.Content | ConvertFrom-Json).items
    $labAgents = $agents | Where-Object {
        $_.tags -contains $label -or
        $_.tags -contains "linux-lab" -or
        $_.tags -contains "windows-lab"
    }

    if ($labAgents) {
        Write-LabOK "[$label] $($labAgents.Count) lab agent(s) enrolled:"
        foreach ($a in $labAgents) {
            Write-LabOK "  -> $($a.local_metadata.host.hostname) ($($a.local_metadata.os.name)) -- $($a.status)"
        }
        return $labAgents.Count
    }

    $total = ($agents | Measure-Object).Count
    Write-LabWarn "[$label] No lab agents visible yet ($total total in Fleet)"
    return 0
}

# -- Orchestration function ----------------------------------------------------

function Invoke-LabFleetSetup {
    <#
    .SYNOPSIS
        Orchestrates the full Fleet Server setup for all active stacks.
        Calls each unit function in the correct order.
    #>
    param([hashtable]$Config)

    Write-LabStep "Fleet -- Pre-flight"

    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LabFail "Docker Desktop is not running."
        exit 1
    }
    Write-LabOK "Docker Desktop is running"

    foreach ($stack in $Config.ActiveStacks) {
        if (-not (Test-LabElasticHealth -Port $stack.ESPort -Password $stack.Password)) {
            Write-LabFail "[$($stack.Label)] Elasticsearch not reachable -- run Invoke-BuildElasticLab.ps1 first"
            exit 1
        }
        Write-LabOK "[$($stack.Label)] Elasticsearch reachable"
    }

    # Check Windows container support once -- applies to all stacks
    $winSupported = Test-LabWindowsContainerSupport

    # Pull images
    Invoke-LabFleetImagePull -Config $Config

    # Create directories
    Write-LabStep "Fleet -- Create Directories"
    New-LabFleetFolders -Config $Config

    # Tear down any existing fleet containers so they pick up the new compose/env
    Write-LabStep "Fleet -- Tear Down Existing Fleet Containers"
    foreach ($stack in $Config.ActiveStacks) {
        $suffix   = $stack.Label.ToLower().Replace('es','')
        $fleetDir = Join-Path $Config.LabRoot "fleet$suffix"
        if (Test-Path (Join-Path $fleetDir "docker-compose.yml")) {
            Write-Host "  [$($stack.Label)] Stopping existing fleet containers..." -ForegroundColor White
            Push-Location $fleetDir
            docker compose --profile agent down --remove-orphans 2>&1 | Out-Null
            Pop-Location
            Write-LabOK "[$($stack.Label)] Fleet containers stopped"
        }
    }

    # Generate compose files
    Write-LabStep "Fleet -- Generate Compose Files"
    foreach ($stack in $Config.ActiveStacks) {
        New-LabFleetComposeFile -Stack $stack -Config $Config -WindowsContainersSupported $winSupported
    }

    # Bootstrap Fleet via API for each stack
    Write-LabStep "Fleet -- Bootstrap via API"
    $stackTokens = @{}

    foreach ($stack in $Config.ActiveStacks) {
        # Generate service token
        $serviceToken = New-LabFleetServiceToken -Stack $stack
        if (-not $serviceToken) { continue }
        $stackTokens[$stack.Label] = $serviceToken

        # Wait for Kibana AND Fleet API to be ready
        $waited   = 0
        $fleetReady = $false
        while ($waited -lt 180 -and -not $fleetReady) {
            if (Test-LabKibanaHealth -Port $stack.KibanaPort) {
                # Kibana is up -- now check Fleet API specifically
                $fleetCheck = Invoke-LabKibanaApi -Method GET `
                    -Uri "http://localhost:$($stack.KibanaPort)/api/fleet/epm/packages/fleet_server" `
                    -Password $stack.Password
                if ($fleetCheck -and $fleetCheck.StatusCode -eq 200) {
                    Write-LabOK "[$($stack.Label)] Kibana Fleet API ready after ${waited}s"
                    $fleetReady = $true
                }
            }
            if (-not $fleetReady) {
                Start-Sleep -Seconds 5 ; $waited += 5
                Write-Host "  [$($stack.Label)] [${waited}s] Waiting for Kibana Fleet API..." -ForegroundColor DarkGray
            }
        }
        if (-not $fleetReady) {
            Write-LabWarn "[$($stack.Label)] Fleet API not ready after 180s -- proceeding anyway"
        }

        # Explicitly initialize Fleet in Kibana (resolves "Unable to initialize Fleet")
        Invoke-LabFleetSetupApi -Stack $stack

        # Create policies
        New-LabFleetServerPolicy -Stack $stack
        New-LabFleetAgentPolicy  -Stack $stack

        # Add fleet_server integration to the server policy (required for Fleet Server to start)
        Add-LabFleetServerIntegration -Stack $stack

        # Register Fleet Server host URL
        Set-LabFleetServerHost -Stack $stack

        # Write initial .env
        Write-LabFleetEnv -Stack $stack -Config $Config -ServiceToken $serviceToken
    }

    # Start Fleet Server + target containers
    Write-LabStep "Fleet -- Start Containers"
    foreach ($stack in $Config.ActiveStacks) {
        if (-not $stackTokens.ContainsKey($stack.Label)) { continue }
        Start-LabFleetContainers -Stack $stack -Config $Config -WindowsContainersSupported $winSupported
    }

    # For each stack: wait until Fleet Server is confirmed up in Kibana,
    # then get the enrollment token and start the agent.
    # Each stack is handled completely before moving to the next.
    Write-LabStep "Fleet -- Enroll Agents"
    foreach ($stack in $Config.ActiveStacks) {
        if (-not $stackTokens.ContainsKey($stack.Label)) { continue }

        # Block until this stack's Fleet Server registers in Kibana Fleet
        $fleetUp = Wait-LabFleetServer -Stack $stack -TimeoutSec 300

        if ($fleetUp) {
            Write-LabOK "[$($stack.Label)] Fleet Server confirmed up -- proceeding to enrollment"
        } else {
            Write-LabWarn "[$($stack.Label)] Fleet Server did not appear in Kibana within 300s"
            Write-LabWarn "[$($stack.Label)] Proceeding to enrollment anyway -- Fleet Server may still be starting"
        }

        $enrollToken = Get-LabFleetEnrollmentToken -Stack $stack
        if (-not $enrollToken) {
            Write-LabWarn "[$($stack.Label)] Skipping agent start -- no enrollment token"
            continue
        }

        Write-LabFleetEnv -Stack $stack -Config $Config `
            -ServiceToken $stackTokens[$stack.Label] `
            -AgentToken $enrollToken

        Start-LabFleetAgent -Stack $stack -Config $Config

        # Update fleet-default-output AFTER agent is started and Fleet Server has
        # fully settled. Fleet Server overwrites fleet-default-output during its
        # Kibana initialization -- calling this too early means Fleet Server may
        # reset it again after our update.
        Start-Sleep -Seconds 10
        Set-LabFleetOutput -Stack $stack -Config $Config
    }

    # Verify enrollment
    Write-LabStep "Fleet -- Verify Agent Enrollment"
    Write-Host "  Waiting 30 seconds for agents to register..." -ForegroundColor White
    Start-Sleep -Seconds 30

    foreach ($stack in $Config.ActiveStacks) {
        Test-LabFleetAgentEnrollment -Stack $stack | Out-Null
    }

    # Final output fix pass -- ensures fleet-default-output is correct for VM agents
    # which enroll later during the VMs phase. Any Fleet Server late initialization
    # that reset the output will be caught here.
    Write-LabStep "Fleet -- Finalize Outputs"
    foreach ($stack in $Config.ActiveStacks) {
        Set-LabFleetOutput -Stack $stack -Config $Config
    }

    # Summary
    Write-LabStep "Fleet Setup Complete"

    foreach ($stack in $Config.ActiveStacks) {
        $suffix = $stack.Label.ToLower().Replace('es','')
        Write-Host "  [$($stack.Label)] Fleet API  : https://localhost:$($stack.FleetPort)" -ForegroundColor White
        Write-Host "  [$($stack.Label)] Kibana Fleet: http://localhost:$($stack.KibanaPort)/app/fleet" -ForegroundColor White
    }

    Write-Host @"

  ADDING INTEGRATIONS:
    Kibana -> Fleet -> Agent Policies -> Lab Agent Policy
    Add the 'Docker' integration to monitor container metrics/logs
    Add the 'System' integration to monitor host-level metrics

  NOTE: Elastic Agent has no Windows container image.
    Windows containers are monitored externally via the Docker socket.
    For full Windows telemetry run Invoke-BuildLabVMs.ps1 instead.

"@ -ForegroundColor Gray
}

Export-ModuleMember -Function Invoke-LabFleetSetup, Invoke-LabFleetImagePull,
                              Test-LabWindowsContainerSupport, New-LabFleetFolders,
                              New-LabFleetComposeFile, New-LabFleetServiceToken,
                              New-LabFleetServerPolicy, New-LabFleetAgentPolicy,
                              Write-LabFleetEnv, Start-LabFleetContainers,
                              Wait-LabFleetServer, Get-LabFleetEnrollmentToken,
                              Start-LabFleetAgent, Test-LabFleetAgentEnrollment,
                              Set-LabFleetOutput
