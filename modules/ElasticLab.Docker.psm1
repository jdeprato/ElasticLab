# =============================================================================
# ElasticLab.Docker.psm1
# All Docker-related setup: WSL2 config, folder creation, compose file
# generation, image pulls, Elasticsearch start, Kibana start and health wait.
# =============================================================================

function Set-LabWslConfig {
    <#
    .SYNOPSIS
        Ensures vm.max_map_count=262144 is set in ~/.wslconfig.
        Required for Elasticsearch to start successfully inside Docker/WSL2.
    #>
    param([hashtable]$Config)

    Write-LabStep "WSL2 -- Configure vm.max_map_count"

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"

    if (Test-Path $wslConfigPath) {
        $content = Get-Content $wslConfigPath -Raw
        if ($content -match "vm.max_map_count") {
            Write-LabOK ".wslconfig already contains vm.max_map_count -- no change needed"
            return
        }
        if ($content -match "\[wsl2\]") {
            $content = $content -replace "(\[wsl2\])", "`$1`nkernelCommandLine = sysctl.vm.max_map_count=262144"
        } else {
            $content += "`n[wsl2]`nkernelCommandLine = sysctl.vm.max_map_count=262144`n"
        }
        Set-Content -Path $wslConfigPath -Value $content
        Write-LabOK "Updated .wslconfig with vm.max_map_count=262144"
    } else {
        "[wsl2]`nkernelCommandLine = sysctl.vm.max_map_count=262144" |
            Set-Content -Path $wslConfigPath
        Write-LabOK "Created $wslConfigPath"
    }

    Write-LabWarn "A WSL2 restart is required for this to take effect."
    Write-LabWarn "If ES fails to start, run: wsl --shutdown  then restart Docker Desktop."
}

function New-LabFolderStructure {
    <#
    .SYNOPSIS
        Creates the lab directory structure under LabRoot.
        All artifact subdirectories live under LabRoot\artifacts\.
    #>
    param([hashtable]$Config)

    Write-LabStep "Folders -- Create Lab Directory Structure"

    $folders = @(
        $Config.LabRoot,
        $Config.ArtifactsDir,
        $Config.AgentInstallerCache,
        (Join-Path $Config.ArtifactsDir "installers")
    )

    foreach ($stack in $Config.ActiveStacks) {
        $folders += $stack.ComposeDir
    }

    if ($Config.SetupElser) {
        $folders += $Config.ElserModelDir
    }

    foreach ($folder in $folders) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-LabOK "Created: $folder"
        } else {
            Write-LabInfo "Already exists: $folder"
        }
    }
}

function Invoke-LabImagePull {
    <#
    .SYNOPSIS
        Pulls all required Docker images for the active stacks.
    #>
    param([hashtable]$Config)

    Write-LabStep "Docker -- Pull Images"

    $images = @()
    foreach ($stack in $Config.ActiveStacks) {
        $images += "$($Config.DockerRegistry)/elasticsearch/elasticsearch:$($stack.Version)"
        $images += "$($Config.DockerRegistry)/kibana/kibana:$($stack.Version)"
    }
    if ($Config.SetupElser) { $images += "nginx:alpine" }

    foreach ($image in $images) {
        Write-Host "`n  Pulling: $image" -ForegroundColor White
        docker pull $image 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            Write-LabOK "Pulled: $image"
        } else {
            Write-LabFail "Failed to pull: $image -- check internet and version"
            exit 1
        }
    }
}

function New-LabComposeFiles {
    <#
    .SYNOPSIS
        Generates docker-compose.yml and .env for each active stack.
        Conditionally includes ELSER nginx repo service when AITool includes ELSER.
    #>
    param([hashtable]$Config)

    Write-LabStep "Docker -- Generate Compose Files"

    foreach ($stack in $Config.ActiveStacks) {
        $content = _New-StackComposeContent -Stack $stack -Config $Config
        _Write-StackComposeFiles -Stack $stack -Content $content
    }
}

function Start-LabElasticsearch {
    <#
    .SYNOPSIS
        Starts Elasticsearch (and ELSER nginx repo if configured) for each active stack.
    #>
    param([hashtable]$Config)

    Write-LabStep "Docker -- Start Elasticsearch"

    foreach ($stack in $Config.ActiveStacks) {
        Write-Host "`n  Starting $($stack.Label) Elasticsearch$(if ($Config.SetupElser){' + ELSER repo'})..." -ForegroundColor White
        Push-Location $stack.ComposeDir
        if ($Config.SetupElser) {
            docker compose up -d $stack.ElserRepo $stack.ESContainer 2>&1 | ForEach-Object { Write-Host $_ }
        } else {
            docker compose up -d $stack.ESContainer 2>&1 | ForEach-Object { Write-Host $_ }
        }
        if ($LASTEXITCODE -eq 0) { Write-LabOK "$($stack.Label) Elasticsearch started" }
        else {
            Write-LabFail "Failed to start $($stack.Label) ES -- check: docker logs $($stack.ESContainer)"
            exit 1
        }
        Pop-Location
    }
}

