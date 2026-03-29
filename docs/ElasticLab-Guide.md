# ElasticLab — User Guide

## What Is ElasticLab?

ElasticLab is an automated PowerShell-based lab environment that builds and manages a full Elastic Stack on a Windows workstation using Docker Desktop and Hyper-V virtual machines. It is designed for engineers who need to test, learn, or demonstrate Elastic capabilities across both the current stable (8.x) and latest (9.x) versions of the stack simultaneously.

A single command can bring up the entire environment from scratch — including Elasticsearch, Kibana, machine learning inference endpoints, Fleet Server, monitored containers, and enrolled Windows and Linux virtual machines — or tear it all back down cleanly when no longer needed.

---

## What Gets Built

ElasticLab deploys the following across three phases:

### Phase 1 — Elastic Stack

| Component | ES8 | ES9 |
|-----------|-----|-----|
| Elasticsearch | Port 9208 | Port 9209 |
| Kibana | Port 5601 | Port 5602 |
| ELSER (semantic search ML model) | ✓ | ✓ |
| Ollama (local LLM inference) | Shared | Shared |

Both stacks run independently in Docker on isolated networks. Each has its own credentials, data volumes, and configuration.

### Phase 2 — Fleet Server

| Component | ES8 Stack | ES9 Stack |
|-----------|-----------|-----------|
| Fleet Server container | Port 8220 | Port 8221 |
| Linux target container (Ubuntu 22.04) | ✓ | ✓ |
| Elastic Agent container (Docker monitoring) | ✓ | ✓ |

Fleet Server manages agent enrollment and policy distribution. The Docker-based Elastic Agent monitors container metrics and logs from the host Docker socket.

### Phase 3 — Virtual Machines

| VM | OS | Enrolled To |
|----|-----|------------|
| vm-windows-8 | Windows Server 2022 | Fleet Server 8 |
| vm-windows-9 | Windows Server 2022 | Fleet Server 9 |
| vm-linux-8 | Ubuntu 22.04 | Fleet Server 8 |
| vm-linux-9 | Ubuntu 22.04 | Fleet Server 9 |

Each VM runs the Elastic Agent natively, providing full OS-level telemetry including Windows Event Log, Windows registry, system metrics, disk, network, and process data — capabilities not available from Docker containers.

---

## What You Can Do With This Lab

Once the environment is running you have access to:

**Elasticsearch capabilities**
- Full-text search across both ES8 and ES9 simultaneously
- Semantic search via ELSER (`.elser_model_2_linux-x86_64`)
- Vector search and hybrid search patterns
- Side-by-side comparison of ES8 vs ES9 behavior and API changes
- Local LLM inference via Ollama (llama3.2 by default)

**Fleet and agent monitoring**
- Fleet-managed agent policy deployment across Docker containers and full VMs
- System integration data: CPU, memory, disk, network, processes
- Windows-specific telemetry: Event Log (Security, System, Application), Windows Defender, services
- Log collection from all monitored hosts
- Agent health monitoring across four separate agents per stack

**Development and testing**
- A safe isolated environment to test index mappings, ingest pipelines, and queries
- API-level access to both stacks from the host (`http://localhost:9208`, `http://localhost:9209`)
- Kibana UI for both stacks for dashboards, Dev Tools, and Fleet management
- A realistic multi-host monitoring scenario for testing alerting and detection rules

---

## Prerequisites

### Required Software

All of the following must be installed and running before executing the build scripts.

| Software | Version | Download |
|----------|---------|----------|
| Windows 10/11 Pro, Enterprise, or Education | Any | — |
| PowerShell | 5.1 or later | Built into Windows |
| Docker Desktop | Latest | https://www.docker.com/products/docker-desktop/ |
| WSL2 | Any | `wsl --install` in PowerShell as Administrator |
| Vagrant | 2.3 or later | https://www.vagrantup.com/downloads (auto-installed if winget available) |

> **Note:** Windows Home edition is not supported. Hyper-V requires Pro, Enterprise, or Education.

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 24 GB | 32 GB or more |
| Free disk space | 40 GB | 60 GB or more |
| CPU cores | 8 | 12 or more |

> **RAM breakdown:** ES8 + ES9 Docker stacks use approximately 10–12 GB. Four VMs use approximately 10 GB (two Windows VMs at 4 GB each, two Linux VMs at 1 GB each). Additional overhead for Docker Desktop and the host OS requires the remainder.

### Enabling Prerequisites

**WSL2:**
```powershell
# Run as Administrator
wsl --install
# Reboot when prompted
```

**Hyper-V (if not already enabled):**
```powershell
# Run as Administrator
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
# Reboot when prompted
```

**Docker Desktop:**
1. Download and install from https://www.docker.com/products/docker-desktop/
2. During setup, ensure WSL2 integration is selected
3. Start Docker Desktop and wait for it to show as running in the system tray
4. Verify: `docker info` should return without errors

