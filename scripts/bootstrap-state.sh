#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time bootstrap: Terraform remote state storage.
#
# Terraform stores its state in an Azure Storage container — but it cannot create
# that container, because to run at all it needs somewhere to put state. This
# script is the resolution to that circularity: a small, deliberate, documented
# manual seam at the trust root. Everything after it is codified.
#
# Idempotent by design. Re-running it is a no-op, so it is safe to use as a
# "is my state storage healthy?" check, not just a first-run script.
#
# See architecture/infra.md §8.1 and §10 steps 1-2 in the sentinel-brain repo.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Git Bash (MSYS2) rewrites anything that looks like a Unix path into a Windows
# path, which corrupts --scope /subscriptions/... into C:/Program Files/...
# This makes the script behave identically in Git Bash and in a POSIX shell.
export MSYS_NO_PATHCONV=1

STATE_RG="${STATE_RG:-sentinel-state-rg}"
STATE_SA="${STATE_SA:-sentineltfstate0375}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
LOCATION="${LOCATION:-canadacentral}"

log()  { printf '  %s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
die()  { printf '\n✖ %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1 || die "az CLI not found on PATH."

step "Checking Azure login"
if ! SUB_ID=$(az account show --query id -o tsv 2>/dev/null); then
  die "Not logged in. Run: az login"
fi
SUB_NAME=$(az account show --query name -o tsv)
log "subscription: $SUB_NAME ($SUB_ID)"
log "region:       $LOCATION"

# ── Resource group ───────────────────────────────────────────────────────────
# Deliberately NOT sentinel-rg. State lives in its own group so that
# ci_destroy_infra's `terraform destroy` + `az group delete` on sentinel-rg
# cannot delete the state describing what it is destroying.
step "Resource group: $STATE_RG"
if [ "$(az group exists --name "$STATE_RG")" = "true" ]; then
  log "already exists — skipping"
else
  az group create --name "$STATE_RG" --location "$LOCATION" --output none
  log "created"
fi

# ── Storage account ──────────────────────────────────────────────────────────
step "Storage account: $STATE_SA"
if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --output none 2>/dev/null; then
  log "already exists in $STATE_RG — skipping"
else
  # The name is global across all of Azure, so "taken" and "yours" are different
  # failures and must not be conflated.
  if [ "$(az storage account check-name --name "$STATE_SA" --query nameAvailable -o tsv)" = "false" ]; then
    die "Storage account name '$STATE_SA' is taken by another Azure tenant.
    Pick a new name and change it in ALL of these together, in one commit:
      - backend.tf                        (storage_account_name)
      - scripts/bootstrap-state.sh        (STATE_SA default)
      - oidc.tf                           (gha_state_blob role scope)
      - docs/BOOTSTRAP.md
      - sentinel-brain architecture/infra.md §8.1
    Or re-run with: STATE_SA=<newname> $0"
  fi
  az storage account create \
    --name "$STATE_SA" \
    --resource-group "$STATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --encryption-services blob \
    --min-tls-version TLS1_2 \
    --output none
  log "created"
fi

SA_ID=$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)

# ── Data-plane RBAC ──────────────────────────────────────────────────────────
# backend.tf sets use_azuread_auth, so Terraform reaches the state blob with an
# Entra token rather than a storage access key. Owner on the subscription is a
# CONTROL-plane role and grants no blob access whatsoever — without this
# assignment `terraform init` fails with a 403 that reads like a broken backend.
step "Granting the operator blob data access"
if OPERATOR_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null); then
  PRINCIPAL_TYPE=User
else
  # Running as a service principal (CI). Fall back to the logged-in SP.
  OPERATOR_ID=$(az account show --query user.name -o tsv)
  OPERATOR_ID=$(az ad sp show --id "$OPERATOR_ID" --query id -o tsv 2>/dev/null) \
    || die "Could not resolve the current principal's object id."
  PRINCIPAL_TYPE=ServicePrincipal
fi
log "principal: $OPERATOR_ID ($PRINCIPAL_TYPE)"

# --assignee-object-id + --assignee-principal-type skip the Microsoft Graph
# lookup that plain --assignee performs. In a tenant where directory reads are
# restricted, that lookup is what fails — not the assignment itself.
if az role assignment list --assignee "$OPERATOR_ID" --scope "$SA_ID" \
     --role "Storage Blob Data Contributor" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
  log "already assigned — skipping"
else
  az role assignment create \
    --assignee-object-id "$OPERATOR_ID" \
    --assignee-principal-type "$PRINCIPAL_TYPE" \
    --role "Storage Blob Data Contributor" \
    --scope "$SA_ID" \
    --output none
  log "assigned Storage Blob Data Contributor"
fi

# ── Container ────────────────────────────────────────────────────────────────
# --auth-mode login uses the Entra token, matching how Terraform will connect.
# Creating it with an access key instead would "work" while leaving the actual
# credential path untested until the first terraform init — so we test it here.
# RBAC propagation is eventually consistent and routinely takes 30-120s, hence
# the retry rather than a single attempt.
step "Container: $STATE_CONTAINER"
if az storage container show --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
     --auth-mode login --output none 2>/dev/null; then
  log "already exists — skipping"
else
  for attempt in 1 2 3 4 5 6 7 8; do
    if az storage container create --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
         --auth-mode login --output none 2>/dev/null; then
      log "created"
      break
    fi
    [ "$attempt" -eq 8 ] && die "Container creation still failing after ~2min.
    Almost always RBAC propagation. Wait a minute and re-run — this script is idempotent."
    log "waiting for RBAC propagation (attempt $attempt/8)..."
    sleep 15
  done
fi

# ── Report ───────────────────────────────────────────────────────────────────
cat <<EOF

✔ State storage ready. These must match backend.tf exactly:

    resource_group_name  = "$STATE_RG"
    storage_account_name = "$STATE_SA"
    container_name       = "$STATE_CONTAINER"
    key                  = "sentinel.terraform.tfstate"

Next: terraform init   (drops -backend=false — this is the real one)
EOF