function Wait-LabElasticsearch {
    <#
    .SYNOPSIS
        Polls each active Elasticsearch until healthy or timeout.
        Returns a hashtable of Label -> bool.
    #>
    param([hashtable]$Config, [int]$TimeoutSec = 180)

    Write-LabStep "Elasticsearch -- Wait for Health"

    $results = @{}
    foreach ($stack in $Config.ActiveStacks) {
        Write-Host "`n  Waiting for $($stack.Label) Elasticsearch..." -ForegroundColor White
        $waited = 0
        while ($waited -lt $TimeoutSec) {
            if (Test-LabElasticHealth -Port $stack.ESPort -Password $stack.Password) {
                Write-LabOK "$($stack.Label) healthy after ${waited}s"
                break
            }
            Start-Sleep -Seconds 5 ; $waited += 5
            Write-Host "  [${waited}s] Still waiting..." -ForegroundColor DarkGray
        }
        $results[$stack.Label] = Test-LabElasticHealth -Port $stack.ESPort -Password $stack.Password
        if (-not $results[$stack.Label]) {
            Write-LabFail "$($stack.Label) did not respond within ${TimeoutSec}s"
        }
    }
    return $results
}

function Set-LabKibanaSystemPassword {
    <#
    .SYNOPSIS
        Sets the kibana_system password for each active stack.
        Requires Elasticsearch to already be healthy (call Wait-LabElasticsearch first).
        Returns a hashtable of Label -> bool indicating which stacks succeeded.
    #>
    param([hashtable]$Config, [hashtable]$HealthResults)

    Write-LabStep "Elasticsearch -- Set kibana_system Password"

    $results = @{}
    foreach ($stack in $Config.ActiveStacks) {
        if (-not $HealthResults[$stack.Label]) {
            Write-LabWarn "$($stack.Label) not healthy -- skipping kibana_system password"
            $results[$stack.Label] = $false
            continue
        }
        $headers = Get-LabBasicAuthHeader -Password $stack.Password
        $headers["Content-Type"] = "application/json"
        try {
            $r = Invoke-WebRequest `
                -Uri "http://localhost:$($stack.ESPort)/_security/user/kibana_system/_password" `
                -Method POST -Headers $headers `
                -Body "{`"password`":`"$($stack.Password)`"}" `
                -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-LabOK "$($stack.Label) kibana_system password set"
                $results[$stack.Label] = $true
            }
        } catch {
            Write-LabFail "$($stack.Label) kibana_system password failed: $_"
            $results[$stack.Label] = $false
        }
    }
    return $results
}

function Start-LabKibana {
    <#
    .SYNOPSIS
        Starts Kibana for each active stack where the ES password was successfully set.
    #>
    param([hashtable]$Config, [hashtable]$PasswordResults)

    Write-LabStep "Docker -- Start Kibana"

    foreach ($stack in $Config.ActiveStacks) {
        if ($PasswordResults[$stack.Label]) {
            Write-Host "`n  Starting $($stack.Label) Kibana..." -ForegroundColor White
            Push-Location $stack.ComposeDir
            docker compose --profile kibana up -d $stack.KibanaContainer 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { Write-LabOK "$($stack.Label) Kibana started" }
            else { Write-LabWarn "Failed to start $($stack.Label) Kibana -- check: docker logs $($stack.KibanaContainer)" }
            Pop-Location
        } else {
            Write-LabWarn "Skipping $($stack.Label) Kibana -- ES password was not set"
        }
    }
}

