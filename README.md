# ElasticLab

Automated PowerShell lab environment that deploys a full Elastic Stack on a Windows workstation using Docker Desktop and Hyper-V. Runs Elasticsearch 8.x and 9.x simultaneously, with Fleet Server, monitored containers, ELSER semantic search, Ollama LLM inference, and enrolled Windows and Linux virtual machines.

> A single command builds the entire environment from scratch. Another tears it all down.

---

## What Gets Built

| Phase | Components |
|-------|-----------|
| **Elastic** | Elasticsearch 8 + 9, Kibana 8 + 9, ELSER ML model, Ollama |
| **Fleet** | Fleet Server 8 + 9, Ubuntu target containers, Elastic Agent containers |
| **VMs** | 4 Hyper-V VMs (2x Windows Server 2022, 2x Ubuntu 22.04), each enrolled in Fleet |

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Windows 10/11 **Pro, Enterprise, or Education** | Home edition not supported (no Hyper-V) |
| PowerShell 5.1+ | Run as Administrator |
| Docker Desktop | https://www.docker.com/products/docker-desktop/ |
| WSL2 | `wsl --install` then reboot |
| Vagrant 2.3+ | Auto-installed via winget if not present |
| **32 GB RAM** recommended | Minimum 24 GB |
| **60 GB free disk** recommended | Minimum 40 GB |

---

## Quick Start

**1. Clone the repo**
```powershell
git clone https://github.com/YOUR_USERNAME/ElasticLab.git
cd ElasticLab
```

**2. Edit the config**
```powershell
notepad config\LabConfig.psd1
```
At minimum, change `ES8Password` and `ES9Password` from `CHANGE_ME_8` / `CHANGE_ME_9` to secure values of your choice.

**3. Run as Administrator**
```powershell
# Full build -- all three phases (Elastic -> Fleet -> VMs)
.\Invoke-ElasticLab.ps1

# Single stack
.\Invoke-ElasticLab.ps1 -Stack 8    # ES8 only
.\Invoke-ElasticLab.ps1 -Stack 9    # ES9 only

# Individual phases
.\Invoke-ElasticLab.ps1 -Phase Elastic
.\Invoke-ElasticLab.ps1 -Phase Fleet
.\Invoke-ElasticLab.ps1 -Phase VMs

# Tear everything down
.\Invoke-ElasticLab.ps1 -Phase Cleanup
```

> **First run:** Allow 30-60 minutes. Vagrant boxes are ~6 GB (Windows) and ~600 MB (Linux) and download once, then cache locally for fast subsequent builds.

---

## Access Points

| Service | ES8 | ES9 |
|---------|-----|-----|
| Kibana | http://localhost:5601 | http://localhost:5602 |
| Elasticsearch | http://localhost:9208 | http://localhost:9209 |
| Fleet Server | http://localhost:8220 | http://localhost:8221 |
| Fleet UI | http://localhost:5601/app/fleet | http://localhost:5602/app/fleet |

Default username: `elastic`  
Password: whatever you set in `LabConfig.psd1`

---

## Documentation

See [`docs/ElasticLab-Guide.md`](docs/ElasticLab-Guide.md) for the full user guide covering:

- Detailed prerequisites and setup
- Complete configuration reference
- Usage examples for all phases and stack modes
- Environment verification steps
- Troubleshooting common issues
- File location reference

A Word version is also available at [`docs/ElasticLab-Guide.docx`](docs/ElasticLab-Guide.docx).

---

## Repository Structure

```
ElasticLab/
  Invoke-ElasticLab.ps1       -- Main driver script (only script you run)
  config/
    LabConfig.psd1             -- All configuration settings
  modules/
    ElasticLab.psd1            -- Module manifest
    ElasticLab.psm1            -- Module loader
    ElasticLab.Core.psm1       -- Shared helpers, HTTP, output formatting
    ElasticLab.Preflight.psm1  -- Pre-flight checks
    ElasticLab.Docker.psm1     -- Elasticsearch + Kibana stack
    ElasticLab.Fleet.psm1      -- Fleet Server + agent enrollment
    ElasticLab.VMs.psm1        -- Vagrant VM provisioning
    ElasticLab.AI.psm1         -- ELSER + Ollama setup
    ElasticLab.License.psm1    -- Elastic license management
    ElasticLab.Invoke.psm1     -- Phase orchestration
    ElasticLab.Cleanup.psm1    -- Teardown and cleanup
  docs/
    ElasticLab-Guide.md        -- Full user guide (Markdown)
    ElasticLab-Guide.docx      -- Full user guide (Word)
```

---

## Notes

- All lab data is written to `C:\elastic-lab\` (configurable via `LabRoot` in `LabConfig.psd1`). This folder is excluded from the repo via `.gitignore`.
- The `.env` files containing credentials are generated at runtime and never committed.
- Run logs are written to `C:\elastic-lab\logs\` after each phase.

---

## License

MIT License -- see [LICENSE](LICENSE) for details.
