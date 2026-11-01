"""Tests for sync.py. Run in the repo shell (it has PyYAML):
python3 -m unittest discover -s kubernetes/apps/ai/go-catalog-sync/app
"""

import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest import mock

import yaml

# The job image installs requests and paho-mqtt; the repo shell does not have them.
for name in ("requests", "paho", "paho.mqtt", "paho.mqtt.client"):
    sys.modules.setdefault(name, types.ModuleType(name))

import sync  # noqa: E402

PROXY = """\
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMProxy
metadata:
  name: litellm
spec:
  litellmSettings:
    drop_params: true
    fallbacks:
      - opus: [go-kimi-k3.1-pro, go-glm-5.3]
      - sonnet: [go-glm-5.3, openrouter/anthropic/claude-sonnet-5.5]
"""

GO_MODELS = """\
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMModel
metadata:
  name: go-glm-5.3
spec:
  modelName: go-glm-5.3
  params:
    model: opencode_go/glm-5.3
    apiKeyRef:
      name: opencode-go
      key: OPENCODE_GO_API_KEY
  info:
    extra:
      input_cost_per_token: 1.4e-06
      output_cost_per_token: 4.4e-06
"""


class TrackedModels(unittest.TestCase):
    def test_reads_go_targets_from_proxy_fallbacks(self):
        self.assertEqual(sync.tracked_models(yaml.safe_load(PROXY)), {"kimi-k3.1-pro", "glm-5.3"})

    def test_no_fallbacks_is_empty(self):
        self.assertEqual(sync.tracked_models({"spec": {}}), set())


class GoModelDocs(unittest.TestCase):
    def test_current_prices_reads_info_extra(self):
        docs = list(yaml.safe_load_all(GO_MODELS))
        self.assertEqual(sync.current_prices(docs)["glm-5.3"]["input_cost_per_token"], 1.4e-06)

    def test_build_emits_litellmmodel_per_tracked_model(self):
        docs = sync.build_go_models(
            {"glm-5.3", "kimi-k3.1-pro"},
            {"kimi-k3.1-pro": {"input": 2.0, "output": 10.0}},
            {"glm-5.3": {"input_cost_per_token": 1.4e-06}},
        )
        # The operator makes env var names from metadata.name; keep dots out, as the other models do.
        self.assertEqual([d["metadata"]["name"] for d in docs], ["go-glm-5-3", "go-kimi-k3-1-pro"])
        kimi = docs[1]
        self.assertEqual(kimi["kind"], "LiteLLMModel")
        self.assertEqual(kimi["spec"]["modelName"], "go-kimi-k3.1-pro")
        self.assertEqual(kimi["spec"]["params"]["model"], "opencode_go/kimi-k3.1-pro")
        self.assertEqual(kimi["spec"]["params"]["apiKeyRef"], {"name": "opencode-go", "key": "OPENCODE_GO_API_KEY"})
        self.assertEqual(kimi["spec"]["info"]["extra"], {"input_cost_per_token": 2e-06, "output_cost_per_token": 1e-05})
        # No new price: the old one stays.
        self.assertEqual(docs[0]["spec"]["info"]["extra"], {"input_cost_per_token": 1.4e-06})

    def test_dump_round_trips_with_document_starts_and_indented_lists(self):
        docs = sync.build_go_models({"glm-5.3"}, {"glm-5.3": {"input": 1.4, "output": 4.4}}, {})
        text = sync.dump_go_models(docs)
        self.assertTrue(text.startswith("# GENERATED"))
        self.assertIn("\n---\n", text)
        self.assertEqual([d for d in yaml.safe_load_all(text) if d], docs)

    def test_dump_indents_sequences(self):
        text = sync.dump_go_models([{"a": [1, 2]}])
        self.assertIn("a:\n  - 1\n", text)


class DiffPrices(unittest.TestCase):
    def test_large_change_is_suspicious_and_not_applied(self):
        new = {"glm-5.3": {"input": 14.0, "output": 4.4}}
        applied, suspicious = sync.diff_prices({"glm-5.3"}, new, {"glm-5.3": {"input_cost_per_token": 1.4e-06, "output_cost_per_token": 4.4e-06}})
        self.assertEqual(applied, {})
        self.assertIn("glm-5.3", suspicious)
        self.assertNotIn("glm-5.3", new)


class Run(unittest.TestCase):
    def test_dry_run_writes_catalog_and_go_models(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)
            ldir = repo / sync.LITELLM_DIR
            (ldir / "models").mkdir(parents=True)
            (ldir / "litellmproxy.yaml").write_text(PROXY)
            (ldir / "models" / "opencode-go.yaml").write_text(GO_MODELS)
            catalog = (["glm-5.3", "kimi-k3.1-pro", "muse-spark-1.3-contributor"], {})
            prices = ({"glm-5.3": {"input": 1.4, "output": 4.4}, "kimi-k3.1-pro": {"input": 2.0, "output": 10.0}}, {})
            with mock.patch.object(sync, "DRY_RUN", True), mock.patch.object(sync, "MQTT_HOST", ""), \
                    mock.patch.object(sync, "fetch_catalog", return_value=catalog), \
                    mock.patch.object(sync, "fetch_prices", return_value=prices):
                sync.run(repo)
            self.assertEqual(json.loads((ldir / "go-catalog.json").read_text()), catalog[0])
            docs = [d for d in yaml.safe_load_all((ldir / "models" / "opencode-go.yaml").read_text()) if d]
            self.assertEqual([d["spec"]["modelName"] for d in docs], ["go-glm-5.3", "go-kimi-k3.1-pro"])


if __name__ == "__main__":
    unittest.main()