function Wait-LabKibana {
    <#
    .SYNOPSIS
        Polls Kibana for each active stack until it reports 'available' or times out.
        Returns a hashtable of Label -> bool.
    #>
    param([hashtable]$Config, [hashtable]$PasswordResults)

    Write-LabStep "Kibana -- Wait for Initialization"

    $ready   = @{}
    $waited  = 0
    $maxWait = 180

    foreach ($stack in $Config.ActiveStacks) {
        $ready[$stack.Label] = $false
    }

    while ($waited -lt $maxWait) {
        $allDone = $true
        foreach ($stack in $Config.ActiveStacks) {
            if (-not $ready[$stack.Label] -and $PasswordResults[$stack.Label]) {
                $ready[$stack.Label] = Test-LabKibanaHealth -Port $stack.KibanaPort
                if (-not $ready[$stack.Label]) { $allDone = $false }
            }
        }
        if ($allDone) { break }
        Start-Sleep -Seconds 5 ; $waited += 5
        Write-Host "  [${waited}s] Checking Kibana..." -ForegroundColor DarkGray
    }

    foreach ($stack in $Config.ActiveStacks) {
        if ($ready[$stack.Label]) {
            Write-LabOK "$($stack.Label) Kibana available on port $($stack.KibanaPort)"
        } elseif ($PasswordResults[$stack.Label]) {
            Write-LabWarn "$($stack.Label) Kibana not ready within ${maxWait}s -- check: docker logs $($stack.KibanaContainer)"
        }
    }

    return $ready
}

# -- Private: compose content builder (pure -- no disk writes) -----------------

function _New-StackComposeContent {
    param([hashtable]$Stack, [hashtable]$Config)

    # Resolve all variables first -- these are referenced inside the here-strings below
    $stackName   = $Stack.Label.ToLower()
    $projectName = "elastic$($stackName.Replace('es',''))"
    $esName      = $Stack.ESContainer
    $kibanaName  = $Stack.KibanaContainer
    $netName     = "${projectName}-net"
    $volName     = "${esName}-data"
    $esPort      = $Stack.ESPort
    $kbPort      = $Stack.KibanaPort
    $version     = $Stack.Version
    $registry    = $Config.DockerRegistry

    $elserEnvBlock     = ""
    $elserDependsBlock = ""
    $elserServiceBlock = ""

    if ($Config.SetupElser) {
        $elserEnvBlock = @"
      - xpack.ml.model_repository=http://$($Stack.ElserRepo)
      - xpack.ml.enabled=true
"@
        $elserDependsBlock = @"
    depends_on:
      - $($Stack.ElserRepo)
"@
        $mountPath    = $Config.ElserModelDir.Replace('\', '/')
        $volumeMount  = "${mountPath}:/usr/share/nginx/html:ro"
        $elserServiceBlock = @"

  $($Stack.ElserRepo):
    image: nginx:alpine
    container_name: $($Stack.ElserRepo)
    volumes:
      - $volumeMount
    networks:
      - $netName
    restart: unless-stopped
"@
    }

    $compose = @"
name: $projectName

services:
  ${esName}:
    image: ${registry}/elasticsearch/elasticsearch:${version}
    container_name: $esName
    environment:
      - node.name=$esName
      - cluster.name=lab-cluster-$stackName
      - discovery.type=single-node
      - ELASTIC_PASSWORD=`${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms2g -Xmx2g"
$elserEnvBlock
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "${esPort}:9200"
    volumes:
      - ${volName}:/usr/share/elasticsearch/data
    networks:
      - $netName
$elserDependsBlock
$elserServiceBlock
  ${kibanaName}:
    image: ${registry}/kibana/kibana:${version}
    container_name: $kibanaName
    environment:
      - ELASTICSEARCH_HOSTS=http://${esName}:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=`${KIBANA_PASSWORD}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=elasticlab-32-char-encryption-key-00
      - XPACK_SECURITY_ENCRYPTIONKEY=elasticlab-32-char-security-key-0000
      - XPACK_REPORTING_ENCRYPTIONKEY=elasticlab-32-char-reporting-key-000
      - XPACK_FLEET_AGENTS_TLSCHECKDISABLED=true
    ports:
      - "${kbPort}:5601"
    depends_on:
      - $esName
    networks:
      - $netName
    profiles:
      - kibana

volumes:
  ${volName}:

networks:
  ${netName}:
    driver: bridge
"@

    $envContent = "ELASTIC_PASSWORD=$($Stack.Password)`nKIBANA_PASSWORD=$($Stack.Password)"

    return @{ Compose = $compose; Env = $envContent }
}

# -- Private: compose file writer (disk write -- separate from content build) ---

function _Write-StackComposeFiles {
    param([hashtable]$Stack, [hashtable]$Content)

    Set-Content -Path (Join-Path $Stack.ComposeDir "docker-compose.yml") -Value $Content.Compose
    Set-Content -Path (Join-Path $Stack.ComposeDir ".env")               -Value $Content.Env
    Write-LabOK "Compose files written: $($Stack.ComposeDir)"
}

Export-ModuleMember -Function Set-LabWslConfig, New-LabFolderStructure, Invoke-LabImagePull,
                              New-LabComposeFiles, Start-LabElasticsearch,
                              Wait-LabElasticsearch, Set-LabKibanaSystemPassword,
                              Start-LabKibana, Wait-LabKibana
