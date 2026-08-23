"""Unit tests for the bridge and rotate handlers (tasks 3.3 / 3.6).

stdlib-only on purpose: the handlers import `azure.functions` (present in the
Function host, absent on dev boxes and CI runners), so a fake module is
injected before import. Every outbound HTTP call is intercepted at
urllib.request.urlopen — no network, no credentials, no Azure.

Run:  python -m unittest discover modules/functions/tests -v
"""
import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

SRC = Path(__file__).resolve().parent.parent / "src"


# ── fake azure.functions, just enough for the handlers ────────────────────────
class _FakeEventGridEvent:
    def __init__(self, payload):
        self._payload = payload

    def get_json(self):
        return self._payload


def _install_fake_azure_functions():
    azure = types.ModuleType("azure")
    azure.__path__ = []
    functions = types.ModuleType("azure.functions")
    functions.EventGridEvent = _FakeEventGridEvent
    sys.modules["azure"] = azure
    sys.modules["azure.functions"] = functions


def _load(name, rel):
    _install_fake_azure_functions()
    spec = importlib.util.spec_from_file_location(name, SRC / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _CapturedRequest:
    """Context-manager stand-in for urlopen's response, recording the request."""

    def __init__(self, store):
        self.store = store
        self.status = 204

    def __call__(self, req, timeout=None):
        self.store.append(req)
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return b"{}"


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = _load("bridge_handler", "bridge/__init__.py")
        self.env = {
            "GITHUB_EVENT_TYPE": "incident-alert",
            "GITHUB_REPO": "Keshav0375/Sentinel",
            "GITHUB_TOKEN": "test-token",
        }

    def _run(self, payload):
        sent = []
        with mock.patch.dict("os.environ", self.env, clear=False), \
             mock.patch.object(self.bridge.urllib.request, "urlopen", _CapturedRequest(sent)):
            self.bridge.main(_FakeEventGridEvent(payload))
        self.assertEqual(len(sent), 1, "exactly one dispatch per event")
        req = sent[0]
        return req, json.loads(req.data)

    def test_deploy_failure_classified_from_tags_list(self):
        _, body = self._run({"tags": ["deploy_status:failed", "service:dummy-api"], "title": "x"})
        self.assertEqual(body["client_payload"]["signal_type"], "deploy_failure")

    def test_runtime_error_is_the_default(self):
        _, body = self._run({"tags": ["service:dummy-api"], "title": "5xx spike"})
        self.assertEqual(body["client_payload"]["signal_type"], "runtime_error")

    def test_classifier_reads_title_when_tags_missing(self):
        # Datadog webhook bodies vary: no tags key at all, marker in the title.
        _, body = self._run({"title": "ALERT deploy_status:failed on dummy-api"})
        self.assertEqual(body["client_payload"]["signal_type"], "deploy_failure")

    def test_payload_is_passthrough_plus_stamps(self):
        data = {"dd_event_id": "e-1", "alert_id": "a-1", "tags": ["t"], "title": "T"}
        _, body = self._run(data)
        cp = body["client_payload"]
        for k, v in data.items():
            self.assertEqual(cp[k], v, "original Datadog fields must pass through")
        self.assertIn("signal_type", cp)
        self.assertIn("correlation_id", cp)
        self.assertEqual(body["event_type"], "incident-alert")

    def test_dispatch_target_and_auth(self):
        req, _ = self._run({"title": "x"})
        self.assertEqual(req.full_url, "https://api.github.com/repos/Keshav0375/Sentinel/dispatches")
        self.assertEqual(req.get_header("Authorization"), "token test-token")

    def test_empty_event_still_dispatches_runtime_error(self):
        _, body = self._run({})
        self.assertEqual(body["client_payload"]["signal_type"], "runtime_error")


class RotateTests(unittest.TestCase):
    def setUp(self):
        self.rotate = _load("rotate_handler", "rotate/__init__.py")

    def _run(self, payload, env):
        sent = []
        with mock.patch.dict("os.environ", env, clear=False), \
             mock.patch.object(self.rotate.urllib.request, "urlopen", _CapturedRequest(sent)):
            self.rotate.main(_FakeEventGridEvent(payload))
        return sent

    def test_non_llm_secret_is_ignored(self):
        sent = self._run({"ObjectName": "github-pat"}, {"TEAMS_WEBHOOK_URL": "https://t"})
        self.assertEqual(sent, [], "only the two LLM keys are rotatable")

    def test_manual_path_posts_to_teams(self):
        sent = self._run({"ObjectName": "openai-api-key"},
                         {"TEAMS_WEBHOOK_URL": "https://teams.example/hook",
                          "ANTHROPIC_ADMIN_KEY": ""})
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0].full_url, "https://teams.example/hook")
        self.assertIn("manual", json.loads(sent[0].data)["text"].lower().replace("cannot be auto-rotated", "manual"))

    def test_missing_webhook_does_not_crash(self):
        # B8 open: no webhook seeded. The event re-fires on schedule; the
        # handler must log-and-return, never raise.
        sent = self._run({"ObjectName": "anthropic-api-key"},
                         {"TEAMS_WEBHOOK_URL": "", "ANTHROPIC_ADMIN_KEY": ""})
        self.assertEqual(sent, [])

    def test_anthropic_without_admin_key_takes_manual_path(self):
        sent = self._run({"ObjectName": "anthropic-api-key"},
                         {"TEAMS_WEBHOOK_URL": "https://teams.example/hook",
                          "ANTHROPIC_ADMIN_KEY": ""})
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0].full_url, "https://teams.example/hook")


if __name__ == "__main__":
    unittest.main()
