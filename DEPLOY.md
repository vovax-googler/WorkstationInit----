# DEPLOY.md — Deploy a Cloud Workstation (Claude Code + Antigravity preinstalled)

> Demonstration code provided "as-is", not a Google product, and with no support or warranty — see the
> full [disclaimer in README.md](./README.md).

This is the step-by-step runbook for deploying, from scratch, a Google Cloud Workstation whose default
workstation comes with the **Claude Code CLI** (`claude`) and the **Antigravity CLI** (`agy`) already
installed. It is written so a human **or** an agent (Claude Code CLI / `agy`) can follow it.

It uses the predefined `code-oss` image + a GCS-hosted **startup script** — no custom container image.

---

## 1. Information you need before you start

Collect these. Only the first three are usually project-specific; the rest have sane defaults.

| Info | Required? | What it is | Example |
| ---- | --------- | ---------- | ------- |
| **Project ID** | ✅ | The target GCP project | `my-gcp-project` |
| **Region** | ✅ | Where the cluster/VM live | `europe-west3` (Frankfurt) |
| **Bucket name** | ✅ | GCS bucket to host `startup.sh`. **Must be globally unique** | `gs://my-gcp-project-workstation-startup` |
| Cluster name | ⬜ | Workstations cluster to create/use | `cluster-workstations` |
| Config name | ⬜ | Workstation config to create | `ws-ai-default` |
| Workstation name | ⬜ | The workstation instance | `ws-default` |
| Machine type | ⬜ | VM size | `e2-standard-4` |
| Disk sizes | ⬜ | Boot + persistent `/home` (GB) | `50` / `50` |
| Replica zones | ⬜ | HA zones for the persistent disk | `europe-west3-a,europe-west3-b` |
| Service account | ⬜ | VM identity. Blank = default Compute SA | *(blank)* |
| `WS_USER` | ⬜ | User inside the image (home = persistent disk) | `user` |

All of these are set in a **`.env`** file (copy from `.env.example`).

### Account prerequisites (the scripts cannot grant these themselves)
- **Authenticated `gcloud`**: `gcloud auth login`.
- **Billing enabled** on the project.
- **IAM** on the project — `roles/owner` covers everything; the granular set:
  - `roles/serviceusage.serviceUsageAdmin` — enable APIs + create service identity
  - `roles/compute.networkAdmin` — VPC, subnet, Cloud Router, Cloud NAT
  - `roles/workstations.admin` — cluster, config, workstation
  - `roles/storage.admin` — create bucket + grant the VM SA read access
  - `roles/iam.serviceAccountAdmin` — grant the Workstations agent `actAs` on the VM SA

---

## 2. The files

| File | Role |
| ---- | ---- |
| `.env.example` | Template of all variables → copy to `.env` and edit |
| `bootstrap.sh` | **One-time per project**: enable APIs, create service identity, VPC/subnet, Cloud Router + NAT, cluster |
| `startup.sh` | Runs on the VM at boot: installs `claude` + `agy`, fixes PATH |
| `deploy.sh` | Upload `startup.sh`, grant IAM, create the config + workstation, start it |

---

## 3. Deploy — step by step

```bash
# 0) Authenticate and target the project
gcloud auth login
gcloud config set project <PROJECT_ID>

# 1) Get the repo and configure
git clone https://github.com/vovax-googler/WorkstationInit----.git WorkstationInit
cd WorkstationInit
cp .env.example .env
#   Edit .env: set PROJECT_ID, REGION, and a globally-unique BUCKET (others optional).

# 2) One-time project setup  (~15-20 min; the cluster is the slow part)
bash bootstrap.sh --dry-run     # optional: preview the gcloud commands
bash bootstrap.sh

# 3) Deploy the config + workstation
bash deploy.sh --dry-run        # optional: preview
bash deploy.sh
```

> Already have a Workstations cluster and network (with Cloud NAT for private VMs)? You can skip
> `bootstrap.sh` — just set `CLUSTER` in `.env` to the existing cluster and run `deploy.sh`.

### What each step does under the hood
- **`bootstrap.sh`**
  1. Enables `workstations`, `compute`, `storage` APIs.
  2. Creates the Cloud Workstations **service identity** (needed for the `actAs` grant later).
  3. Creates a custom-mode **VPC + subnet** with **Private Google Access**.
  4. Creates a **Cloud Router + Cloud NAT** — egress so the no-public-IP VM can `curl` during startup.
  5. Creates the **Workstations cluster**.
