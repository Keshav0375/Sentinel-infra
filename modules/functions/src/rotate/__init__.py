"""Key Vault SecretNearExpiry -> rotate or escalate (architecture/infra.md §3.8).

Fires ~30 days before an LLM key expires. Two paths:

  1. AUTOMATED — only if an Anthropic *admin* key is configured
     (ANTHROPIC_ADMIN_KEY): mint a replacement via the Admin API, write it as a
     NEW VERSION of the same secret with a fresh 90-day expiry. Consumers read
     "latest", so no redeploy is needed.
  2. MANUAL — everything else (including openai-api-key: OpenAI has no key-mint
     API): post "manual rotation required" to Teams and write NOTHING. A human
     rotates at the provider and re-seeds with --expires; the rotator never
     fabricates a value it cannot obtain.

Writing happens through this function's system-assigned identity, which holds
Key Vault Secrets Officer via the keyvault module's enable_rotator_officer
toggle — the only WRITE principal besides the human operator.
"""
import datetime
import json
import logging
import os
import urllib.request

import azure.functions as func

ROTATABLE = {"anthropic-api-key", "openai-api-key"}


def _teams(message: str) -> None:
    url = os.environ.get("TEAMS_WEBHOOK_URL", "")
    if not url:
        # B8 open: no webhook seeded yet. Log loudly rather than crash — the
        # SecretNearExpiry event will re-fire on its schedule.
        logging.warning("rotate: TEAMS_WEBHOOK_URL empty (B8?) — wanted to say: %s", message)
        return
    req = urllib.request.Request(
        url,
        data=json.dumps({"text": message}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        logging.info("rotate: teams notified (HTTP %s)", resp.status)


def _mint_anthropic(admin_key: str) -> str:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/organizations/api_keys",
        data=json.dumps({"name": f"sentinel-rotated-{datetime.date.today().isoformat()}"}).encode(),
        headers={
            "x-api-key": admin_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())["api_key"]


def main(event: func.EventGridEvent) -> None:
    data = event.get_json() or {}
    secret_name = data.get("ObjectName", "")

    if secret_name not in ROTATABLE:
        logging.info("rotate: ignoring SecretNearExpiry for %r (not an LLM key)", secret_name)
        return

    admin_key = os.environ.get("ANTHROPIC_ADMIN_KEY", "")
    if secret_name == "anthropic-api-key" and admin_key:
        # Imports deferred: the SDK only loads on the automated path, so the
        # manual path works even if a bad deploy broke the azure-* packages.
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient

        new_value = _mint_anthropic(admin_key)
        client = SecretClient(os.environ["KEY_VAULT_URI"], DefaultAzureCredential())
        client.set_secret(
            secret_name,
            new_value,
            expires_on=datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90),
        )
        logging.info("rotate: %s rotated, new version set with +90d expiry", secret_name)
        _teams(f"Sentinel: `{secret_name}` rotated automatically (new version, +90d).")
    else:
        _teams(
            f"Sentinel: `{secret_name}` expires in ~30 days and cannot be auto-rotated. "
            f"Rotate at the provider and re-seed with: az keyvault secret set "
            f"--vault-name {os.environ.get('KEY_VAULT_NAME', 'sentinel-kv-0375')} "
            f"--name {secret_name} --value <new> --expires <+90d>"
        )
