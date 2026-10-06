#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# The kubernetes provider's credential plugin: kubelogin, plus the two things
# a bare `kubelogin` exec could not give us. Called by namespace.tf, not by hand.
#
# ── 1. Its stderr is kept ────────────────────────────────────────────────────
# An exec plugin's stderr goes to the provider process, which Terraform only
# logs under TF_LOG. A failure therefore surfaced as nothing more than
#     getting credentials: exec: executable kubelogin failed with exit code 1
# with the reason (an AADSTS code, an az error) thrown away. When
# SENTINEL_KUBELOGIN_LOG names a file, stderr is appended there instead, and
# lifecycle.sh prints that file when Terraform fails. stderr only — the token
# travels on stdout, which is passed through untouched to the provider.
#
# ── 2. In CI, one refresh and one retry ──────────────────────────────────────
# `--login azurecli` borrows az's session, and that session is minted from a
# GitHub OIDC assertion that expires within minutes (see az-refresh.sh).
# lifecycle.sh refreshes it before every layer; this is the backstop for a
# kubernetes resource first touched late in a long apply. Locally there is
# nothing to refresh from, so a failure is simply returned.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log="${SENTINEL_KUBELOGIN_LOG:-}"

run_kubelogin() {
  if [ -n "${log}" ]; then
    kubelogin "$@" 2>>"${log}"
  else
    kubelogin "$@"
  fi
}

note() {
  if [ -n "${log}" ]; then echo "kubelogin.sh: $*" >>"${log}"; else echo "kubelogin.sh: $*" >&2; fi
}

run_kubelogin "$@" && exit 0
status=$?

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  exit "${status}"
fi

note "kubelogin exited ${status}; refreshing the az session and retrying once"
# stdout to /dev/null: this process's stdout IS the credential channel, and
# nothing az-refresh.sh prints belongs on it.
if [ -n "${log}" ]; then
  bash "${here}/az-refresh.sh" >/dev/null 2>>"${log}" || { note "refresh failed"; exit "${status}"; }
else
  bash "${here}/az-refresh.sh" >/dev/null || { note "refresh failed"; exit "${status}"; }
fi
run_kubelogin "$@"
