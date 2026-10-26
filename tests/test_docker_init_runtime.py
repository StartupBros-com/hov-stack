#!/usr/bin/env python3
"""Hermetic admission checks for the opt-in real Docker proof."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parent / "docker-init-runtime.test.sh"
IMAGE = "sha256:" + "a" * 64


class DockerInitRuntimeAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="docker-init-admission-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ledger = self.root / "docker.calls"
        self.binary = self.root / "docker"
        self.binary.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >>\"$FAKE_DOCKER_LEDGER\"\n"
            "[ \"$1\" = --host ] || exit 95\n"
            "shift 2\n"
            "case \"$1 $2\" in\n"
            "  'version --format') printf '29.7.2|6a43e3d\\n' ;;\n"
            "  'image inspect')\n"
            "    case \"$4\" in\n"
            "      '{{.Id}}') printf '%s\\n' \"$FAKE_IMAGE\" ;;\n"
            "      *Volumes*) printf 'null\\n' ;;\n"
            "      *Entrypoint*) printf '[\"docker-entrypoint.sh\"]\\n' ;;\n"
            "      *) exit 96 ;;\n"
            "    esac ;;\n"
            "  'container inspect')\n"
            "    case \"$4\" in\n"
            "      '{{.Image}}') printf '%s\\n' \"$FAKE_IMAGE\" ;;\n"
            "      *Healthcheck*) printf '[\"CMD-SHELL\",\"unexpected-probe\"]\\n' ;;\n"
            "      *) exit 97 ;;\n"
            "    esac ;;\n"
            "  *) exit 98 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        self.binary.chmod(0o755)
        self.env = os.environ.copy()
        self.env.pop("DOCKER_INIT_RUNTIME_TEST", None)
        self.env.update(
            PATH=f"{self.root}:/usr/bin:/bin",
            FAKE_DOCKER_LEDGER=str(self.ledger),
            FAKE_IMAGE=IMAGE,
        )

    def run_script(self, *args: str, consent: bool = False) -> subprocess.CompletedProcess[str]:
        env = dict(self.env)
        if consent:
            env["DOCKER_INIT_RUNTIME_TEST"] = "1"
        return subprocess.run(
            ["/usr/bin/bash", str(RUNNER), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def assert_no_docker(self) -> None:
        self.assertFalse(self.ledger.exists(), "admission reached Docker before consent")

    def install_create_signal_fake_docker(self) -> None:
        self.created_id = "b" * 64
        self.external_id = "e" * 64
        self.created_marker = self.root / "create.materialized"
        self.removed_marker = self.root / "container.removed"
        self.created_name = self.root / "created.name"
        self.created_owner = self.root / "created.owner"
        self.created_role = self.root / "created.role"
        studio_probe = (
            "node --eval=\"fetch('http://127.0.0.1:3000/api/platform/profile')"
            ".then((r) => {if (!r.ok) throw new Error(r.status)})\""
        )
        pg_meta_probe = (
            "node --eval=\"fetch('http://127.0.0.1:8080/health')"
            ".then((r) => {if (!r.ok) throw new Error(r.status)})\""
        )
        self.env.update(
            FAKE_CREATED_ID=self.created_id,
            FAKE_EXTERNAL_ID=self.external_id,
            FAKE_CREATE_MARKER=str(self.created_marker),
            FAKE_REMOVED_MARKER=str(self.removed_marker),
            FAKE_CREATED_NAME=str(self.created_name),
            FAKE_CREATED_OWNER=str(self.created_owner),
            FAKE_CREATED_ROLE=str(self.created_role),
            FAKE_STUDIO_HEALTH=json.dumps(["CMD-SHELL", studio_probe]),
            FAKE_PG_META_HEALTH=json.dumps(["CMD-SHELL", pg_meta_probe]),
        )
        self.binary.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >>\"$FAKE_DOCKER_LEDGER\"\n"
            "[ \"$1\" = --host ] || exit 95\n"
            "shift 2\n"
            "case \"$1 $2\" in\n"
            "  'version --format') printf '29.7.2|6a43e3d\\n' ;;\n"
            "  'image inspect')\n"
            "    case \"$4\" in\n"
            "      '{{.Id}}') printf '%s\\n' \"$FAKE_IMAGE\" ;;\n"
            "      *Volumes*) printf 'null\\n' ;;\n"
            "      *Entrypoint*) printf '[\"docker-entrypoint.sh\"]\\n' ;;\n"
            "      *) exit 96 ;;\n"
            "    esac ;;\n"
            "  'container ls') printf '%s\\n' \"$FAKE_EXTERNAL_ID\" ;;\n"
            "  'volume ls') : ;;\n"
            "  'container create')\n"
            "    shift 2\n"
            "    name= owner= role=\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      case \"$1\" in\n"
            "        --name) name=$2; shift 2; continue ;;\n"
            "        --label)\n"
            "          case \"$2\" in\n"
            "            com.startupbros.docker-init-runtime.owner=*) owner=${2#*=} ;;\n"
            "            com.startupbros.docker-init-runtime.role=*) role=${2#*=} ;;\n"
            "          esac\n"
            "          shift 2; continue ;;\n"
            "      esac\n"
            "      shift\n"
            "    done\n"
            "    [ -n \"$name\" ] && [ -n \"$owner\" ] && [ -n \"$role\" ]\n"
            "    printf '%s\\n' \"$name\" >\"$FAKE_CREATED_NAME\"\n"
            "    printf '%s\\n' \"$owner\" >\"$FAKE_CREATED_OWNER\"\n"
            "    printf '%s\\n' \"$role\" >\"$FAKE_CREATED_ROLE\"\n"
            "    : >\"$FAKE_CREATE_MARKER\"\n"
            "    sleep 0.5\n"
            "    printf '%s\\n' \"$FAKE_CREATED_ID\" ;;\n"
            "  'container inspect')\n"
            "    format=$4 target=$5\n"
            "    case \"$format\" in\n"
            "      '{{.Image}}') printf '%s\\n' \"$FAKE_IMAGE\" ;;\n"
            "      *Healthcheck*)\n"
            "        case \"$target\" in\n"
            "          source-studio) printf '%s\\n' \"$FAKE_STUDIO_HEALTH\" ;;\n"
            "          source-meta) printf '%s\\n' \"$FAKE_PG_META_HEALTH\" ;;\n"
            "          *) exit 97 ;;\n"
            "        esac ;;\n"
            "      *Config.Labels*)\n"
            "        IFS= read -r created_name <\"$FAKE_CREATED_NAME\"\n"
            "        IFS= read -r owner <\"$FAKE_CREATED_OWNER\"\n"
            "        IFS= read -r role <\"$FAKE_CREATED_ROLE\"\n"
            "        if [ \"$target\" = \"$created_name\" ] || [ \"$target\" = \"$FAKE_CREATED_ID\" ]; then\n"
            "          printf '%s\\t%s\\t%s\\n' \"$FAKE_CREATED_ID\" \"$owner\" \"$role\"\n"
            "        else\n"
            "          exit 97\n"
            "        fi ;;\n"
            "      '{{.Id}}')\n"
            "        [ \"$target\" = \"$FAKE_EXTERNAL_ID\" ] || exit 97\n"
            "        printf '%s\\n' \"$FAKE_EXTERNAL_ID\" ;;\n"
            "      *) exit 97 ;;\n"
            "    esac ;;\n"
            "  'container rm')\n"
            "    [ \"$3\" = -f ] && [ \"$4\" = \"$FAKE_CREATED_ID\" ] || exit 99\n"
            "    printf '%s\\n' \"$4\" >\"$FAKE_REMOVED_MARKER\" ;;\n"
            "  *) exit 98 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        self.binary.chmod(0o755)

    def test_help_is_offline(self) -> None:
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source", result.stdout.lower())
        self.assert_no_docker()

    def test_both_consent_signals_are_required(self) -> None:
        for args, consent in [([], False), (["--allow-real-docker"], False), ([], True)]:
            with self.subTest(args=args, consent=consent):
                result = self.run_script(*args, consent=consent)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assert_no_docker()

    def test_post_phase_is_not_silently_substituted(self) -> None:
        result = self.run_script("--allow-real-docker", "--phase", "post", consent=True)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("owned by U4", result.stderr)
        self.assert_no_docker()

    def test_remote_endpoint_is_refused_before_docker(self) -> None:
        result = self.run_script(
            "--allow-real-docker", "--phase", "pre", "--socket", "tcp://example.invalid:2375",
            "--studio-image", IMAGE, "--pg-meta-image", IMAGE,
            "--studio-container", "source-studio", "--pg-meta-container", "source-meta",
            consent=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong-docker-endpoint", result.stdout)
        self.assert_no_docker()

    def test_interrupt_after_create_materializes_recovers_only_owned_id(self) -> None:
        self.install_create_signal_fake_docker()
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        socket_path = self.root / "fixture.sock"
        sock.bind(str(socket_path))
        env = dict(self.env)
        env["DOCKER_INIT_RUNTIME_TEST"] = "1"
        process = subprocess.Popen(
            [
                "/usr/bin/bash", str(RUNNER),
                "--allow-real-docker", "--phase", "pre", "--socket", f"unix://{socket_path}",
                "--studio-image", IMAGE, "--pg-meta-image", IMAGE,
                "--studio-container", "source-studio", "--pg-meta-container", "source-meta",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.created_marker.exists():
                if process.poll() is not None:
                    break
                time.sleep(0.01)
            self.assertTrue(self.created_marker.exists(), "fake Docker never materialized the fixture")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

        self.assertEqual(process.returncode, 1, stderr)
        self.assertIn("runtime_proof=false", stdout)
        self.assertTrue(self.removed_marker.exists(), "materialized fixture ID was not removed")
        self.assertEqual(self.removed_marker.read_text(encoding="utf-8").strip(), self.created_id)
        calls = self.ledger.read_text(encoding="utf-8")
        self.assertEqual(calls.count(f"container rm -f {self.created_id}"), 1)
        self.assertNotIn(f"container rm -f {self.external_id}", calls)
        self.assertIn(f"container inspect --format {{{{.Id}}}} {self.external_id}", calls)

    def test_deployed_probe_mismatch_prevents_fixture_creation(self) -> None:
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        socket_path = self.root / "fixture.sock"
        sock.bind(str(socket_path))
        result = self.run_script(
            "--allow-real-docker", "--phase", "pre", "--socket", f"unix://{socket_path}",
            "--studio-image", IMAGE, "--pg-meta-image", IMAGE,
            "--studio-container", "source-studio", "--pg-meta-container", "source-meta",
            consent=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deployed healthcheck does not match", result.stderr)
        calls = self.ledger.read_text(encoding="utf-8")
        self.assertIn("container inspect", calls)
        self.assertIn("source-studio", calls)
        for mutation in ("container create", "container start", "container exec", "container rm"):
            self.assertNotIn(mutation, calls)
        self.assertIn("runtime_proof=false", result.stdout)


if __name__ == "__main__":
    unittest.main()
