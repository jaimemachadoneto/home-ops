"""Test the hook script that sends a GitHub push to doco-cd.

A fake doco-cd server records each request. The test checks the path, the body
and the signature, because doco-cd refuses a payload with a wrong signature.
"""
import hashlib
import hmac
import http.server
import os
import subprocess
import tempfile
import threading
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "app", "scripts", "doco-cd-deploy.sh")
SECRET = "test-secret"
BODY = b'{"ref":"refs/heads/main","repository":{"full_name":"x/y"}}\n'


class Recorder(http.server.BaseHTTPRequestHandler):
    calls = []
    status = 202

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        Recorder.calls.append((self.path, dict(self.headers), self.rfile.read(n)))
        self.send_response(Recorder.status)
        self.end_headers()

    def log_message(self, *a):
        pass


class DocoCdDeployTest(unittest.TestCase):
    def setUp(self):
        Recorder.calls = []
        Recorder.status = 202
        self.server = http.server.HTTPServer(("127.0.0.1", 0), Recorder)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.dir = tempfile.TemporaryDirectory()
        self.payload = os.path.join(self.dir.name, "payload")
        with open(self.payload, "wb") as f:
            f.write(BODY)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def run_script(self, **env):
        e = {"PATH": os.environ["PATH"], "DOCO_CD_URL": "http://127.0.0.1:%d" % self.server.server_port,
             "DOCO_CD_WEBHOOK_SECRET": SECRET, "PAYLOAD_FILE": self.payload}
        e.update(env)
        e = {k: v for k, v in e.items() if v is not None}
        return subprocess.run(["sh", SCRIPT], env=e, capture_output=True, text=True, timeout=60)

    def test_posts_to_each_target_with_the_same_body(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([c[0] for c in Recorder.calls],
                         ["/v1/webhook/embeddings", "/v1/webhook/ai-host", "/v1/webhook/ai-host-extra"])
        for _, _, body in Recorder.calls:
            self.assertEqual(body, BODY)

    def test_signs_the_body_with_the_secret_of_doco_cd(self):
        self.run_script()
        want = "sha256=" + hmac.new(SECRET.encode(), BODY, hashlib.sha256).hexdigest()
        for _, headers, _ in Recorder.calls:
            self.assertEqual(headers.get("X-Hub-Signature-256"), want)
            self.assertEqual(headers.get("X-GitHub-Event"), "push")

    def test_fails_when_the_secret_is_missing(self):
        r = self.run_script(DOCO_CD_WEBHOOK_SECRET=None)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(Recorder.calls, [])

    def test_fails_when_the_payload_file_is_missing(self):
        r = self.run_script(PAYLOAD_FILE=os.path.join(self.dir.name, "none"))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(Recorder.calls, [])

    def test_tries_every_target_and_fails_when_doco_cd_refuses(self):
        Recorder.status = 401
        r = self.run_script()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(Recorder.calls), 3)


if __name__ == "__main__":
    unittest.main()
