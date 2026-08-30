#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Put the runtime secrets into a freshly created Key Vault.
#
#     bash scripts/seed-vault.sh --vault kv-sentinel-dev-1a2b
#     bash scripts/seed-vault.sh --vault kv-sentinel-dev-1a2b --dry-run
#
# Values arrive as environment variables (GitHub environment secrets in CI, a
# sourced .env locally). A blank one is skipped, not an error.
#
# ── Terraform still writes no secret, and that invariant is intact ───────────
# The vault is created EMPTY by Terraform because a secret in state is a secret
# in a storage account, readable by anything with state access (docs/BOOTSTRAP.md
# step 8). This runs AFTER the apply, from the runner, over the data plane. The
# secret never enters a plan, a state file, or a log.
#
# ── Why this needs a role Contributor does not include ───────────────────────
# Azure separates control plane from data plane. `Contributor` can create a Key
# Vault and cannot put a secret in one. The deploy identity gets
# `Key Vault Secrets Officer` from modules/keyvault (seeder_principal_id);
# without it every write here 403s.
#
# ── Idempotent on purpose ────────────────────────────────────────────────────
# `az keyvault secret set` always creates a NEW VERSION. Running it on every
# apply would churn versions and, worse, keep resetting the expiry clock that
# the rotation Function watches — so a secret would never appear near-expiry and
# rotation would never fire. This writes only when the secret is absent or is
# within RENEW_WITHIN_DAYS of expiring.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT=""
DRY_RUN=0
EXPIRY_DAYS=90
RENEW_WITHIN_DAYS=30

# Environment variable -> Key Vault secret name. The mapping is mechanical
# (lowercase, underscores to hyphens) because Key Vault permits only
# alphanumerics and hyphens; deriving it beats maintaining a table that drifts.
SECRETS=(
  DATADOG_API_KEY
  DATADOG_APP_KEY
  LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY
  LANGFUSE_BASE_URL
  TEAMS_WEBHOOK_URL
)

# Deliberately absent: ANTHROPIC_API_KEY and OPENAI_API_KEY. Both vendors support
# workload identity federation, so the backend pod authenticates with its
# projected service-account token and there is no key to store. See
# architecture/decisions.md 2026-08-30 in sentinel-brain. Built in backend
# phase 7 — infra has no pod to federate from yet.

while [ $# -gt 0 ]; do
  case "$1" in
    --vault)   VAULT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --expiry-days) EXPIRY_DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "${VAULT}" ]; then
  echo "error: --vault is required." >&2
  exit 2
fi

# A deployment without the keyvault component has no vault, and that is a valid
# configuration rather than a failure.
if ! az keyvault show --name "${VAULT}" -o none 2>/dev/null; then
  echo "vault ${VAULT} does not exist — nothing to seed"
  exit 0
fi

echo "seeding ${VAULT}"
if [ "${DRY_RUN}" -eq 1 ]; then echo "DRY RUN — nothing will be written"; fi
echo

expires_on="$(date -u -d "+${EXPIRY_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')"
renew_before="$(date -u -d "+${RENEW_WITHIN_DAYS} days" '+%s')"

set_count=0
skip_missing=0
skip_current=0
missing_names=()

for env_name in "${SECRETS[@]}"; do
  secret_name="$(printf '%s' "${env_name}" | tr '[:upper:]_' '[:lower:]-')"
  value="${!env_name:-}"

  if [ -z "${value}" ]; then
    skip_missing=$(( skip_missing + 1 ))
    missing_names+=("${env_name} -> ${secret_name}")
    continue
  fi

  # Never let a value reach a log, including through `set -x` or a later failure
  # dump. GitHub redacts a registered mask everywhere in the run.
  echo "::add-mask::${value}"

  # Read the CURRENT expiry, if the secret exists at all. `|| true` because a
  # missing secret is the normal first-apply case and must not trip `set -e`.
  current_expiry="$(az keyvault secret show --vault-name "${VAULT}" --name "${secret_name}" \
                      --query "attributes.expires" -o tsv 2>/dev/null || true)"

  if [ -n "${current_expiry}" ] && [ "${current_expiry}" != "None" ]; then
    current_epoch="$(date -u -d "${current_expiry}" '+%s' 2>/dev/null || echo 0)"
    if [ "${current_epoch}" -gt "${renew_before}" ]; then
      echo "  current   ${secret_name}  (expires ${current_expiry%%T*})"
      skip_current=$(( skip_current + 1 ))
      continue
    fi
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  would set ${secret_name}"
    set_count=$(( set_count + 1 ))
    continue
  fi

  # --value takes the secret on the command line, where it is visible in the
  # process table for the life of the call. There is no stdin form, so the
  # exposure is accepted: an ephemeral CI runner the workflow already trusts
  # with subscription Contributor.
  #
  # An expiry is mandatory, not decorative: the rotation Function subscribes to
  # SecretNearExpiry, and a secret with no expiry never raises that event and so
  # is never rotated.
  if az keyvault secret set \
       --vault-name "${VAULT}" \
       --name "${secret_name}" \
       --value "${value}" \
       --expires "${expires_on}" \
       -o none 2>/dev/null; then
    echo "  set       ${secret_name}  (expires ${expires_on%%T*})"
    set_count=$(( set_count + 1 ))
  else
    echo "::error::failed to write ${secret_name} to ${VAULT}." >&2
    echo "::error::The usual cause is data-plane access: Contributor can create a vault" >&2
    echo "::error::but not write to it. Check that kv_seeder_object_id was passed to the" >&2
    echo "::error::apply so modules/keyvault granted Key Vault Secrets Officer." >&2
    exit 1
  fi
done

echo
echo "written: ${set_count}   already current: ${skip_current}   not supplied: ${skip_missing}"

if [ "${skip_missing}" -gt 0 ]; then
  echo
  echo "Not supplied — the vault comes up without these, which is a VALID state:"
  for name in "${missing_names[@]}"; do echo "  - ${name}"; done
  echo
  echo "A Key Vault reference to a missing secret resolves to the literal"
  echo "@Microsoft.KeyVault(...) string, which the handlers detect and log rather"
  echo "than crash on. Add the value as a GitHub environment secret on"
  echo "'production' and re-run apply; this step adds what is newly available and"
  echo "leaves everything else alone."
fi
