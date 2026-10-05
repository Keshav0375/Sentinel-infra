#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Make gha-app a database principal on one deployment's database (R12).
#
#     bash scripts/grant-db-access.sh --deployment sentinel --environment dev
#     bash scripts/grant-db-access.sh --host <fqdn> --database sentinel_dev
#
# Run by the HUMAN Entra administrator of the Postgres server, after
# `az login` to the subscription's tenant. Not a workflow step, and not
# Terraform:
#
#   - Terraform has no resource for a role INSIDE a database. It attaches
#     server-level Entra administrators and creates the database; mapping an
#     Entra principal to a Postgres role is `pgaadauth_create_principal`, a SQL
#     call (infra §3.2).
#   - gha-app is a database principal, NOT a server admin (decision 2026-10-05).
#     The app pipeline runs on every merge to a repo whose branches are broken
#     on purpose; it may record a deploy, it may not drop the database.
#   - Only an Entra admin can call pgaadauth_create_principal, and the CI
#     identities are deliberately not admins.
#
# ── Idempotent, and meant to be re-run ───────────────────────────────────────
# The role is created only if it is missing, and GRANT is a no-op when the
# privilege is already held. The `deployments` table is created by backend
# phase 1's migration, not by infra, so on a fresh deployment the table grant
# cannot happen yet: the script says so and exits 0. Re-run it after that
# migration has run, and again after any destroy/recreate of the database.
#
# ── The token never leaves this process ──────────────────────────────────────
# psql reads it from PGPASSWORD, which is the environment, not argv: an
# argument is visible in the process table to every user on the machine for as
# long as the call runs. Nothing here prints it, and there is no `set -x`.
#
# Requires: az (logged in as the Postgres Entra admin), psql, and either an
# initialised Terraform working directory (to read the deployment's outputs) or
# --host and --database.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Git Bash rewrites arguments that look like Unix paths; see
# bootstrap-identities.sh. Inert on Linux and macOS.
export MSYS_NO_PATHCONV=1

# `az` emits CRLF on Windows and command substitution keeps the CR. A token
# with a trailing CR is rejected as a bad password, which names nothing useful.
CR="$(printf '\r')"
nocr() { tr -d "${CR}"; }

# Run from the repo root, where `terraform output` finds the working directory.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXPECTED_SUB="174e25ca-ab82-4671-a913-9c2f66e5924d"
ROLE="gha-app"
TABLE="public.deployments"

DEPLOYMENT="sentinel"
ENVIRONMENT="dev"
PG_HOST=""
PG_DATABASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --deployment)  DEPLOYMENT="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --host)        PG_HOST="$2"; shift 2 ;;
    --database)    PG_DATABASE="$2"; shift 2 ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in az psql; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: ${tool} is not installed." >&2
    exit 1
  fi
done

# ── Context assertion ─────────────────────────────────────────────────────────
# `az` keeps one context shared by every terminal, and Sentinel spans two
# tenants. A token from the identity tenant is refused by the server with a
# message about the token, not about the tenant.
current_sub="$(az account show --query id -o tsv 2>/dev/null | nocr || true)"
if [ "${current_sub}" != "${EXPECTED_SUB}" ]; then
  echo "REFUSING: az context is subscription '${current_sub}', expected ${EXPECTED_SUB}" >&2
  echo "  az login && az account set --subscription ${EXPECTED_SUB}" >&2
  exit 1
fi

# ── Where: the deployment's own outputs, unless given ─────────────────────────
# TF_WORKSPACE selects the workspace for this one call without rewriting
# .terraform/environment, so a later `terraform plan` in this checkout is not
# silently pointed at a different deployment.
workspace="${DEPLOYMENT}-${ENVIRONMENT}"
tf_output() {
  TF_WORKSPACE="${workspace}" terraform output -raw "$1" 2>/dev/null | nocr || true
}

