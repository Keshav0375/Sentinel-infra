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

# az on Windows emits CRLF. `$(...)` strips the trailing newline but NOT the \r,
# so every captured value silently carries a trailing carriage return — which
# breaks comparison against clean literals and corrupts any id passed onward.
# Always capture through this.
azq() { az "$@" -o tsv 2>/dev/null | tr -d '\r'; }

command -v az >/dev/null 2>&1 || die "az CLI not found on PATH."

step "Checking Azure login"
if ! SUB_ID=$(azq account show --query id 2>/dev/null); then
  die "Not logged in. Run: az login"
fi
SUB_NAME=$(azq account show --query name)
log "subscription: $SUB_NAME ($SUB_ID)"
log "region:       $LOCATION"

# Sentinel spans TWO tenants (school = resources, personal = the backend-API app
# registrations, §4.4). `az` keeps ONE shared context in ~/.azure, so logging
# into the identity tenant in any other terminal silently repoints this one.
EXPECTED_SUB="${EXPECTED_SUB:-174e25ca-ab82-4671-a913-9c2f66e5924d}"
if [ "$SUB_ID" != "$EXPECTED_SUB" ]; then
  die "Wrong subscription context.
    expected: $EXPECTED_SUB  (Azure for Students, school tenant)
    actual:   $SUB_ID
    Fix with: az account set --subscription $EXPECTED_SUB
    Override deliberately with: EXPECTED_SUB=<id> $0"
fi

# ── Resource group ───────────────────────────────────────────────────────────
# Deliberately NOT sentinel-rg. State lives in its own group so that
# The teardown's (§7.3) `terraform destroy` + `az group delete` on sentinel-rg
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
  if [ "$(azq storage account check-name --name "$STATE_SA" --query nameAvailable)" = "false" ]; then
    # check-name is GLOBAL: it also returns false for accounts in THIS subscription.
    # Distinguish before accusing another tenant — the remediation differs completely.
    MINE_IN_RG=$(azq storage account list --query "[?name=='$STATE_SA'].resourceGroup")
    if [ -n "$MINE_IN_RG" ]; then
      die "Storage account '$STATE_SA' already exists in YOUR subscription, but in
    resource group '$MINE_IN_RG' rather than '$STATE_RG'.
    Do NOT rename anything. Either re-run with STATE_RG=$MINE_IN_RG, or delete the
    stray account if it was a mistake."
    fi
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

SA_ID=$(azq storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id)

# ── Data-plane RBAC ──────────────────────────────────────────────────────────
# backend.tf sets use_azuread_auth, so Terraform reaches the state blob with an
# Entra token rather than a storage access key. Owner on the subscription is a
# CONTROL-plane role and grants no blob access whatsoever — without this
# assignment `terraform init` fails with a 403 that reads like a broken backend.
step "Granting the operator blob data access"
PRINCIPAL_TYPE="${OPERATOR_PRINCIPAL_TYPE:-User}"
if [ -n "${OPERATOR_OBJECT_ID:-}" ]; then
  OPERATOR_ID="$OPERATOR_OBJECT_ID"
elif OPERATOR_ID=$(azq ad signed-in-user show --query id 2>/dev/null); then
  PRINCIPAL_TYPE=User
else
  # Reached only when Graph is unavailable to this principal — which is precisely
  # why a fallback making MORE Graph calls (az ad sp show) cannot work. Ask instead
  # of dying with no remediation.
  die "Could not resolve the current principal's object id via Microsoft Graph.
    Expected when running as a service principal in a tenant that restricts
    directory reads. Supply it explicitly:
      OPERATOR_OBJECT_ID=<object-id> OPERATOR_PRINCIPAL_TYPE=ServicePrincipal $0"
fi
log "principal: $OPERATOR_ID ($PRINCIPAL_TYPE)"

# `create` uses --assignee-object-id + --assignee-principal-type, which skip the
# Microsoft Graph lookup plain --assignee performs. `list` has no such flag, so it
# filters locally instead — same reason: this design must not depend on Graph.
EXISTING_ROLE=$(az role assignment list --scope "$SA_ID" \
  --query "[?principalId=='$OPERATOR_ID' && roleDefinitionName=='Storage Blob Data Contributor'].id | [0]" \
  -o tsv 2>/dev/null || true)
if [ -n "$EXISTING_ROLE" ] && [ "$EXISTING_ROLE" != "None" ]; then
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
    if OUT=$(az storage container create --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
               --auth-mode login --output none 2>&1); then
      log "created"
      break
    fi
    # if/then/fi, not `[ ] && die` — the latter is only safe under `set -e` because
    # other statements follow it in the loop body, and a later reordering would
    # silently disarm it.
    if [ "$attempt" -eq 8 ]; then
      # Never assert "probably propagation" while hiding the response. If the real
      # cause is AuthorizationPermissionMismatch, re-running can never succeed and
      # the operator needs to see that rather than waiting two more minutes.
      die "Container creation still failing after ~2 min. Last error from az:

$OUT"
    fi
    log "retrying, likely RBAC propagation ($attempt/8)..."
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

Next: terraform init   (configures the real backend against this container)
EOF
