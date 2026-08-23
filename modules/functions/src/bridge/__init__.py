"""Event Grid -> GitHub repository_dispatch bridge (architecture/infra.md §3.5).

The ONLY thing this function does is classify and forward. It never mutates
Azure, GitHub state, or the incident itself — HITL demands that GitHub Actions
is the executor and this stays a messenger (fire-and-forget).

Classification is the two-signal contract (§3.4): a Datadog event tagged
`deploy_status:failed` is a failed deploy (Case 2 — revert PR path); anything
else on this topic is a runtime error (Case 3 — full incident response). The
backend branches on `signal_type`, so this field is load-bearing.

stdlib-only HTTP (urllib) — keeps the remote build trivial and the dependency
surface at exactly one package (azure-functions, for the trigger binding).
"""
import json
import logging
import os
import urllib.request
import uuid

import azure.functions as func


def main(event: func.EventGridEvent) -> None:
    data = event.get_json() or {}

    # Tags may arrive as a list (Datadog webhook) or embedded in the title.
    tags_blob = " ".join(data.get("tags", [])) + " " + str(data.get("title", ""))
    signal_type = "deploy_failure" if "deploy_status:failed" in tags_blob else "runtime_error"

    payload = {
        "event_type": os.environ["GITHUB_EVENT_TYPE"],
        "client_payload": {
            # Full passthrough (§3.5) — dd_event_id / alert_id / tags ride along
            # when Datadog sends them — plus the two stamped fields.
            **data,
            "signal_type": signal_type,
            "correlation_id": str(uuid.uuid4()),
        },
    }

    req = urllib.request.Request(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPO']}/dispatches",
        data=json.dumps(payload).encode(),
        headers={
            # GITHUB_TOKEN is a Key Vault *reference* resolved by App Service via
            # the function's system-assigned identity. If it ever arrives empty,
            # the vault grant (enable_bridge_reader) or the seeded secret (B9)
            # is missing — not this code.
            "Authorization": f"token {os.environ['GITHUB_TOKEN']}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        # 204 is the documented success for repository_dispatch.
        logging.info("bridge: %s dispatched (HTTP %s)", signal_type, resp.status)
