# Workstation Init — Cloud Workstation with Claude Code + Antigravity preinstalled

> **Disclaimer:** This code is provided "as-is" as a demonstration only to illustrate a potential
> solution. The code does not constitute a Google product or service of any kind, and Google offers no
> support, warranties, or liability of any kind with its regard. Whoever chooses to use this code
> accepts all responsibility related to it, including for its implementation, use, and ongoing
> maintenance. For the avoidance of doubt, this code is not eligible for the Google Open Source Software
> Vulnerability Rewards Program.

Deploy a [Google Cloud Workstation](https://cloud.google.com/workstations) whose **default
workstation ships with two tools already installed**:

- **Claude Code CLI** (`claude`)
- **Antigravity CLI** (`agy`)

It uses the predefined `code-oss` workstation image plus a **GCS-hosted startup script** — no custom
container image to build or maintain. Everything is parameterized through a `.env` file, so any
developer can clone this repo, set a handful of values, and deploy.

---

## What is an ABD (Agentic Base Deployment)?

An **Agentic Base Deployment** is a standard, ready-made environment where AI coding agents can start
working right away, with no manual setup first. In this repo:

- **Base:** every developer gets the same Cloud Workstation, with the same network, machine size, disk
  and timeouts, all set in one `.env` file.
- **Agentic:** the agent tools (Claude Code and Antigravity) come preinstalled and are kept on the
  persistent disk, so they survive restarts.
- **Deployment:** the whole setup is repeatable from scripts. An agent can even deploy it by following
  [`DEPLOY.md`](./DEPLOY.md).

In short, the ABD is the foundation each team member deploys once and then builds their agentic projects
on.

---

## How it works

Cloud Workstations can run a startup script on the VM by pointing a config at a script stored in
Cloud Storage:

```
--startup-script-uri=gs://<bucket>/startup.sh
```

The script ([`startup.sh`](./startup.sh)) executes **as root on each boot**. It installs the `claude` and `agy` CLIs **as the workstation user**
into `/home/<user>`, which lives on the **persistent disk** — so they survive restarts. `command -v`
guards make re-runs no-ops.

```
deploy.sh ──uploads──> gs://bucket/startup.sh  (+ grants the VM service account read access)
   │
   └──creates──> workstation config (codeoss image + --startup-script-uri)
                     │
                     └──> workstation VM boots ──runs──> startup.sh ──> claude + agy ready
```

Three requirements that are easy to miss — all handled for you:

- **Egress.** The workstation VM has **no public IP** by default, so its `curl` downloads need a
  **Cloud NAT** to reach the internet. `bootstrap.sh` creates a Cloud Router + Cloud NAT for this.
- **Bucket read.** The VM's service account must be able to read the startup script from GCS, so
  `deploy.sh` grants it `roles/storage.objectViewer` on the bucket.
- **`actAs` to launch.** `deploy.sh` pins a **normal** VM service account (the default Compute SA unless
  you set `SERVICE_ACCOUNT`) and grants the Cloud Workstations service agent
  (`service-<num>@gcp-sa-workstations.iam.gserviceaccount.com`) `roles/iam.serviceAccountUser` on it.
  Without this you get `PERMISSION_DENIED` on `Workstations.GenerateAccessToken` when clicking **Launch**.
  Leaving the SA unset would fall back to the Google-managed VM service agent, which **no one can
  `actAs`** — so the config must always name a real SA.

---

## Prerequisites

- An authenticated `gcloud` CLI: `gcloud auth login`, with a project set (`gcloud config set project <id>`).
- Operator IAM roles on the project. For a test, `roles/owner` covers everything; the granular set is:
  - `roles/serviceusage.serviceUsageAdmin` — enable APIs
  - `roles/compute.networkAdmin` — VPC, subnet, Cloud Router, Cloud NAT
  - `roles/workstations.admin` — cluster, config, workstation
  - `roles/storage.admin` — create the bucket and grant the VM SA read access
  - `roles/iam.serviceAccountAdmin` — bind the Workstations service agent's `actAs` on the VM SA
- The required APIs are enabled automatically by `bootstrap.sh`:
  `workstations.googleapis.com`, `compute.googleapis.com`, `storage.googleapis.com`.

Starting from a **clean project**? Run `bootstrap.sh` first — it creates the network and cluster. If you
already have a Workstations cluster, skip straight to `deploy.sh`.

---

## Quick start

```bash
git clone https://github.com/vovax-googler/WorkstationInit----.git WorkstationInit
cd WorkstationInit
cp .env.example .env        # then edit .env with your project values

# Clean project only: create APIs + VPC/subnet/NAT + cluster (~15-20 min).
bash bootstrap.sh --dry-run # review first
bash bootstrap.sh

# Then deploy the config + workstation (with tools preinstalled).
bash deploy.sh --dry-run    # review the gcloud commands first
bash deploy.sh              # upload startup.sh, grant SA read, create config + workstation
```

Open the workstation from the
[Workstations console](https://console.cloud.google.com/workstations) and verify in its terminal:

```bash
claude --version
agy --version
```

---

## Configuration (`.env`)

| Variable          | Description                                                        | Example                              |
| ----------------- | ------------------------------------------------------------------ | ------------------------------------ |
| `PROJECT_ID`      | GCP project ID                                                     | `my-gcp-project`                     |
| `REGION`          | Region of the Workstations cluster                                 | `europe-west3`                       |
| `CLUSTER`         | Existing cluster name                                              | `cluster-workstations`               |
| `CONFIG`          | Workstation config to create                                       | `ws-ai-default`                      |
| `WORKSTATION`     | Workstation instance to create                                     | `ws-default`                         |
| `BUCKET`          | GCS bucket hosting `startup.sh` (auto-created if missing)          | `gs://my-ws-startup`                 |
| `MACHINE_TYPE`    | Compute Engine machine type                                        | `e2-standard-4`                      |
| `BOOT_DISK_GB`    | Boot disk size (GB)                                                | `50`                                 |
| `PD_DISK_GB`      | Persistent home disk size (GB)                                     | `50`                                 |
| `PD_DISK_TYPE`    | Persistent disk type                                               | `pd-ssd`                             |
| `POOL_SIZE`       | Warm instances for fast startup (`0` to disable)                   | `1`                                  |
| `IDLE_TIMEOUT`    | Seconds idle before auto-stop                                      | `7200`                               |
| `RUNNING_TIMEOUT` | Max run time (seconds)                                             | `43200`                              |
| `REPLICA_ZONES`   | HA zones for the persistent disk (comma-separated)                 | `europe-west3-a,europe-west3-b`      |
| `SERVICE_ACCOUNT` | VM service account (blank = default Compute SA)                    | *(blank)*                            |
| `WS_USER`         | User inside the code-oss image (its home is the persistent disk)   | `user`                               |
| `NETWORK`         | VPC network (created by `bootstrap.sh`)                            | `ws-network`                         |
| `SUBNET`          | Subnet name (Private Google Access enabled)                        | `ws-subnet`                          |
| `SUBNET_RANGE`    | Subnet CIDR                                                        | `10.10.0.0/24`                       |
| `ROUTER`          | Cloud Router name (for Cloud NAT)                                  | `ws-router`                          |
| `NAT`             | Cloud NAT name (egress for the private VM)                         | `ws-nat`                             |
| `DISABLE_PUBLIC_IP` | Keep the VM off the public internet (recommended)               | `true`                               |

---

## Reference example (known-good config)

These are the settings of a working deployment, useful as a baseline:

- **Cluster:** `cluster-workstations` in `europe-west3` (private cluster, HTTP/2 gateway enabled).
- **Image:** `code-oss:latest` (predefined Cloud Workstations image).
- **VM:** `e2-standard-4`, 50 GB boot disk, pool size 1, Shielded VM (Secure Boot + vTPM + integrity
  monitoring), no public IP, SSH-to-VM disabled.
- **Persistent home:** `pd-ssd` 50 GB mounted at `/home`, reclaim policy `DELETE`.
- **Zones:** `europe-west3-a`, `europe-west3-b`.
- **Timeouts:** idle `7200s`, running `43200s`.
- **Allowed ports:** `22`, `80`, `1024–65535`.
- **Service account:** default Compute SA, scope `cloud-platform`.

---

## Clean project setup (`bootstrap.sh`)

On a brand-new project there is no network or cluster yet. `bootstrap.sh` provisions everything,
idempotently (safe to re-run):

1. **Enables APIs** — workstations, compute, storage.
2. **VPC + subnet** — a custom-mode network and a subnet with **Private Google Access** (so the VM can
   reach Google APIs and pull the container image without a public IP).
3. **Cloud Router + Cloud NAT** — outbound internet for the private VM. This is what lets `startup.sh`
   run `curl` to install Claude Code and Antigravity. **Without NAT the installs fail.**
4. **Workstations cluster** — created in your region (~15–20 minutes).

```bash
bash bootstrap.sh --dry-run   # review
bash bootstrap.sh
```

If you prefer your own existing VPC/cluster, skip `bootstrap.sh`, set `CLUSTER` (and a reachable
network) in `.env`, and ensure a Cloud NAT exists for the subnet when `DISABLE_PUBLIC_IP=true`.

---

## Verify persistence

Stop and start the workstation, then re-run the version checks — `claude` and `agy` should still
resolve (they live on the persistent `/home` disk).

```bash
gcloud workstations stop  "$WORKSTATION" --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud workstations start "$WORKSTATION" --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
```

---

## Teardown

```bash
gcloud workstations delete "$WORKSTATION" --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud workstations configs delete "$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
# Optionally remove the uploaded script:
gcloud storage rm "$BUCKET/startup.sh"
```

To also remove what `bootstrap.sh` created (only if nothing else uses them):

```bash
gcloud workstations clusters delete "$CLUSTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute routers delete "$ROUTER" --region="$REGION" --project="$PROJECT_ID"
gcloud compute networks subnets delete "$SUBNET" --region="$REGION" --project="$PROJECT_ID"
gcloud compute networks delete "$NETWORK" --project="$PROJECT_ID"
```

---

## Files

| File             | Purpose                                                            |
| ---------------- | ----------------------------------------------------------------- |
| `README.md`      | This guide                                                         |
| `DEPLOY.md`      | Full step-by-step deployment runbook + required info              |
| `.env.example`   | Template for project-specific variables (copy to `.env`)          |
| `bootstrap.sh`   | Clean-project setup: APIs + VPC/subnet/NAT + cluster              |
| `startup.sh`     | Startup script that installs Claude Code + Antigravity             |
| `deploy.sh`      | Uploads `startup.sh`, grants SA read, creates config + workstation |