if [ -z "${PG_HOST}" ] || [ -z "${PG_DATABASE}" ]; then
  if ! command -v terraform >/dev/null 2>&1; then
    echo "error: terraform is not installed; pass --host and --database." >&2
    exit 1
  fi
  [ -n "${PG_HOST}" ]     || PG_HOST="$(tf_output database_host)"
  [ -n "${PG_DATABASE}" ] || PG_DATABASE="$(tf_output database_name)"
fi

# `terraform output -raw` of a null output prints a warning on stderr and
# nothing on stdout, so an empty value here means "no database in this
# deployment" or "this workspace is not initialised" — not a transient error.
if [ -z "${PG_HOST}" ] || [ -z "${PG_DATABASE}" ]; then
  echo "error: could not resolve the database for workspace ${workspace}." >&2
  echo "       Either the deployment has no \`database\` component, or this checkout" >&2
  echo "       has not run \`terraform init\` against the remote state." >&2
  echo "       Pass --host and --database to skip the lookup." >&2
  exit 1
fi

# The Postgres role of an Entra user IS its UPN, verbatim (pg_admin_principal_name).
ADMIN_UPN="$(az account show --query user.name -o tsv | nocr)"

echo "==> workspace ${workspace}"
echo "==> server    ${PG_HOST}"
echo "==> database  ${PG_DATABASE}"
echo "==> role      ${ROLE}"

# --resource-type oss-rdbms is the audience https://ossrdbms-aad.database.windows.net.
PGPASSWORD="$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv | nocr)"
export PGPASSWORD
export PGSSLMODE=require

# -X ignores ~/.psqlrc, which could otherwise echo queries or change output.
pg() {
  local db="$1"; shift
  psql -X -q -v ON_ERROR_STOP=1 -h "${PG_HOST}" -p 5432 -U "${ADMIN_UPN}" -d "${db}" "$@"
}

# ── 1. The role ───────────────────────────────────────────────────────────────
# Roles are server-wide. The pgaadauth functions live in the `postgres`
# database, so that is where the principal is created. The name must equal the
# managed identity's display name: Azure resolves it to the object ID in Entra
# and matches tokens on that ID from then on.
role_exists="$(pg postgres -tA -c "SELECT 1 FROM pg_roles WHERE rolname = '${ROLE}'")"
if [ "${role_exists}" = "1" ]; then
  echo "    role ${ROLE} exists"
else
  echo "    creating Entra principal ${ROLE} (not admin, no MFA)"
  pg postgres -tA -c "SELECT * FROM pgaadauth_create_principal('${ROLE}', false, false)" >/dev/null
fi

# ── 2. Connect and schema usage ───────────────────────────────────────────────
# Through stdin with psql variables: `:"db"` quotes the name as an identifier,
# and -c would not interpolate it at all.
pg "${PG_DATABASE}" -v db="${PG_DATABASE}" -v role="${ROLE}" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"role";
GRANT USAGE ON SCHEMA public TO :"role";
SQL
echo "    granted CONNECT on ${PG_DATABASE}, USAGE on schema public"

# ── 3. The table, if the backend has created it ───────────────────────────────
table_exists="$(pg "${PG_DATABASE}" -tA -c "SELECT to_regclass('${TABLE}') IS NOT NULL")"
if [ "${table_exists}" = "t" ]; then
  pg "${PG_DATABASE}" -v role="${ROLE}" <<'SQL'
GRANT INSERT, SELECT ON public.deployments TO :"role";
SQL
  echo "    granted INSERT, SELECT on ${TABLE}"
  echo
  echo "==> done. ${ROLE} can record deploys in ${PG_DATABASE}."
else
  echo
  echo "NOTE: ${TABLE} does not exist yet in ${PG_DATABASE}, so the table grant is PENDING."
  echo "      It is created by backend phase 1's migration. Re-run this script after"
  echo "      that migration; until then the app pipeline's record stage fails with"
  echo "      \"relation does not exist\" (decision 2026-10-05, record-stage policy)."
fi
