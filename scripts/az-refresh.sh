#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Re-log the az CLI in from a FRESH GitHub OIDC token. CI only; locally a no-op.
#
#     bash scripts/az-refresh.sh
#
# ── Why the session azure/login made does not last a long run ────────────────
# azure/login@v2 logs az in with `--federated-token`: a GitHub OIDC assertion
# that lives for minutes, not hours. az keeps the ARM access token it minted at
# login (good for an hour), so ARM calls keep working. But a token for a
# DIFFERENT resource has to be minted later from that same assertion, and once
# the assertion has expired Entra refuses it (AADSTS700024).
#
# Two resources are first asked for long after login:
#
#   kubelogin   `--login azurecli` asks az for a token for the AKS server app
#               the first time Terraform touches a namespace — AFTER the
#               platform apply. Run 37399746578 (2026-10-06): the platform took
#               ~10 min, kubelogin ran 10m46s after login and exited 1.
#   Key Vault   seed-vault.sh asks for a vault.azure.net token after both
#               applies.
#
# The azurerm provider and the backend are unaffected: ARM_USE_OIDC makes them
# request a fresh assertion from GitHub themselves, every time. This does the
# same thing for az.
#
# ── The token is never printed ───────────────────────────────────────────────
# It is registered with ::add-mask:: before it is used anywhere, nothing here
# runs under `set -x`, and az's own output is discarded. It does appear in
# az's argv for the duration of the login — exactly as azure/login puts it
# there — on a runner that is torn down with the job.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Not GitHub Actions, or a job without `id-token: write`: the caller's own az
# login is the session, and there is nothing to refresh it from.
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  exit 0
fi

# The step's identity, from the same ARM_* the azurerm provider reads — so the
# refreshed az session is the identity Terraform is, never a different one.
for required in ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID; do
  if [ -z "${!required:-}" ]; then
    echo "::error::az-refresh: ${required} is not set. Pass it in the step's env: block." >&2
    exit 1
  fi
done

# `audience` is the value Entra's federated credentials are configured for —
# the same one azure/login requests.
response="$(curl -sSf --retry 3 --max-time 30 \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")" || {
  echo "::error::az-refresh: GitHub refused an OIDC token. Does the job grant 'id-token: write'?" >&2
  exit 1
}
token="$(jq -r '.value // empty' <<< "${response}")"
unset response
if [ -z "${token}" ]; then
  echo "::error::az-refresh: the OIDC response carried no token." >&2
  exit 1
fi
echo "::add-mask::${token}"

az login --service-principal \
  --username "${ARM_CLIENT_ID}" \
  --tenant "${ARM_TENANT_ID}" \
  --federated-token "${token}" \
  --allow-no-subscriptions -o none
unset token
az account set --subscription "${ARM_SUBSCRIPTION_ID}"

echo "az session refreshed from a new GitHub OIDC token"
