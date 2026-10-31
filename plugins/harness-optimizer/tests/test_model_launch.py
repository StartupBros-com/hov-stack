"""Runtime-launch controls; no provider calls."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from run_behavioral import (
    Model,
    ModelUnavailable,
    evaluate,
    frozen_source,
    model_command,
)


class ModelLaunchTests(unittest.TestCase):
    def test_isolation_preserves_explicit_provider_headers_only(self):
        from run_behavioral import isolated_env

        env = isolated_env(
            Path("/synthetic-child"),
            {
                "ANTHROPIC_API_KEY": "fixture-key",
                "ANTHROPIC_BASE_URL": "https://provider.invalid",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Fixture-Auth: fixture-header",
                "UNRELATED_SECRET": "must-not-leak",
                "CLAUDE_CODE_PLUGIN_DIRS": "/private/plugin",
            },
        )
        self.assertEqual(
            env.get("ANTHROPIC_CUSTOM_HEADERS"), "X-Fixture-Auth: fixture-header"
        )
        self.assertEqual(env["ANTHROPIC_API_KEY"], "fixture-key")
        self.assertNotIn("UNRELATED_SECRET", env)
        self.assertNotIn("CLAUDE_CODE_PLUGIN_DIRS", env)

    def test_frozen_discovery_sources_and_equal_collection_capabilities(self):
        import shutil
        from types import SimpleNamespace
        import run_behavioral as runner

        with tempfile.TemporaryDirectory(
            prefix="optimizer-frozen-discovery-"
        ) as directory:
            root = Path(directory)
            package = root / "package"
            shutil.copytree(runner.ROOT, package)
            with patch.object(runner, "ROOT", package):
                source = frozen_source()
                investigator_text = (
                    package / "agents/harness-optimizer-investigator.md"
                ).read_text()
                reference_text = (
                    package / "skills/harness-optimizer/references/discovery.md"
                ).read_text()
                self.assertEqual(source["investigator"], investigator_text)
                self.assertIn(reference_text, source["skill"])
                (package / "agents/harness-optimizer-investigator.md").write_text(
                    "changed between arms"
                )
                (
                    package / "skills/harness-optimizer/references/discovery.md"
                ).write_text("changed between arms")
                prompts = []
                case = dict(
                    json.loads(Path(__file__).with_name("scenarios.json").read_text())[
                        0
                    ],
                    discovery={"active": ["friction"]},
                    oracle={"secret_oracle_marker": True},
                )
                args = SimpleNamespace(
                    model="planted",
                    effort="xhigh",
                    budget_usd=1,
                    timeout=60,
                    max_calls=5,
                )
                for arm in (False, True):
                    model = SimpleNamespace(
                        runtime="planted",
                        served={"planted"},
                        calls=0,
                        cost=0,
                        cost_verified=True,
                    )
                    actions = iter(
                        [
                            {"tool": "investigate", "lane": "friction"},
                            {"tool": "finish", "report": {}},
                        ]
                    )

                    def ask(system, conversation):
                        model.calls += 1
                        prompts.append((arm, system, conversation))
                        if len(conversation) == 1 and "packet" in conversation[0]:
                            packet = conversation[0]["packet"]
                            return {
                                "lane": packet["lane"],
                                "status": "complete",
                                "coverage": {
                                    **packet["coverage"],
                                    "omissions": [],
                                    "reason": "",
                                },
                                "findings": [],
                            }
                        return next(actions)

                    model.ask = ask
                    with patch.object(runner, "Model", return_value=model):
                        receipt = evaluate(case, root / str(arm), args, arm, source)
                    self.assertEqual(receipt["discovery"]["launches"], 1)
                    self.assertEqual(
                        receipt["discovery"]["dispositions"], {"friction": "complete"}
                    )
                    self.assertEqual(receipt["calls"], 3)
                serialized = json.dumps(prompts)
                self.assertNotIn("secret_oracle_marker", serialized)
                self.assertNotIn("changed between arms", serialized)
                for arm, system, conversation in prompts:
                    if len(conversation) == 1 and "packet" in conversation[0]:
                        self.assertIn(investigator_text, system)
                    else:
                        self.assertIn(runner.TOOL_PROTOCOL, system)
                        self.assertEqual(runner.OPTIMIZER_WORKFLOW in system, arm)

    def test_investigator_budget_rejected_before_launch_does_not_consume_attempt(self):
        from types import SimpleNamespace
        import run_behavioral as runner

        with tempfile.TemporaryDirectory(
            prefix="optimizer-dispatch-budget-"
        ) as directory:
            output = Path(directory) / "evaluation"
            model = self.planted_model(output, max_calls=1)
            case = dict(
                json.loads(Path(__file__).with_name("scenarios.json").read_text())[0],
                discovery={"active": ["friction"]},
            )
            real_run = subprocess.run

            def process(command, **kwargs):
                if command[0] == sys.executable:
                    return real_run(command, **kwargs)
                return self.envelope({"tool": "investigate", "lane": "friction"})

            args = SimpleNamespace(
                model="planted", effort="xhigh", budget_usd=1, timeout=60, max_calls=5
            )
            with (
                patch.object(runner, "Model", return_value=model),
                patch.object(runner.subprocess, "run", side_effect=process),
            ):
                receipt = evaluate(case, output, args, source=frozen_source())
            self.assertEqual(receipt["status"], "incomplete")
            self.assertEqual(receipt["calls"], 1)
            self.assertEqual(receipt["discovery"]["launches"], 0)
            self.assertEqual(
                receipt["discovery"]["dispositions"], {"friction": "unavailable"}
            )

    def planted_model(self, output, **limits):
        model = Model.__new__(Model)
        vars(model).update(
            output=output,
            model="planted-no-provider",
            effort="xhigh",
            remaining=1,
            deadline=time.monotonic() + 60,
            max_calls=8,
            calls=0,
            cost=0.0,
            cost_verified=True,
            served=set(),
            env={},
            cli_bin="planted-runtime",
            runtime="planted transport",
        )
        vars(model).update(limits)
        return model

    def envelope(self, action, cost=0.01):
        return subprocess.CompletedProcess(
            [],
            0,
            stdout=json.dumps(
                {
                    "total_cost_usd": cost,
                    "modelUsage": {"planted-no-provider": {}},
                    "structured_output": action,
                }
            ),
            stderr="",
        )

    def test_shared_call_time_and_cost_exhaustion_prevents_subprocess_launch(self):
        for bound in ("calls", "time", "cost"):
            with (
                self.subTest(bound=bound),
                tempfile.TemporaryDirectory(prefix="optimizer-budget-") as directory,
            ):
                model = self.planted_model(
                    Path(directory), max_calls=1 if bound == "calls" else 8
                )
                with patch(
                    "run_behavioral.subprocess.run",
                    return_value=self.envelope(
                        {"objections": []}, 1 if bound == "cost" else 0.01
                    ),
                ) as process:
                    self.assertEqual(
                        model.ask("planted reviewer", []), {"objections": []}
                    )
                    if bound == "time":
                        model.deadline = time.monotonic() - 1
                    with self.assertRaisesRegex(ModelUnavailable, "budget exhausted"):
                        model.ask("planted instruction consumer", [])
                    self.assertEqual(process.call_count, 1)
                    self.assertEqual(model.calls, 1)

    def test_malformed_paid_cost_is_unverified_not_zero_or_budget_credit(self):
        for cost in (
            -0.01,
            float("nan"),
            float("inf"),
            -float("inf"),
            "not-a-number",
            "0.01",
            None,
            True,
        ):
            with (
                self.subTest(cost=cost),
                tempfile.TemporaryDirectory(prefix="optimizer-cost-") as directory,
            ):
                model = self.planted_model(Path(directory))
                with patch(
                    "run_behavioral.subprocess.run",
                    side_effect=[
                        self.envelope({"tool": "check"}),
                        self.envelope({"tool": "check"}, cost),
                    ],
                ):
                    self.assertEqual(
                        model.ask("planted coordinator", []), {"tool": "check"}
                    )
                    with self.assertRaisesRegex(ModelUnavailable, "cost receipt"):
                        model.ask("planted consumer", [])
                self.assertFalse(model.cost_verified)
                self.assertAlmostEqual(model.cost, 0.01)
                self.assertAlmostEqual(model.remaining, 0.99)
                self.assertTrue((Path(directory) / "call-2.stdout").exists())
                with patch("run_behavioral.subprocess.run") as process:
                    with self.assertRaises(ModelUnavailable):
                        model.ask("planted follow-up", [])
                    process.assert_not_called()

    def test_deadline_expiring_during_call_preparation_prevents_launch(self):
        with tempfile.TemporaryDirectory(
            prefix="optimizer-deadline-edge-"
        ) as directory:
            model = self.planted_model(Path(directory), deadline=60)
            with (
                patch("run_behavioral.time.monotonic", side_effect=[0, 61]),
                patch(
                    "run_behavioral.subprocess.run",
                    return_value=self.envelope({"tool": "check"}),
                ) as process,
            ):
                with self.assertRaisesRegex(ModelUnavailable, "budget exhausted"):
                    model.ask("planted coordinator", [])
                process.assert_not_called()
            self.assertEqual(model.calls, 0)

    def test_evaluate_exhaustion_inside_consumers_keeps_incomplete_receipts(self):
        from types import SimpleNamespace

        cases = json.loads(Path(__file__).with_name("scenarios.json").read_text())
        for consumer in ("review", "instruction-trial", "check"):
            for bound in ("calls", "time", "cost"):
                with (
                    self.subTest(consumer=consumer, bound=bound),
                    tempfile.TemporaryDirectory(
                        prefix="optimizer-consumer-budget-"
                    ) as directory,
                ):
                    output = Path(directory) / "evaluation"
                    model = self.planted_model(
                        output, max_calls=2 if bound == "calls" else 8
                    )
                    if consumer == "review":
                        actions = [
                            {"tool": "read", "path": "cli.py"},
                            {
                                "tool": "review",
                                "stage": "diagnosis",
                                "lens": "causal-validity",
                                "targets": ["cli.py"],
                                "changes": {},
                                "claim": {
                                    "cause": "Planted diagnosis",
                                    "scope": "Synthetic only",
                                    "evidence": [0],
                                },
                            },
                        ]
                    else:
                        actions = [
                            {"tool": consumer, "text": "Check arguments."}
                            if consumer == "instruction-trial"
                            else {"tool": "check"},
                            {
                                "argv": [
                                    "tool",
                                    "inspect",
                                    "--project",
                                    "wrong planted input",
                                ],
                                "shell": False,
                            },
                        ]
                    responses = iter(actions)
                    launched = []
                    real_run = subprocess.run

                    def process(command, **kwargs):
                        if command[0] == sys.executable:
                            return real_run(command, **kwargs)
                        launched.append(command)
                        if bound == "time" and len(launched) == 2:
                            model.deadline = time.monotonic() - 1
                        return self.envelope(
                            next(responses), 0.5 if bound == "cost" else 0.01
                        )

                    args = SimpleNamespace(
                        model="planted-no-provider",
                        effort="xhigh",
                        budget_usd=1,
                        timeout=60,
                        max_calls=8,
                    )
                    case = dict(cases[0], instruction_trial=consumer == "check")
                    with (
                        patch("run_behavioral.Model", return_value=model),
                        patch("run_behavioral.subprocess.run", side_effect=process),
                    ):
                        receipt = evaluate(case, output, args, source=frozen_source())
                    self.assertEqual(receipt["status"], "incomplete")
                    self.assertIn("budget exhausted", receipt["blocker"])
                    self.assertEqual(len(launched), 2)
                    self.assertEqual(receipt["calls"], 2)
                    self.assertTrue(receipt["events"])
                    self.assertEqual(
                        json.loads((output / "receipt.json").read_text()), receipt
                    )

    def test_explicit_executable_survives_isolated_home_and_path(self):
        with tempfile.TemporaryDirectory(prefix="optimizer-launch-") as directory:
            root = Path(directory)
            executable = root / "runtime with spaces"
            executable.write_text("fixture runtime identity")
            executable.chmod(0o700)
            calls = []

            def process(command, **kwargs):
                calls.append((command, kwargs))
                if "--help" in command:
                    output = "--bare --restricted --tools --strict-mcp-config --no-session-persistence --max-budget-usd --json-schema"
                elif "--version" in command:
                    output = "fixture-runtime"
                else:
                    output = json.dumps(
                        {
                            "total_cost_usd": 0,
                            "modelUsage": {"fixture": {}},
                            "result": "A narrative preamble is not an action.",
                            "structured_output": {"tool": "finish"},
                        }
                    )
                return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

            with (
                patch.dict(
                    "os.environ", {"ANTHROPIC_API_KEY": "fixture-only"}, clear=False
                ),
                patch("run_behavioral.subprocess.run", side_effect=process),
            ):
                model = Model(
                    root, "fixture", "xhigh", 1, 60, 2, cli_bin=str(executable)
                )
                model.env["PATH"] = "/missing"
                self.assertEqual(model.ask("fixture", []), {"tool": "finish"})
            self.assertIn("--json-schema", calls[-1][0])
            self.assertEqual(len(calls), 3)
            self.assertTrue(all(command[0] == str(executable) for command, _ in calls))
            self.assertTrue(
                all(kwargs["env"]["HOME"] == str(root / "home") for _, kwargs in calls)
            )
            self.assertEqual(
                model_command("fixture", "xhigh", 1, str(executable))[0],
                str(executable),
            )

    def test_every_response_requires_nonempty_model_provenance(self):
        for usage in (None, {}, [], {"": {}}, {"   ": {}}):
            with (
                self.subTest(usage=usage),
                tempfile.TemporaryDirectory(
                    prefix="optimizer-provenance-"
                ) as directory,
            ):
                model = Model.__new__(Model)
                vars(model).update(
                    output=Path(directory),
                    model="fixture",
                    effort="xhigh",
                    remaining=1,
                    deadline=time.monotonic() + 60,
                    max_calls=2,
                    calls=0,
                    cost=0,
                    cost_verified=True,
                    served=set(),
                    env={},
                    cli_bin="planted-runtime",
                )
                envelope = {
                    "total_cost_usd": 0.01,
                    "structured_output": {"tool": "finish"},
                    "modelUsage": {"fixture": {}},
                }
                valid = subprocess.CompletedProcess(
                    [], 0, stdout=json.dumps(envelope), stderr=""
                )
                if usage is None:
                    del envelope["modelUsage"]
                else:
                    envelope["modelUsage"] = usage
                invalid = subprocess.CompletedProcess(
                    [], 0, stdout=json.dumps(envelope), stderr=""
                )
                with patch(
                    "run_behavioral.subprocess.run", side_effect=[valid, invalid]
                ):
                    self.assertEqual(model.ask("fixture", []), {"tool": "finish"})
                    with self.assertRaisesRegex(
                        ModelUnavailable, "served-model receipt"
                    ):
                        model.ask("fixture", [])
                self.assertEqual(model.calls, 2)
                self.assertAlmostEqual(model.cost, 0.02)
                self.assertTrue(model.cost_verified)
                self.assertTrue((Path(directory) / "call-2.stdout").is_file())

    def test_failed_launcher_is_not_reported_as_missing_isolation_flags(self):
        with tempfile.TemporaryDirectory(
            prefix="optimizer-launch-failure-"
        ) as directory:
            root = Path(directory)
            executable = root / "wrapper"
            executable.write_text("fixture wrapper")
            executable.chmod(0o700)
            failure = subprocess.CompletedProcess(
                [], 127, stdout="", stderr="launcher target missing under isolated HOME"
            )
            with (
                patch.dict(
                    "os.environ", {"ANTHROPIC_API_KEY": "fixture-only"}, clear=False
                ),
                patch("run_behavioral.subprocess.run", return_value=failure),
            ):
                with self.assertRaisesRegex(
                    ModelUnavailable, "runtime launch failed.*127"
                ):
                    Model(root, "fixture", "xhigh", 1, 60, 2, cli_bin=str(executable))
            self.assertEqual((root / "preflight.stderr").read_text(), failure.stderr)
