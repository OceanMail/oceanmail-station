#!/usr/bin/env python3
"""Real-process, loopback HTTP acceptance. Synthetic identities; ephemeral secrets."""

import copy
import http.client
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/debug/oceanmail-station"


class AuthAcceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oceanmail-auth-")
        self.root = Path(self.temp.name)
        self.tokens = {
            name: secrets.token_hex(32)
            for name in [
                "alice",
                "bob",
                "admin",
                "operator",
                "captain",
                "no_permission",
                "expired",
            ]
        }
        self.config = {"laboratory_only": True, "credentials": []}
        for name, token in self.tokens.items():
            role = {
                "admin": "admin",
                "operator": "operator",
                "captain": "owner_captain",
            }.get(name, "user")
            grants = (
                [
                    {
                        "account_id": "account-" + name,
                        "permissions": ["context_read", "available_read"],
                    }
                ]
                if name in ("alice", "bob")
                else []
            )
            self.config["credentials"].append(
                {
                    "token": token,
                    "user_id": "user-" + name,
                    "role": role,
                    "permissions": []
                    if name == "no_permission"
                    else ["auth_context_read"],
                    "device_id": "device-" + name,
                    "device_trusted": name != "alice",
                    "account_grants": grants,
                    "expires_at_unix": 1
                    if name == "expired"
                    else int(time.time()) + 300,
                }
            )
        self.auth_file = self.root / "auth.json"
        self.auth_file.touch(mode=0o600)
        self.auth_file.write_text(json.dumps(self.config))
        self.postqueue = self.root / "postqueue"
        self.postqueue.write_text("#!/bin/sh\nexit 0\n")
        self.postqueue.chmod(0o700)
        self.log = self.root / "station.log"
        self.process = None
        self.start()

    def start(self, configured=True, bind=None):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        env = os.environ.copy()
        env.pop("OCEANMAIL_LAB_AUTH_FILE", None)
        env.update(
            OCEANMAIL_BIND=bind or f"127.0.0.1:{self.port}",
            OCEANMAIL_STATE_DB=str(self.root / "station.db"),
            OCEANMAIL_POSTQUEUE=str(self.postqueue),
        )
        if configured:
            env["OCEANMAIL_LAB_AUTH_FILE"] = str(self.auth_file)
        with self.log.open("ab") as output:
            self.process = subprocess.Popen(
                [str(BINARY)], env=env, stdout=output, stderr=output
            )
        if bind is not None:
            return
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail("Station exited before becoming ready")
            try:
                if self.request("/api/v1/health")[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.025)
        self.fail("Station did not become ready within 10 seconds")

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

    def tearDown(self):
        self.stop()
        try:
            # Configuration is the sole operator-owned secret input. Station must
            # never copy these secrets into its logs, SQLite/WAL, or other output.
            for path in self.root.iterdir():
                if path.is_file() and path != self.auth_file:
                    data = path.read_bytes()
                    for token in self.tokens.values():
                        self.assertNotIn(
                            token.encode(), data, "secret leaked to Station output"
                        )
        finally:
            self.temp.cleanup()

    def request(self, path, name=None, extra_headers=None, token=None):
        headers = dict(extra_headers or {})
        if name is not None or token is not None:
            headers["Authorization"] = "Bearer " + (
                token if token is not None else self.tokens[name]
            )
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            conn.request("GET", path, headers=headers)
            response = conn.getresponse()
            raw = response.read()
            for secret in self.tokens.values():
                self.assertNotIn(secret.encode(), raw, "secret leaked in HTTP response")
            return response.status, json.loads(raw), dict(response.getheaders())
        finally:
            conn.close()

    def test_missing_invalid_expired_and_query_credentials_denied(self):
        for path, name, token in [
            ("/api/v1/auth/context", None, None),
            ("/api/v1/auth/context", None, secrets.token_hex(32)),
            ("/api/v1/auth/context", "expired", None),
            ("/api/v1/auth/context?token=" + self.tokens["alice"], None, None),
        ]:
            status, body, headers = self.request(path, name, token=token)
            self.assertEqual((status, body), (401, {"error": "unauthorized"}))
            self.assertEqual(headers["cache-control"], "no-store")
            self.assertEqual(headers["www-authenticate"], "Bearer")

    def test_context_is_server_derived_and_device_trust_is_independent(self):
        status, alice, headers = self.request(
            "/api/v1/auth/context",
            "alice",
            {
                "X-User-Id": "user-bob",
                "X-Account-Id": "account-bob",
                "X-Role": "admin",
                "X-Device-Trusted": "true",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(alice["user_id"], "user-alice")
        self.assertEqual(alice["role"], "user")
        self.assertFalse(alice["device_trusted"])
        self.assertEqual(alice["device_id"], "device-alice")
        self.assertEqual(
            alice["account_grants"], self.config["credentials"][0]["account_grants"]
        )
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(headers["vary"], "Authorization")
        _, bob, _ = self.request("/api/v1/auth/context", "bob")
        self.assertEqual(bob["role"], "user")
        self.assertTrue(bob["device_trusted"])

    def test_account_isolation_and_nonexistent_scope_have_identical_denial(self):
        self.assertEqual(
            self.request("/api/v1/accounts/account-alice/auth/context", "alice")[0], 200
        )
        for principal in ("alice", "admin", "operator", "captain", "no_permission"):
            foreign = self.request(
                "/api/v1/accounts/account-bob/auth/context", principal
            )
            absent = self.request(
                "/api/v1/accounts/nonexistent/auth/context", principal
            )
            self.assertEqual(foreign[:2], (403, {"error": "forbidden"}))
            self.assertEqual(foreign[:2], absent[:2])
        self.assertEqual(
            self.request("/api/v1/accounts/account-alice/auth/context", "bob")[0], 403
        )
        self.assertEqual(
            self.request("/api/v1/accounts/account-alice/auth/context")[0], 401
        )

    def test_permission_is_required_even_for_authenticated_principal(self):
        self.assertEqual(
            self.request("/api/v1/auth/context", "no_permission")[:2],
            (403, {"error": "forbidden"}),
        )

    def test_identity_survives_restart_only_via_explicit_reprovision(self):
        before = self.request("/api/v1/auth/context", "alice")[1]
        self.stop()
        self.start()
        self.assertEqual(before, self.request("/api/v1/auth/context", "alice")[1])
        self.stop()
        self.start(configured=False)
        self.assertEqual(self.request("/api/v1/auth/context", "alice")[0], 401)

    def test_removed_grant_is_denied_after_lab_restart(self):
        self.stop()
        config = copy.deepcopy(self.config)
        config["credentials"][0]["account_grants"] = []
        self.auth_file.write_text(json.dumps(config))
        self.start()
        self.assertEqual(
            self.request("/api/v1/accounts/account-alice/auth/context", "alice")[0], 403
        )

    def test_no_production_capability_is_promoted(self):
        station = self.request("/api/v1/station")[1]
        self.assertFalse(station["capabilities"]["api_authentication"])
        self.assertFalse(station["capabilities"]["lan_exposure"])
        security = self.request("/api/v1/security/storage")[1]
        for field in (
            "production_storage_ready",
            "application_storage_encryption",
            "per_user_key_separation",
            "host_volume_encryption_verified",
        ):
            self.assertFalse(security[field])
        self.assertEqual(self.request("/api/v1/queues/outbound/history")[0], 200)

    def test_auth_configuration_does_not_enable_lan_binding(self):
        self.stop()
        self.start(bind="0.0.0.0:0")
        self.assertNotEqual(self.process.wait(timeout=5), 0)

    def test_invalid_configuration_fails_startup_without_secret_diagnostics(self):
        self.stop()
        self.auth_file.write_text('{"token":"' + self.tokens["alice"] + '"}')
        self.start(bind="127.0.0.1:0")
        self.assertNotEqual(self.process.wait(timeout=5), 0)
        self.assertIn(
            b"invalid laboratory authentication configuration", self.log.read_bytes()
        )

    def test_group_readable_credential_file_fails_startup(self):
        self.stop()
        self.auth_file.chmod(0o640)
        self.start(bind="127.0.0.1:0")
        self.assertNotEqual(self.process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main()
