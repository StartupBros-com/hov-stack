#!/usr/bin/env python3
"""Regression test for wsl-cdp-forward.py half-close semantics.

The bug (pre-0.3.0): pipe()'s `finally` called writer.close(), tearing the whole
shared connection the moment EITHER direction hit EOF. A CDP client that finished
sending (half-close) would kill the reverse direction mid-flight, truncating a
large screenshot frame streaming back the other way.

This test reproduces exactly that: the client half-closes its write side, and the
target then streams 4 MiB back. Pre-fix the client receives a truncated stream;
post-fix (write_eof + full close only after both directions finish) it receives
every byte. Stdlib only; no live bridge touched (ephemeral loopback ports).
"""
import os
import socket
import subprocess
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FWD = os.path.join(HERE, "..", "wsl-cdp-forward.py")


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class HalfCloseRelayTest(unittest.TestCase):
    def test_reverse_stream_survives_client_half_close(self):
        payload = bytes([0xAB]) * (4 * 1024 * 1024)  # 4 MiB: exceeds socket buffers
        tport, lport = free_port(), free_port()

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", tport))
        listener.listen(1)

        def target():
            conn, _ = listener.accept()
            with conn:
                # Drain the request until the client half-closes (clean EOF via
                # the relay's write_eof), THEN stream the big reverse payload.
                while conn.recv(65536):
                    pass
                try:
                    conn.sendall(payload)
                except OSError:
                    pass  # pre-fix: relay tore the connection, send fails here

        th = threading.Thread(target=target, daemon=True)
        th.start()

        relay = subprocess.Popen(
            [sys.executable, FWD, "--listen-port", str(lport),
             "--target-host", "127.0.0.1", "--target-port", str(tport)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            client = None
            deadline = time.time() + 5
            while time.time() < deadline:
                try:
                    client = socket.create_connection(("127.0.0.1", lport), timeout=1)
                    break
                except OSError:
                    time.sleep(0.1)
            self.assertIsNotNone(client, "relay never started accepting")

            with client:
                client.sendall(b"REQUEST\n")
                client.shutdown(socket.SHUT_WR)  # half-close: client done sending
                client.settimeout(10)
                got = bytearray()
                while True:
                    try:
                        chunk = client.recv(65536)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    got += chunk

            self.assertEqual(
                len(got), len(payload),
                f"reverse stream truncated: got {len(got)} of {len(payload)} bytes "
                f"(the writer.close() half-close bug)",
            )
        finally:
            relay.terminate()
            try:
                relay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay.kill()
            listener.close()


if __name__ == "__main__":
    unittest.main()
