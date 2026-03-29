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

## AI Integration

ElasticLab deploys two AI components — ELSER and Ollama — and wires them into Elasticsearch as inference endpoints. Here is how to verify they are working and demonstrate their value.

### ELSER — Semantic Search

ELSER (Elastic Learned Sparse EncodeR) enables search by *meaning* rather than exact keywords. The classic demonstration is showing that a keyword search misses relevant results that a semantic search finds.

**1. Create an index with a sparse vector field**

In Kibana Dev Tools (`http://localhost:5601/app/dev_tools`):

```json
PUT /lab-docs
{
  "mappings": {
    "properties": {
      "text": { "type": "text" },
      "text_embedding": { "type": "sparse_vector" }
    }
  }
}
```

**2. Create an ingest pipeline that runs ELSER**

```json
PUT _ingest/pipeline/elser-pipeline
{
  "processors": [
    {
      "inference": {
        "model_id": "elser-local",
        "input_output": [
          { "input_field": "text", "output_field": "text_embedding" }
        ]
      }
    }
  ]
}
```

**3. Index documents through the pipeline**

```json
POST /lab-docs/_doc?pipeline=elser-pipeline
{ "text": "The server is running out of memory and needs to be restarted" }

POST /lab-docs/_doc?pipeline=elser-pipeline
{ "text": "Elasticsearch heap pressure is causing performance degradation" }

POST /lab-docs/_doc?pipeline=elser-pipeline
{ "text": "The quarterly sales report shows a 12% increase in revenue" }

POST /lab-docs/_doc?pipeline=elser-pipeline
{ "text": "Network latency spikes are affecting application response times" }
```

**4. Compare keyword vs semantic search**

Keyword search — returns no results because "RAM" does not appear in any document:
```json
GET /lab-docs/_search
{
  "query": {
    "match": { "text": "RAM problem" }
  }
}
```

Semantic search — finds the memory and heap documents because it understands that "RAM problem" means the same thing as memory pressure:
```json
GET /lab-docs/_search
{
  "query": {
    "sparse_vector": {
      "field": "text_embedding",
      "inference_id": "elser-local",
      "query": "RAM problem"
    }
  }
}
```

---

### Ollama — Local LLM Inference

Ollama runs a local large language model (llama3.2 by default) accessible through the Elasticsearch inference API. No data leaves the machine and no external API keys are required.

**1. Verify Ollama is reachable**

```powershell
Invoke-RestMethod -Uri "http://localhost:11434/api/tags"
```

Should return the list of downloaded models including `llama3.2`.

**2. Query the LLM through the Elasticsearch inference API**

In Kibana Dev Tools:
```json
POST _inference/completion/ollama-local
{
  "input": "In one sentence, what is Elasticsearch used for?"
}
```

This proves the model is accessible through Elastic's inference layer rather than requiring a direct call to Ollama.

---

### RAG — Retrieval Augmented Generation

The most compelling demonstration combines both components. Use ELSER to retrieve relevant documents, then pass them to Ollama to generate a natural language answer — a basic RAG (Retrieval Augmented Generation) pattern running entirely locally.

**Step 1 — Retrieve relevant documents with ELSER**
```json
GET /lab-docs/_search
{
  "query": {
    "sparse_vector": {
      "field": "text_embedding",
      "inference_id": "elser-local",
      "query": "what performance issues are there?"
    }
  },
  "size": 2
}
```

**Step 2 — Pass retrieved content to Ollama for generation**
```json
POST _inference/completion/ollama-local
{
  "input": "Based on these observations: 'Elasticsearch heap pressure is causing performance degradation' and 'Network latency spikes are affecting application response times' — summarize what performance issues exist and suggest a remedy."
}
```

This demonstrates a complete local AI pipeline: semantic retrieval with ELSER followed by natural language generation with Ollama, with no external API dependencies.

---

### VM Telemetry — Real Host Data in Kibana

The enrolled VMs provide the most tangible observability demonstration. Once the VMs phase completes, open Kibana and navigate to **Discover** or **Dashboards**. You will see real data flowing from all four VMs including:

- **Windows Event Log** — Security, System, and Application event streams
- **Windows process and service metrics** — CPU, memory, handles per process
- **Linux system metrics** — CPU, memory, disk I/O, network per host
- **File integrity and log collection** — from both Windows and Linux hosts

This is a realistic multi-host monitoring scenario that can be used to build and test detection rules, alerting, and dashboards against live data.

| Capability | What It Demonstrates |
|------------|----------------------|
| ELSER semantic search | Find relevant content without exact keyword matches |
| Ollama LLM inference | AI generation through Elasticsearch with no external API |
| RAG pattern | Intelligent Q&A over your own data, running entirely locally |
| ES8 vs ES9 side by side | Run the same queries on both stacks to compare behavior |
| VM telemetry | Real Windows Event Log, process, and system data in Kibana |



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

## Elastic Trial License

ElasticLab automatically activates a **30-day Elastic Enterprise trial license** on each stack during the build. This enables all paid features including:

- Machine learning (required for ELSER)
- Fleet Server and centralized agent management
- Advanced security features
- Alerting and detection rules

**After 30 days** the license reverts to Basic. ELSER and Fleet Server will stop functioning. To continue using the full feature set you have two options:

- **Rebuild the lab** — run `.\Invoke-ElasticLab.ps1 -Phase Cleanup` followed by a full rebuild to start a fresh 30-day trial on new Elasticsearch data volumes
- **Apply a valid license** — upload a paid license via Kibana under **Stack Management → License Management**

> This lab is intended for testing and evaluation purposes. The 30-day Enterprise trial is provided by Elastic for non-production use.

---

## Notes

- All lab data is written to `C:\elastic-lab\` (configurable via `LabRoot` in `LabConfig.psd1`). This folder is excluded from the repo via `.gitignore`.
- The `.env` files containing credentials are generated at runtime and never committed.
- Run logs are written to `C:\elastic-lab\logs\` after each phase.

---

## License

MIT License -- see [LICENSE](LICENSE) for details.