---

## Installation

1. Download `ElasticLab.zip` and extract it to a folder of your choice. The recommended location is your Desktop or `C:\Scripts\`.

2. The extracted folder should contain:
```
ElasticLab\
  Invoke-ElasticLab.ps1    -- Main driver script
  config\
    LabConfig.psd1          -- All configuration settings
  modules\
    ElasticLab.psd1
    ElasticLab.psm1
    ElasticLab.Core.psm1
    ElasticLab.Docker.psm1
    ElasticLab.Fleet.psm1
    ElasticLab.VMs.psm1
    ElasticLab.AI.psm1
    ElasticLab.License.psm1
    ElasticLab.Preflight.psm1
    ElasticLab.Invoke.psm1
    ElasticLab.Cleanup.psm1
```

3. Review and optionally edit `config\LabConfig.psd1` before running. The defaults are ready to use — editing is only needed if you want to change ports, credentials, versions, or resource allocation.

---

## Configuration Reference

All settings live in `config\LabConfig.psd1`. The file is a PowerShell data file — it contains only key-value pairs, no executable code.

### Stack Selection

```powershell
StackMode = "Both"   # "8" = ES8 only | "9" = ES9 only | "Both" = both stacks
```

This can also be overridden at runtime with the `-Stack` parameter without editing the file.

### Ports

```powershell
ES8Port          = 9208   # Elasticsearch 8 external port
ES9Port          = 9209   # Elasticsearch 9 external port
Kibana8Port      = 5601   # Kibana 8
Kibana9Port      = 5602   # Kibana 9
FleetServer8Port = 8220   # Fleet Server 8
FleetServer9Port = 8221   # Fleet Server 9
```

### Credentials

```powershell
ES8Password = "changeme8"   # Elasticsearch 8 elastic user password
ES9Password = "changeme9"   # Elasticsearch 9 elastic user password
```

### AI Tools

```powershell
AITool = "Both"   # "ELSER" | "Ollama" | "Both" | "None"
```

### VM Resources

```powershell
WindowsVMMemoryMB = 4096   # RAM per Windows VM (MB)
WindowsVMCPUs     = 2      # vCPUs per Windows VM
LinuxVMMemoryMB   = 1024   # RAM per Linux VM (MB)
LinuxVMCPUs       = 1      # vCPUs per Linux VM
```

---

## Running the Lab

Open PowerShell **as Administrator** and navigate to the folder where you extracted ElasticLab.

### Full Build (All Phases)

```powershell
.\Invoke-ElasticLab.ps1
```

Runs all three phases in sequence: Elastic → Fleet → VMs. This is the default. Expect the first run to take 30–60 minutes depending on internet speed (Vagrant boxes are approximately 6 GB for Windows and 600 MB for Linux).

### Run a Single Stack

```powershell
# ES8 only — all phases
.\Invoke-ElasticLab.ps1 -Stack 8

# ES9 only — all phases
.\Invoke-ElasticLab.ps1 -Stack 9

# Both stacks (same as default)
.\Invoke-ElasticLab.ps1 -Stack Both
```

The `-Stack` parameter overrides the `StackMode` setting in `LabConfig.psd1` without requiring you to edit the file.

### Run Individual Phases

```powershell
# Elastic Stack only (Elasticsearch + Kibana + ELSER + Ollama)
.\Invoke-ElasticLab.ps1 -Phase Elastic

# Fleet only (requires Elastic phase to be running)
.\Invoke-ElasticLab.ps1 -Phase Fleet

# VMs only (requires Fleet phase to be running)
.\Invoke-ElasticLab.ps1 -Phase VMs

# Tear everything down
.\Invoke-ElasticLab.ps1 -Phase Cleanup
```

Phases can be combined with the `-Stack` parameter:

```powershell
# ES9 only, Fleet phase
.\Invoke-ElasticLab.ps1 -Phase Fleet -Stack 9
```

---

## Accessing the Environment

Once the build completes, the following endpoints are available from your host machine:

### Kibana (Web UI)

| Stack | URL | Username | Password |
|-------|-----|----------|---------|
| ES8 | http://localhost:5601 | elastic | changeme8 |
| ES9 | http://localhost:5602 | elastic | changeme9 |

### Elasticsearch (API)

| Stack | URL | Username | Password |
|-------|-----|----------|---------|
| ES8 | http://localhost:9208 | elastic | changeme8 |
| ES9 | http://localhost:9209 | elastic | changeme9 |

### Fleet Server

| Stack | URL |
|-------|-----|
| ES8 | http://localhost:8220 |
| ES9 | http://localhost:8221 |

### Fleet Management (Kibana)

| Stack | URL |
|-------|-----|
| ES8 | http://localhost:5601/app/fleet |
| ES9 | http://localhost:5602/app/fleet |

---

## Verifying the Environment

### Check Docker containers are running

```powershell
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected containers: `es8`, `kibana8`, `es9`, `kibana9`, `fleet8`, `fleet9`, `linux8`, `linux9`, `agent8`, `agent9`

### Check Elasticsearch health

```powershell
# ES8
$h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:changeme8")) }
(Invoke-RestMethod -Uri "http://localhost:9208/_cluster/health" -Headers $h).status

# ES9
$h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:changeme9")) }
(Invoke-RestMethod -Uri "http://localhost:9209/_cluster/health" -Headers $h).status
```

Both should return `green`.

### Check VM status

```powershell
Get-VM | Where-Object { $_.Name -like "elastic-lab-*" } | Select-Object Name, State
```

### Check agent status on a Linux VM

```powershell
cd C:\elastic-lab\vm-linux-8
vagrant ssh -c "sudo /usr/share/elastic-agent/elastic-agent status"
```

---

## Cleanup

To tear down the entire environment:

```powershell
.\Invoke-ElasticLab.ps1 -Phase Cleanup
```

The cleanup phase will prompt you interactively for each category of artifacts (Vagrant boxes, agent installers, Ollama, ELSER model, Docker images, lab folder). This allows you to preserve large downloads like Vagrant boxes (~6 GB) across rebuilds to avoid re-downloading them.

To tear down a single stack:

```powershell
# ES8 only
.\Invoke-ElasticLab.ps1 -Phase Cleanup -Stack 8

# ES9 only
.\Invoke-ElasticLab.ps1 -Phase Cleanup -Stack 9
```

---

## Troubleshooting

### VM agents showing as degraded in Fleet

This can happen if the Fleet output configuration gets reset after a Docker restart. Run the following to re-apply the correct output URLs:

```powershell
$h8 = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:changeme8")); "kbn-xsrf"="true"; "Content-Type"="application/json" }
$h9 = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:changeme9")); "kbn-xsrf"="true"; "Content-Type"="application/json" }
$ip = (Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" -AddressFamily IPv4).IPAddress
Invoke-RestMethod -Uri "http://localhost:5601/api/fleet/outputs/fleet-default-output" -Method PUT -Headers $h8 -Body "{`"name`":`"default`",`"type`":`"elasticsearch`",`"hosts`":[`"http://${ip}:9208`"],`"is_default`":true,`"is_default_monitoring`":true,`"config_yaml`":`"ssl.verification_mode: none`"}"
Invoke-RestMethod -Uri "http://localhost:5602/api/fleet/outputs/fleet-default-output" -Method PUT -Headers $h9 -Body "{`"name`":`"default`",`"type`":`"elasticsearch`",`"hosts`":[`"http://${ip}:9209`"],`"is_default`":true,`"is_default_monitoring`":true,`"config_yaml`":`"ssl.verification_mode: none`"}"
```

### Docker Desktop not running

```powershell
# Check status
docker info

# Start Docker Desktop
Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
# Wait 30-60 seconds then retry
```

### VAGRANT_HOME not set correctly

If Vagrant re-downloads boxes on every build, the `VAGRANT_HOME` environment variable may not be persisted. Check and set it:

```powershell
# Check
[System.Environment]::GetEnvironmentVariable("VAGRANT_HOME", "Machine")

# Should return: C:\elastic-lab\artifacts\.vagrant.d
# If blank or wrong, set it:
[System.Environment]::SetEnvironmentVariable("VAGRANT_HOME", "C:\elastic-lab\artifacts\.vagrant.d", "Machine")
```

### WinRM errors when connecting to VMs

```powershell
# Run as Administrator on the host
Start-Service WinRM
winrm quickconfig -y
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
```

### Log files

All run logs are saved to `C:\elastic-lab\logs\` with a timestamp and phase in the filename. Check these for detailed error output if a phase fails.

---

## File Locations

| Item | Location |
|------|---------|
| Lab root | `C:\elastic-lab\` |
| Elasticsearch 8 data | `C:\elastic-lab\elastic8\` |
| Elasticsearch 9 data | `C:\elastic-lab\elastic9\` |
| Fleet Server 8 | `C:\elastic-lab\fleet8\` |
| Fleet Server 9 | `C:\elastic-lab\fleet9\` |
| VM directories | `C:\elastic-lab\vm-windows-8\` etc. |
| Vagrant box cache | `C:\elastic-lab\artifacts\.vagrant.d\boxes\` |
| Agent installers | `C:\elastic-lab\artifacts\agent-installers\` |
| Ollama installer | `C:\elastic-lab\artifacts\installers\` |
| ELSER model | `C:\elastic-lab\artifacts\elser-model\` |
| Run logs | `C:\elastic-lab\logs\` |
