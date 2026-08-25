#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Pause / resume Sentinel compute.  (task 6.8)
#
# Lives here rather than inline in ci_pause.yml for three reasons: the gate lints
# every scripts/*.sh, a hundred-line `run:` block is not reviewable, and a script
# runs locally where a workflow step does not. Inline, it also hung actionlint's
# shell parser outright.
#
# (A line beginning `# shellcheck ...` is read as a DIRECTIVE, not a comment —
# which is how the first draft of this header failed to parse.)
#
# ── Pause is NOT zero cost ───────────────────────────────────────────────────
# Stopping ends the COMPUTE charge, which dominates. These continue regardless:
# OS disks, storage, the AKS load balancer, and ACR's flat daily charge. Only
# destroy is zero. The summary says so, because a pause button that implies
# otherwise is worse than no button.
#
# ── Two limits worth knowing before you rely on it ───────────────────────────
#   Postgres auto-restarts after 7 DAYS — Azure forces it, no opt-out. A pause
#   is a lease, not a switch.
#   AKS stop/start takes 5-10 minutes each way.
#
# Idempotent: starting an already-running resource is an ERROR in Azure, not a
# no-op, so every action checks state first.
#
# Usage: pause.sh --action pause|resume --scope platform|all|<deployment>
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export MSYS_NO_PATHCONV=1

CR="$(printf '\r')"
nocr() { tr -d "${CR}"; }

ACTION="pause"
SCOPE="platform"

while [ $# -gt 0 ]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --scope)  SCOPE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${ACTION}" in
  pause|resume) ;;
  *) echo "--action must be pause or resume" >&2; exit 2 ;;
esac

echo "action=${ACTION} scope=${SCOPE}"
echo

report=""
note() { echo "  $1"; report="${report}
  $1"; }

# Does a resource name belong to the requested scope?
#   platform  only the shared layer (names carry -plat-)
#   all       everything
#   <name>    that deployment's resources
in_scope() {
  case "${SCOPE}" in
    platform) case "$1" in *-plat-*|*plat*) return 0 ;; *) return 1 ;; esac ;;
    all)      return 0 ;;
    *)        case "$1" in *"${SCOPE}"*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

# ── AKS ──────────────────────────────────────────────────────────────────────
# Only the platform holds a cluster, and pausing it stops EVERY deployment's
# workloads at once. Same button, very different blast radius — hence the note.
while IFS=$'\t' read -r name rg; do
  [ -n "${name}" ] || continue
  in_scope "${name}" || continue
  state="$(az aks show -g "${rg}" -n "${name}" --query powerState.code -o tsv | nocr)"
  if [ "${ACTION}" = "pause" ] && [ "${state}" = "Running" ]; then
    az aks stop -g "${rg}" -n "${name}" --no-wait
    note "aks ${name}: stopping (5-10 min) — this stops EVERY deployment's workloads"
  elif [ "${ACTION}" = "resume" ] && [ "${state}" != "Running" ]; then
    az aks start -g "${rg}" -n "${name}" --no-wait
    note "aks ${name}: starting (5-10 min)"
  else
    note "aks ${name}: already ${state}"
  fi
done <<EOF
$(az aks list --query "[].[name,resourceGroup]" -o tsv | nocr)
EOF

# ── Postgres ─────────────────────────────────────────────────────────────────
# Iterates every server rather than taking the first: database.mode=dedicated
# gives a deployment its own, so there can be several.
while IFS=$'\t' read -r name rg; do
  [ -n "${name}" ] || continue
  in_scope "${name}" || continue
  state="$(az postgres flexible-server show -n "${name}" -g "${rg}" --query state -o tsv | nocr)"
  if [ "${ACTION}" = "pause" ] && [ "${state}" = "Ready" ]; then
    az postgres flexible-server stop -n "${name}" -g "${rg}" -o none
    note "postgres ${name}: stopped — Azure force-restarts it in 7 days"
  elif [ "${ACTION}" = "resume" ] && [ "${state}" != "Ready" ]; then
    az postgres flexible-server start -n "${name}" -g "${rg}" -o none
    note "postgres ${name}: started"
  else
    note "postgres ${name}: already ${state}"
  fi
done <<EOF
$(az postgres flexible-server list --query "[].[name,resourceGroup]" -o tsv | nocr)
EOF

# ── App Service ──────────────────────────────────────────────────────────────
# F1 is free either way, so this is not about money — a stopped app also stops
# generating Datadog signal, which matters when you are not watching it.
while IFS=$'\t' read -r name rg; do
  [ -n "${name}" ] || continue
  in_scope "${name}" || continue
  if [ "${ACTION}" = "pause" ]; then
    az webapp stop -n "${name}" -g "${rg}" -o none && note "webapp ${name}: stopped"
  else
    az webapp start -n "${name}" -g "${rg}" -o none && note "webapp ${name}: started"
  fi
done <<EOF
$(az webapp list --query "[?kind!='functionapp'].[name,resourceGroup]" -o tsv | nocr)
EOF

echo
echo "Cannot be paused — these keep billing:"
echo "  ACR                 flat daily charge; covered by the free grant"
echo "  AKS load balancer   persists while the cluster exists"
echo "  disks and storage   allocated regardless of power state"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ${ACTION} · scope \`${SCOPE}\`"
    echo ""
    echo '```'
    echo "${report}"
    echo '```'
    echo "**Still billing:** ACR (flat daily), the AKS load balancer, disks and storage."
    echo "Only destroy is zero."
    if [ "${ACTION}" = "pause" ]; then
      echo ""
      echo "> Postgres auto-restarts after **7 days** — re-run to re-pause."
    else
      echo ""
      echo "> AKS takes 5-10 minutes to start. Wait before applying anything that touches it:"
      echo "> a stopped cluster plans fine and then fails the apply with \`OperationNotAllowed\`."
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi
