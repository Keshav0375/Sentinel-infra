#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Preflight — the checks a `terraform plan` structurally cannot make.
#
# A plan proves auth works, state is readable, config is valid, and what would
# change. It does NOT prove an apply will succeed. Every check below maps to a
# failure this project actually hit, and none of them are visible to a plan:
#
#   quota            the 6-vCPU regional ceiling
#   SKU availability B2ats_v2 failed the system-pool RAM floor; B2s was not in
#                    this subscription's allowed AKS list for canadacentral
#   providers        ten had to be registered by hand on a fresh subscription
#   name availability `sentineltfstate` was already taken by another tenant
#   soft-deleted vault a destroyed vault holds its name for 7 days
#   postgres state   `400 ServerStoppedError` broke a run three times
#
# ── Two modes, because the identities differ ─────────────────────────────────
# `plan`  runs under gha-plan (Reader). It gets the checks Reader can perform.
# `apply` runs under gha-deploy. Name availability is a POST `*/action` that
#         Reader cannot call at all, so those checks live here.
#
# The alternative was widening gha-plan so one script could do everything. That
# was rejected: an identity any pull request can trigger should not gain actions
# to satisfy a checklist.
#
# A check that says "no" without saying "run this" has moved the problem rather
# than solved it, so every failure prints its remedy.
#
# Usage: preflight.sh --mode plan|apply [--deployment <d>] [--environment <e>]
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# Git Bash rewrites `/subscriptions/...` into a Windows path; the API then
# answers MissingSubscription, which says nothing about path conversion.
export MSYS_NO_PATHCONV=1

CR="$(printf '\r')"
nocr() { tr -d "${CR}"; }

MODE="plan"
DEPLOYMENT=""
ENVIRONMENT=""
LOCATION="${AZURE_LOCATION:-canadacentral}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)        MODE="$2"; shift 2 ;;
    --deployment)  DEPLOYMENT="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --location)    LOCATION="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

FAILED=0
pass() { printf '  %-42s PASS\n' "$1"; }
warn() { printf '  %-42s WARN  %s\n' "$1" "$2"; }
fail() { printf '  %-42s FAIL  %s\n' "$1" "$2"; FAILED=1; }

echo "preflight (mode=${MODE}, location=${LOCATION})"
echo

# ── Checks available to BOTH identities ──────────────────────────────────────

# The school tenant. If this fails nothing else can run, so it is first.
sub="$(az account show --query id -o tsv 2>/dev/null | nocr)"
if [ -n "${sub}" ]; then
  pass "azure token (school tenant)"
else
  fail "azure token (school tenant)" "az login --tenant <school>"
fi

# A fresh subscription has these unregistered and the resulting Terraform error
# reads like a bug in the config rather than a subscription that has never been
# used.
unregistered=""
for ns in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
          Microsoft.KeyVault Microsoft.EventGrid Microsoft.Web Microsoft.Storage \
          Microsoft.ManagedIdentity; do
  state="$(az provider show --namespace "${ns}" --query registrationState -o tsv 2>/dev/null | nocr)"
  [ "${state}" = "Registered" ] || unregistered="${unregistered} ${ns}"
done
if [ -z "${unregistered}" ]; then
  pass "resource providers registered"
else
  fail "resource providers registered" "az provider register --namespace${unregistered}"
fi

# The ceiling that decides the whole architecture: 6 vCPU regionally, and an AKS
# node is 2. It is why deployments share one cluster instead of getting their own.
usage="$(az vm list-usage --location "${LOCATION}" --query "[?name.value=='cores'].{c:currentValue,l:limit}" -o tsv 2>/dev/null | nocr)"
if [ -n "${usage}" ]; then
  cur="$(echo "${usage}" | cut -f1)"
  lim="$(echo "${usage}" | cut -f2)"
  if [ "${cur}" -lt "${lim}" ]; then
    pass "regional vCPU quota (${cur}/${lim} used)"
  else
    fail "regional vCPU quota (${cur}/${lim} used)" "pause or destroy a deployment, or request an increase"
  fi
else
  warn "regional vCPU quota" "could not read usage"
fi

# Three SKUs were rejected before B2pls_v2 was found: the grant SKU failed the
# system pool's RAM floor, and the obvious small SKUs are not in this
# subscription's allowed list for this region.
if az vm list-skus --location "${LOCATION}" --size Standard_B2pls_v2 --query "[0].name" -o tsv 2>/dev/null | grep -q .; then
  pass "AKS node SKU available in region"
else
  fail "AKS node SKU available in region" "az vm list-skus --location ${LOCATION} --resource-type virtualMachines -o table"
fi

# Stopped is Postgres' NORMAL idle state, and a stopped server ERRORS a plan —
# the provider must refresh admins, database and extensions, none of which read
# while it is down.
servers="$(az postgres flexible-server list --query "[].{n:name,g:resourceGroup,s:state}" -o tsv 2>/dev/null | nocr)"
if [ -z "${servers}" ]; then
  pass "postgres servers (none yet)"
else
  stopped=""
  while IFS=$'\t' read -r n _ s; do
    [ "${s}" = "Ready" ] || stopped="${stopped} ${n}"
  done <<< "${servers}"
  if [ -z "${stopped}" ]; then
    pass "postgres servers running"
  elif [ "${MODE}" = "plan" ]; then
    # gha-plan holds no write action anywhere and CANNOT start them. Reporting is
    # the correct behaviour; starting is the Pause/Resume workflow's job.
    warn "postgres servers running" "stopped:${stopped} — run Pause/Resume (resume), the plan will fail otherwise"
  else
    fail "postgres servers running" "az postgres flexible-server start -n <name> -g <rg>"
  fi
fi

# ── Checks that need `*/action`, so apply-mode only ──────────────────────────
if [ "${MODE}" = "apply" ] && [ -n "${DEPLOYMENT}" ] && [ -n "${ENVIRONMENT}" ]; then
  echo
  uid="$(printf '%s' "${sub}-${DEPLOYMENT}-${ENVIRONMENT}" | sha1sum | cut -c1-4)"
  kv="kv-${DEPLOYMENT}-${ENVIRONMENT}-${uid}"
  st="st${DEPLOYMENT}${ENVIRONMENT}${uid}"

  # A destroyed vault holds its name for 7 days. Without purge, destroy →
  # recreate of the same deployment fails on a vault nobody can see — which is
  # the exact cycle this platform exists to support.
  if az keyvault list-deleted --query "[?name=='${kv}'].name" -o tsv 2>/dev/null | grep -q .; then
    fail "key vault name free (${kv})" "az keyvault purge --name ${kv} --location ${LOCATION}"
  else
    pass "key vault name free (${kv})"
  fi

  # Globally unique across every Azure tenant, and a taken name fails with a
  # message that does not say "taken".
  avail="$(az storage account check-name --name "${st}" --query nameAvailable -o tsv 2>/dev/null | nocr)"
  if [ "${avail}" = "true" ]; then
    pass "storage account name free (${st})"
  else
    fail "storage account name free (${st})" "another tenant holds it — change the deployment name"
  fi
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "preflight: OK"
  exit 0
fi
echo "preflight: FAILED — see remedies above"
exit 1