- **`deploy.sh`**
  1. Creates the bucket and uploads `startup.sh`.
  2. Grants the VM service account `roles/storage.objectViewer` on the bucket (so the VM can read the script).
  3. Grants the Workstations service agent `roles/iam.serviceAccountUser` (`actAs`) on the VM service account
     (so launching works).
  4. Creates the **config** (`code-oss` image, machine/disks/timeouts/ports, `--startup-script-uri`,
     pinned VM service account).
  5. Creates and **starts** the workstation.

---

## 4. Verify

Open the workstation from the
[Workstations console](https://console.cloud.google.com/workstations) → **Launch**, then in its terminal:

```bash
claude --version
agy --version
```

Both should print versions. (`startup.sh` adds `~/.local/bin` to `~/.bashrc`, so `claude` resolves in
new terminals.)

To confirm persistence: stop/start the workstation and re-check — `claude`/`agy` live on the persistent
`/home` disk.

---

## 5. Troubleshooting (issues seen in real runs)

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| **401 / `PERMISSION_DENIED` on `Workstations.GenerateAccessToken`** when clicking Launch | Config used the Google-managed VM service agent, which no one can `actAs` | `deploy.sh` now pins a normal SA and grants the Workstations agent `actAs` on it. If you edited the config, re-run `deploy.sh` and restart the workstation. |
| `bash: claude: command not found` (but `agy` works) | `~/.local/bin` not on PATH in the non-login terminal shell | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc` (already handled by `startup.sh` on new boots) |
| `claude` missing right after the **first** boot of a new workstation (`agy` works) | `startup.sh` ran before Cloud NAT egress was ready, and its `curl` failed. (`agy` comes pre-installed in the `code-oss` image, so it works either way and doesn't prove the script ran.) | Stop/start the workstation (NAT is ready by then), or re-run the script once from the workstation terminal: `gcloud storage cat <BUCKET>/startup.sh \| sudo bash` |
| `argument --allowed-ports: ... json or arg_dict` | Ports must be `first=/last=` arg_dicts | Already fixed in `deploy.sh` |
| Startup installs fail on a private VM | No internet egress | Ensure Cloud NAT exists for the subnet (created by `bootstrap.sh`); private VMs have no public IP |
| `agy --version` empty/fails | Antigravity install URL/command | Confirm `curl -fsSL https://antigravity.google/cli/install.sh \| bash` is current; update `startup.sh` if it changed |

After changing the config or `startup.sh`, **stop and start** the workstation to apply:
```bash
gcloud workstations stop  <WS> --config=<CONFIG> --cluster=<CLUSTER> --region=<REGION> --project=<PROJECT_ID>
gcloud workstations start <WS> --config=<CONFIG> --cluster=<CLUSTER> --region=<REGION> --project=<PROJECT_ID>
```
(If you changed `startup.sh`, re-upload it first: `gcloud storage cp startup.sh <BUCKET>/startup.sh`.)

---

## 6. Teardown

```bash
# Source your .env first so the variables below are populated.
gcloud workstations delete "$WORKSTATION" --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud workstations configs delete "$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud storage rm "$BUCKET/startup.sh"

# Optional — remove what bootstrap.sh created (only if nothing else uses them):
gcloud workstations clusters delete "$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute routers delete "$ROUTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute networks subnets delete "$SUBNET" --region="$REGION" --project="$PROJECT_ID"
gcloud compute networks delete "$NETWORK" --project="$PROJECT_ID"
```

---

## 7. For an agent (Claude Code CLI / `agy`)

To deploy via an agent, give it the project and region explicitly, e.g.:

> Read `DEPLOY.md`. Deploy a workstation to project `<PROJECT_ID>`, region `<REGION>`. Create `.env` from
> `.env.example` (use a globally-unique bucket), then run `bootstrap.sh` and `deploy.sh`. Report the
> workstation host URL and confirm `claude` and `agy` are installed.

The agent must still be authenticated (`gcloud auth login`) with the IAM roles in §1, on a billing-enabled
project.
