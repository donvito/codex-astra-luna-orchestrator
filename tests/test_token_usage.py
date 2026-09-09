import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.token_usage import thread_role

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "token_usage.py"
STRING_ROLES = ("review", "compact", "memory_consolidation")


class ThreadRoleTests(unittest.TestCase):
    def test_string_subagent_sources(self):
        for role in STRING_ROLES:
            with self.subTest(role=role):
                self.assertEqual(thread_role({"source": {"subagent": role}}), (role, ""))

    def test_existing_source_shapes(self):
        cases = [
            ({"id": "root", "session_id": "root", "source": "cli"}, ("root", "")),
            (
                {
                    "source": {
                        "subagent": {
                            "thread_spawn": {
                                "agent_role": "worker",
                                "agent_nickname": "Luna",
                            }
                        }
                    }
                },
                ("worker", "Luna"),
            ),
            ({"source": {"subagent": {"other": "guardian"}}}, ("guardian", "")),
            (
                {"id": "child", "source": "cli", "thread_source": "guardian_review"},
                ("guardian_review", ""),
            ),
        ]
        for meta, expected in cases:
            with self.subTest(meta=meta):
                self.assertEqual(thread_role(meta), expected)


class TokenUsageCliTests(unittest.TestCase):
    def run_cli(self, *args):
        with tempfile.TemporaryDirectory() as directory:
            for index, role in enumerate(("root", *STRING_ROLES)):
                source = "cli" if role == "root" else {"subagent": role}
                records = [
                    {
                        "type": "session_meta",
                        "payload": {
                            "id": role,
                            "session_id": "root",
                            "source": source,
                            "timestamp": "2026-09-09T12:00:00Z",
                            "cwd": "/example",
                        },
                    },
                    {"type": "turn_context", "payload": {"model": "test-model"}},
                    {
                        "type": "token_usage_record",
                        "payload": {
                            "usage": {"input_tokens": 90, "output_tokens": 10, "total_tokens": 100},
                        },
                    },
                ]
                path = Path(directory) / f"rollout-{index}.jsonl"
                path.write_text(
                    "\n".join(json.dumps(record) for record in records), encoding="utf-8"
                )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--sessions-dir", directory, *args],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_list_counts_string_subagent_sources(self):
        output = self.run_cli("--list")
        self.assertRegex(output, r"root\s+3\s+/example")

    def test_latest_renders_string_subagent_roles(self):
        output = self.run_cli("--latest")
        self.assertIn("4 (4 counted, 0 auto-review skipped)", output)
        for role in STRING_ROLES:
            self.assertIn(f"| {role} | test-model", output)

    def test_root_json_preserves_roles_and_usage(self):
        report = json.loads(self.run_cli("--root", "root", "--format", "json"))
        self.assertEqual({thread["role"] for thread in report["threads"]}, {"root", *STRING_ROLES})
        self.assertEqual(
            sum(thread["per_model"]["test-model"]["total_tokens"] for thread in report["threads"]),
            400,
        )


if __name__ == "__main__":
    unittest.main()
