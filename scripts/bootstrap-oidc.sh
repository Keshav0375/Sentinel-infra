#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time bootstrap: the CI identity (architecture/infra.md §4.3).
#
# The second chicken-and-egg. GitHub Actions authenticates to Azure via OIDC to
# run Terraform — but the identity and federated credential that make OIDC work
# cannot be created by that pipeline, because it has no identity yet.
#
# This creates the minimum by hand, then prints the `terraform import` commands
# that hand all five objects to Terraform. Everything after that is codified.
#
# NOTE: the identity is a USER-ASSIGNED MANAGED IDENTITY, not an app
# registration. The subscription lives in the uwindsor.ca tenant where
# `allowedToCreateApps` is false at tenant policy. A UAMI is a plain Azure
# resource under RBAC and carries federated credentials identically.
#
# Idempotent. Re-running it is a no-op.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Git Bash rewrites /subscriptions/... into a Windows path, corrupting --scope.
export MSYS_NO_PATHCONV=1

RG="${RG:-sentinel-rg}"
STATE_RG="${STATE_RG:-sentinel-state-rg}"
STATE_SA="${STATE_SA:-sentineltfstate0375}"
UAMI="${UAMI:-sentinel-gha}"
LOCATION="${LOCATION:-canadacentral}"
OWNER="${OWNER:-Keshav0375}"   # case-sensitive — Azure matches OIDC subjects exactly

