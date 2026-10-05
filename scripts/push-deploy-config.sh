#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Push the app pipeline's configuration to Sentinel-deployment (R8).
#
#     bash scripts/push-deploy-config.sh --dry-run    # show what would be pushed
#     bash scripts/push-deploy-config.sh              # push
#     bash scripts/push-deploy-config.sh --env-file ../Sentinel/.env \
#          --deployment sentinel --environment dev --repo Keshav0375/Sentinel-deployment
#
# Target: the GitHub environment `sentinel-dev` on Sentinel-deployment, created
# here if missing. Fixed, not a flag: gha-app federates exactly the subject
# `repo:Keshav0375/Sentinel-deployment:environment:sentinel-dev`, so any other
# environment name would hold credentials no job can use.
#
#   secrets    AZURE_CLIENT_ID (gha-app), AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
#              DD_API_KEY
#   variables  AZURE_RG, APP_NAME, DEPLOYED_APP_URL, PG_HOST, PG_DATABASE,
#              PG_USER (= gha-app), DD_SITE
#
# ── Pushed once, not resolved per run ────────────────────────────────────────
# Every value is deterministic. gha-app lives in rg-sentinel-bootstrap, so its
# client ID survives a destroy/recreate of the deployment, and the deployment's
# names are uid = sha1(sub-dep-env)[0:4]. Re-run only when gha-app is rebuilt,
# the Datadog key rotates, or a different deployment becomes the target.
#
# A separate script from set-gh-secrets.sh, which mirrors a whole .env into
# Sentinel-infra's `production` environment. This one computes most of its
# values, writes variables as well as secrets, and reads one key from a file
# that belongs to another repo.
#
# ── Secret values never touch argv or output ─────────────────────────────────
# `gh secret set --body "$v"` puts the value in the process table; stdin keeps
# it in a pipe. A dry run reports a secret's length, never its value. Variables
# are not secret — GitHub shows them in every log — so they are printed.
#
# ── The .env is parsed, not sourced ──────────────────────────────────────────
# Same rules as set-gh-secrets.sh: split on the first `=`, strip a trailing CR
# and one matched pair of quotes, execute nothing.
#
# Requires: az (logged in to the subscription), gh (authenticated, admin on the
# target repo), and an initialised Terraform working directory for the outputs.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

export MSYS_NO_PATHCONV=1
CR="$(printf '\r')"
nocr() { tr -d "${CR}"; }

# Run from the repo root, so `terraform output` and the default ../Sentinel/.env
# resolve the same wherever this is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXPECTED_SUB="174e25ca-ab82-4671-a913-9c2f66e5924d"
BOOTSTRAP_RG="${BOOTSTRAP_RG:-rg-sentinel-bootstrap}"
GH_ENVIRONMENT="sentinel-dev"
APP_IDENTITY="gha-app"

REPO="Keshav0375/Sentinel-deployment"
DEPLOYMENT="sentinel"
ENVIRONMENT="dev"
ENV_FILE="../Sentinel/.env"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --repo)        REPO="$2"; shift 2 ;;
    --deployment)  DEPLOYMENT="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --env-file)    ENV_FILE="$2"; shift 2 ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Preconditions, each with the fix in the message ──────────────────────────
for tool in az terraform; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: ${tool} is not installed." >&2
    exit 1
  fi
done

if [ ! -f "${ENV_FILE}" ]; then
  echo "error: ${ENV_FILE} not found. Pass --env-file <path> to the .env holding DD_API_KEY." >&2
  exit 1
fi

# A dry run reads Azure and Terraform but writes nothing to GitHub, so it does
# not need gh; with gh it also reports whether the environment exists.
have_gh=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  have_gh=1
elif [ "${DRY_RUN}" -eq 0 ]; then
  echo "error: gh is missing or not authenticated. Run: gh auth login" >&2
  exit 1
fi

current_sub="$(az account show --query id -o tsv 2>/dev/null | nocr || true)"
if [ "${current_sub}" != "${EXPECTED_SUB}" ]; then
  echo "REFUSING: az context is subscription '${current_sub}', expected ${EXPECTED_SUB}" >&2
  echo "  az login && az account set --subscription ${EXPECTED_SUB}" >&2
  exit 1
fi

# ── Value sources ─────────────────────────────────────────────────────────────

