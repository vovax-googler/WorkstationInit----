#!/usr/bin/env bash
#
# One-time, per-project setup for a CLEAN Google Cloud project.
#
# Idempotent: every step tolerates "already exists", so it is safe to re-run.
# Run this BEFORE deploy.sh:
#
#   cp .env.example .env      # then edit .env
#   bash bootstrap.sh         # enable APIs, create VPC/subnet/NAT + cluster
#   bash bootstrap.sh --dry-run
#
# It provisions everything a fresh project lacks:
#   1. Enables the required APIs.
#   2. Creates a custom-mode VPC + a subnet with Private Google Access.
#   3. Creates a Cloud Router + Cloud NAT so the private (no-public-IP)
#      workstation VM has outbound internet for apt/curl in startup.sh.
#   4. Creates the Workstations cluster (~15-20 min).
#
# Operator needs (for the test, Owner covers all of these):
#   roles/serviceusage.serviceUsageAdmin, roles/compute.networkAdmin,
#   roles/workstations.admin

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run: cp .env.example .env  (then edit it)" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${PROJECT_ID:?set PROJECT_ID in .env}"
: "${REGION:?set REGION in .env}"
: "${CLUSTER:?set CLUSTER in .env}"
NETWORK="${NETWORK:-ws-network}"
SUBNET="${SUBNET:-ws-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/24}"
ROUTER="${ROUTER:-ws-router}"
NAT="${NAT:-ws-nat}"

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

echo "=== Bootstrapping project '$PROJECT_ID' in '$REGION' ==="
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no changes will be made)"

# --- 1) Enable APIs ----------------------------------------------------------
run gcloud services enable \
  workstations.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID"

# Provision the Cloud Workstations service agent so deploy.sh can grant it
# actAs on the VM service account (required to launch workstations).
run gcloud beta services identity create \
  --service=workstations.googleapis.com --project="$PROJECT_ID" || true

# --- 2) VPC network + subnet (Private Google Access) -------------------------
run gcloud compute networks create "$NETWORK" \
  --project="$PROJECT_ID" --subnet-mode=custom || true

run gcloud compute networks subnets create "$SUBNET" \
  --project="$PROJECT_ID" --region="$REGION" \
  --network="$NETWORK" --range="$SUBNET_RANGE" \
  --enable-private-ip-google-access || true

# --- 3) Cloud Router + Cloud NAT (egress for no-public-IP VMs) ---------------
# Without this, startup.sh's curl downloads fail on a private workstation.
run gcloud compute routers create "$ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" --network="$NETWORK" || true

run gcloud compute routers nats create "$NAT" \
  --project="$PROJECT_ID" --region="$REGION" --router="$ROUTER" \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges || true

# --- 4) Workstations cluster (long-running, ~15-20 min) ----------------------
run gcloud workstations clusters create "$CLUSTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --network="projects/$PROJECT_ID/global/networks/$NETWORK" \
  --subnetwork="projects/$PROJECT_ID/regions/$REGION/subnetworks/$SUBNET" || true

echo
echo "Bootstrap complete. Next: bash deploy.sh"
