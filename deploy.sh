#!/usr/bin/env bash
#
# Deploy a Google Cloud Workstation config + workstation that comes with
# the Claude Code CLI and the Antigravity CLI preinstalled.
#
# Usage:
#   cp .env.example .env      # then edit .env
#   bash deploy.sh            # show the actions, then create them
#   bash deploy.sh --dry-run  # print the gcloud commands without running them
#
# Requires: an authenticated `gcloud` (run `gcloud auth login`) and an existing
# Workstations cluster (create one with bootstrap.sh -- see "Clean project setup" in README.md).

set -euo pipefail

# --- Parse args --------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Load configuration ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run: cp .env.example .env  (then edit it)" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# --- Validate required values ------------------------------------------------
: "${PROJECT_ID:?set PROJECT_ID in .env}"
: "${REGION:?set REGION in .env}"
: "${CLUSTER:?set CLUSTER in .env}"
: "${CONFIG:?set CONFIG in .env}"
: "${WORKSTATION:?set WORKSTATION in .env}"
: "${BUCKET:?set BUCKET in .env}"
WS_USER="${WS_USER:-user}"

# --- Helper: print + (optionally) run ---------------------------------------
run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

echo "=== Deploying Cloud Workstation config '$CONFIG' to cluster '$CLUSTER' ($REGION) ==="
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no changes will be made)"

# Resolve the workstation VM service account: explicit SERVICE_ACCOUNT, else the
# project's default Compute Engine SA (<projectNumber>-compute@developer...).
# We ALWAYS pin a normal SA. If you leave it unset, the config would default to
# the Google-managed VM service agent (service-...@gcp-sa-workstationsvm), which
# *nobody* can actAs — so launching the workstation fails with PERMISSION_DENIED
# on Workstations.GenerateAccessToken. A normal SA avoids that.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
WS_SA="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# The Cloud Workstations service agent runs/launches the VM as WS_SA, so it needs
# iam.serviceAccountUser (actAs) on WS_SA. Create the agent first if missing.
WS_AGENT="service-${PROJECT_NUMBER}@gcp-sa-workstations.iam.gserviceaccount.com"

# --- 1) Host the startup script in GCS ---------------------------------------
# Bucket creation is best-effort: ignore "already exists".
run gcloud storage buckets create "$BUCKET" \
  --project="$PROJECT_ID" --location="$REGION" || true
run gcloud storage cp "$SCRIPT_DIR/startup.sh" "$BUCKET/startup.sh"

# The workstation VM service account must be able to READ the startup script.
run gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$WS_SA" \
  --role=roles/storage.objectViewer

# --- 1b) Let the Workstations service agent actAs the VM service account ------
# Without this, launching the workstation fails on GenerateAccessToken.
gcloud beta services identity create --service=workstations.googleapis.com \
  --project="$PROJECT_ID" >/dev/null 2>&1 || true
run gcloud iam service-accounts add-iam-policy-binding "$WS_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$WS_AGENT" \
  --role=roles/iam.serviceAccountUser

# --- 2) Create the workstation config ----------------------------------------
CONFIG_ARGS=(
  "$CONFIG"
  --cluster="$CLUSTER"
  --region="$REGION"
  --project="$PROJECT_ID"
  --container-predefined-image=codeoss
  --machine-type="${MACHINE_TYPE:-e2-standard-4}"
  --boot-disk-size="${BOOT_DISK_GB:-50}"
  --pool-size="${POOL_SIZE:-0}"
  --pd-disk-type="${PD_DISK_TYPE:-pd-ssd}"
  --pd-disk-size="${PD_DISK_GB:-50}"
  --pd-reclaim-policy=delete
  --service-account-scopes=https://www.googleapis.com/auth/cloud-platform
  --shielded-secure-boot
  --shielded-vtpm
  --shielded-integrity-monitoring
  --replica-zones="${REPLICA_ZONES:-$REGION-a,$REGION-b}"
  --idle-timeout="${IDLE_TIMEOUT:-7200}"
  --running-timeout="${RUNNING_TIMEOUT:-43200}"
  --allowed-ports=first=22,last=22
  --allowed-ports=first=80,last=80
  --allowed-ports=first=1024,last=65535
  --startup-script-uri="$BUCKET/startup.sh"
  --service-account="$WS_SA"
)
# Note: SSH-to-VM is disabled by default (omit --enable-ssh-to-vm to keep it off).
# Keep the VM off the public internet unless explicitly disabled. When private,
# Cloud NAT (from bootstrap.sh) provides the egress startup.sh needs.
if [[ "${DISABLE_PUBLIC_IP:-true}" == "true" ]]; then
  CONFIG_ARGS+=( --disable-public-ip-addresses )
fi

run gcloud workstations configs create "${CONFIG_ARGS[@]}"

# --- 3) Create and start the workstation -------------------------------------
run gcloud workstations create "$WORKSTATION" \
  --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"

run gcloud workstations start "$WORKSTATION" \
  --config="$CONFIG" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT_ID"

echo
echo "Done. Open the workstation, then verify inside its terminal:"
echo "  claude --version && agy --version"