# One key from a .env, by the parsing rules in the header. Prints nothing when
# the key is absent or blank.
env_get() {
  local file="$1" want="$2" line key value first last
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%"${CR}"}"
    case "${line}" in ''|\#*) continue ;; esac
    key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
    [ "${key}" = "${want}" ] || continue
    value="${line#*=}"
    first="${value%"${value#?}"}"
    last="${value#"${value%?}"}"
    if [ ${#value} -ge 2 ] && [ "${first}" = "${last}" ] \
       && { [ "${first}" = '"' ] || [ "${first}" = "'" ]; }; then
      value="${value#?}"
      value="${value%?}"
    fi
    printf '%s' "${value}"
    return
  done < "${file}"
}

# TF_WORKSPACE selects the workspace for this call only; .terraform/environment
# is left alone, so the checkout's next plan targets what it targeted before.
workspace="${DEPLOYMENT}-${ENVIRONMENT}"
tf_output() {
  TF_WORKSPACE="${workspace}" terraform output -raw "$1" 2>/dev/null | nocr || true
}

# Plain variables read by indirection rather than associative arrays: macOS
# ships bash 3.2, which has no `declare -A`.
# Read below through ${!v}, which shellcheck cannot follow.
# shellcheck disable=SC2034
{
  s_AZURE_CLIENT_ID="$(az identity show --name "${APP_IDENTITY}" --resource-group "${BOOTSTRAP_RG}" --query clientId -o tsv 2>/dev/null | nocr || true)"
  s_AZURE_TENANT_ID="$(az account show --query tenantId -o tsv | nocr)"
  s_AZURE_SUBSCRIPTION_ID="${current_sub}"
  s_DD_API_KEY="$(env_get "${ENV_FILE}" DD_API_KEY)"

  v_AZURE_RG="$(tf_output deployment_resource_group)"
  v_APP_NAME="$(tf_output app_name)"
  v_DEPLOYED_APP_URL="$(tf_output app_url)"
  v_PG_HOST="$(tf_output database_host)"
  v_PG_DATABASE="$(tf_output database_name)"
  v_PG_USER="${APP_IDENTITY}"
  dd_site="$(env_get "${ENV_FILE}" DD_SITE)"
  v_DD_SITE="${dd_site:-datadoghq.com}"
}

SECRET_ORDER=(AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID DD_API_KEY)
VAR_ORDER=(AZURE_RG APP_NAME DEPLOYED_APP_URL PG_HOST PG_DATABASE PG_USER DD_SITE)

# ── All or nothing ────────────────────────────────────────────────────────────
# A partial push produces a pipeline that fails several stages later on a blank
# value, naming the stage rather than the missing variable. Refuse up front.
missing=()
for n in "${SECRET_ORDER[@]}"; do v="s_${n}"; [ -n "${!v}" ] || missing+=("secret   ${n}"); done
for n in "${VAR_ORDER[@]}"; do v="v_${n}"; [ -n "${!v}" ] || missing+=("variable ${n}"); done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "REFUSING: these have no value:" >&2
  for m in "${missing[@]}"; do echo "  - ${m}" >&2; done
  echo >&2
  echo "  AZURE_CLIENT_ID          run scripts/bootstrap-identities.sh (creates gha-app)" >&2
  echo "  DD_API_KEY               set it in ${ENV_FILE}" >&2
  echo "  AZURE_RG, APP_NAME, ...  apply workspace ${workspace} with the app_service and" >&2
  echo "                           database components, and run \`terraform init\` here" >&2
  exit 1
fi

echo "repo:        ${REPO}"
echo "environment: ${GH_ENVIRONMENT}"
echo "workspace:   ${workspace}"
echo "env file:    ${ENV_FILE}"
[ "${DRY_RUN}" -eq 1 ] && echo "mode:        DRY RUN — nothing will be written"
echo

# ── The environment ───────────────────────────────────────────────────────────
# PUT is idempotent: it creates the environment or leaves an existing one (and
# its protection rules) as it is.
env_exists=unknown
if [ "${have_gh}" -eq 1 ]; then
  if gh api "repos/${REPO}/environments/${GH_ENVIRONMENT}" >/dev/null 2>&1; then
    env_exists=yes
  else
    env_exists=no
  fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  case "${env_exists}" in
    yes) echo "  environment ${GH_ENVIRONMENT} exists" ;;
    no)  echo "  would create environment ${GH_ENVIRONMENT}" ;;
    *)   echo "  would create environment ${GH_ENVIRONMENT} if missing (gh unavailable, not checked)" ;;
  esac
elif [ "${env_exists}" = "yes" ]; then
  echo "  environment ${GH_ENVIRONMENT} exists"
else
  gh api -X PUT "repos/${REPO}/environments/${GH_ENVIRONMENT}" >/dev/null
  echo "  created     environment ${GH_ENVIRONMENT}"
fi

# ── Secrets, by stdin ─────────────────────────────────────────────────────────
for n in "${SECRET_ORDER[@]}"; do
  v="s_${n}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    value="${!v}"
    echo "  would set   secret   ${n}  (${#value} chars)"
    continue
  fi
  if printf '%s' "${!v}" \
       | gh secret set "${n}" --env "${GH_ENVIRONMENT}" --repo "${REPO}" >/dev/null 2>&1; then
    echo "  set         secret   ${n}"
  else
    echo "  FAILED      secret   ${n}" >&2
    exit 1
  fi
done

# ── Variables ─────────────────────────────────────────────────────────────────
for n in "${VAR_ORDER[@]}"; do
  v="v_${n}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  would set   variable ${n} = ${!v}"
    continue
  fi
  if gh variable set "${n}" --env "${GH_ENVIRONMENT}" --repo "${REPO}" \
       --body "${!v}" >/dev/null 2>&1; then
    echo "  set         variable ${n} = ${!v}"
  else
    echo "  FAILED      variable ${n}" >&2
    exit 1
  fi
done

echo
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "dry run complete: ${#SECRET_ORDER[@]} secrets, ${#VAR_ORDER[@]} variables would be set."
else
  echo "pushed: ${#SECRET_ORDER[@]} secrets, ${#VAR_ORDER[@]} variables to ${REPO} / ${GH_ENVIRONMENT}."
fi