log()  { printf '  %s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
die()  { printf '\n✖ %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null 2>&1 || die "az CLI not found on PATH."

step "Checking Azure login"
SUB_ID=$(az account show --query id -o tsv 2>/dev/null) || die "Not logged in. Run: az login"
log "subscription: $(az account show --query name -o tsv) ($SUB_ID)"

# Sentinel spans TWO tenants (school = resources, personal = the backend-API app
# registrations, §4.4). `az` keeps ONE shared context in ~/.azure, so logging
# into the identity tenant in any other terminal silently repoints this one.
# Creating sentinel-gha in the wrong tenant would half-work and be confusing to
# unpick, so assert rather than trust.
EXPECTED_SUB="${EXPECTED_SUB:-174e25ca-ab82-4671-a913-9c2f66e5924d}"
if [ "$SUB_ID" != "$EXPECTED_SUB" ]; then
  die "Wrong subscription context.
    expected: $EXPECTED_SUB  (Azure for Students, school tenant)
    actual:   $SUB_ID
    Fix with: az account set --subscription $EXPECTED_SUB
    Override deliberately with: EXPECTED_SUB=<id> $0"
fi

az group show --name "$RG" --output none 2>/dev/null \
  || die "Resource group '$RG' not found. Run docs/BOOTSTRAP.md step 1 first."
az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --output none 2>/dev/null \
  || die "State storage '$STATE_SA' not found. Run scripts/bootstrap-state.sh first."

# ── The identity ─────────────────────────────────────────────────────────────
step "Managed identity: $UAMI"
if az identity show --name "$UAMI" --resource-group "$RG" --output none 2>/dev/null; then
  log "already exists — skipping"
else
  az identity create --name "$UAMI" --resource-group "$RG" --location "$LOCATION" --output none
  log "created"
fi

CLIENT_ID=$(az identity show --name "$UAMI" --resource-group "$RG" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name "$UAMI" --resource-group "$RG" --query principalId -o tsv)
# Built by hand, NOT from `az identity show --query id`. az returns the id with
# "resourcegroups" in lowercase, and the azurerm provider's ID parser is
# case-sensitive: importing with the az-returned value fails with "the segment at
# position 0 didn't match", which points nowhere near the real cause.
UAMI_ID="/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$UAMI"
log "clientId:    $CLIENT_ID"
log "principalId: $PRINCIPAL_ID"

# ── Role assignments ─────────────────────────────────────────────────────────
# --assignee-object-id + --assignee-principal-type skip the Microsoft Graph
# lookup that plain --assignee performs. In this tenant directory reads are
# permitted but writes are not; using the explicit form removes the dependency
# on Graph entirely and is what makes this work under tenant policy.
#
# A freshly created UAMI's service principal replicates asynchronously, so the
# first assignment can fail with PrincipalNotFound. Retry rather than fail.
assign_role() {
  local role="$1" scope="$2" label="$3"
  if az role assignment list --assignee "$PRINCIPAL_ID" --scope "$scope" \
       --role "$role" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    log "$label — already assigned, skipping"
    return 0
  fi
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
         --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" --output none 2>/dev/null; then
      log "$label — assigned"
      return 0
    fi
    [ "$attempt" -eq 6 ] && die "Could not assign '$role'. Usually Entra replication; re-run."
    log "$label — waiting for principal replication ($attempt/6)..."
    sleep 10
  done
}

step "Role assignments"
assign_role "Contributor" "/subscriptions/$SUB_ID/resourceGroups/$RG" "Contributor on $RG"
# State lives outside the Contributor scope above, and backend.tf reaches the
# blob with an Entra token — control-plane rights grant no data-plane access.
assign_role "Storage Blob Data Contributor" \
  "/subscriptions/$SUB_ID/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA" \
  "Storage Blob Data Contributor on $STATE_SA"

# ── Federated credentials ────────────────────────────────────────────────────
# Only the two Sentinel-infra credentials are created here — just enough for
# ci_infra_dry.yml (PR) and ci_infra.yml (main) to authenticate. Terraform
# creates the remaining three once it can run.
add_fedcred() {
  local name="$1" subject="$2"
  if az identity federated-credential show --name "$name" --identity-name "$UAMI" \
       --resource-group "$RG" --output none 2>/dev/null; then
    log "$name — already exists, skipping"
    return 0
  fi
  az identity federated-credential create --name "$name" \
    --identity-name "$UAMI" --resource-group "$RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$subject" \
    --audiences "api://AzureADTokenExchange" --output none
  log "$name — created"
}

step "Federated credentials (bootstrap pair)"
add_fedcred "sentinel-infra-main" "repo:$OWNER/Sentinel-infra:ref:refs/heads/main"
add_fedcred "sentinel-infra-pr"   "repo:$OWNER/Sentinel-infra:pull_request"

# ── Import commands ──────────────────────────────────────────────────────────
# All five, not just the identity. Importing only the UAMI leaves four objects
# to collide on the first apply. Managed-identity resources import by Azure
# resource ID, which is derivable — one practical advantage over app
# registrations, whose import id is an opaque directory object id.
CONTRIB_ID=$(az role assignment list --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" --role Contributor \
  --query "[0].id" -o tsv)
BLOB_ID=$(az role assignment list --assignee "$PRINCIPAL_ID" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA" \
  --role "Storage Blob Data Contributor" --query "[0].id" -o tsv)

cat <<EOF

✔ Bootstrap complete. Now import all five objects.

  ⚠ Run these in PowerShell, or export MSYS_NO_PATHCONV=1 first in Git Bash.
    MSYS rewrites /subscriptions/... into C:/Program Files/Git/subscriptions/...
    for ANY command, terraform included — not just az.

terraform import azurerm_user_assigned_identity.sentinel_gha \\
  "$UAMI_ID"

terraform import azurerm_federated_identity_credential.sentinel_infra_main \\
  "$UAMI_ID/federatedIdentityCredentials/sentinel-infra-main"

terraform import azurerm_federated_identity_credential.sentinel_infra_pr \\
  "$UAMI_ID/federatedIdentityCredentials/sentinel-infra-pr"

terraform import azurerm_role_assignment.gha_contributor \\
  "$CONTRIB_ID"

terraform import azurerm_role_assignment.gha_state_blob \\
  "$BLOB_ID"

Then: terraform plan
  Expect NO destroy and NO replace — only the 3 remaining federated credentials
  to add. Anything else means an attribute drifted between az and the HCL.

GitHub variable AZURE_CLIENT_ID = $CLIENT_ID
  (the clientId above, NOT the principalId)
EOF
