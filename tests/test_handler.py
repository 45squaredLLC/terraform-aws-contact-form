"""Unit tests for src/handler.py. No AWS needed: boto3 is replaced with a fake.

Run: python -m unittest discover -s tests
"""

import base64
import importlib
import io
import json
import os
import sys
import types
import unittest
import urllib.parse
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))


class FakeClients:
    """Stands in for boto3: records every call by service."""

    def __init__(self):
        self.calls = {}

    def client(self, service, region_name=None):
        fake = mock.MagicMock()
        fake.get_parameter.return_value = {"Parameter": {"Value": "turnstile-secret"}}
        self.calls.setdefault(service, []).append(fake)
        return fake

    def one(self, service):
        return self.calls[service][-1]


def load(env):
    """Import a fresh copy of the handler with these environment variables."""
    fake = FakeClients()
    sys.modules["boto3"] = types.SimpleNamespace(client=fake.client)
    base = {"TO_ADDRESSES": "owner@example.com", "FROM_ADDRESS": "website@example.com"}
    with mock.patch.dict(os.environ, {**base, **env}, clear=True):
        sys.modules.pop("handler", None)
        module = importlib.import_module("handler")
    return module, fake


def event(fields, content_type="application/json", b64=False):
    if content_type == "application/json":
        body = json.dumps(fields)
    else:
        body = urllib.parse.urlencode(fields)
    if b64:
        body = base64.b64encode(body.encode()).decode()
    return {
        "body": body,
        "isBase64Encoded": b64,
        "headers": {"Content-Type": content_type},
        "requestContext": {"http": {"sourceIp": "203.0.113.9"}},
    }


GOOD = {"name": "Pat", "email": "pat@example.org", "message": "Do you take vintage coats?"}


class HandlerTest(unittest.TestCase):
    def test_sends_email_with_reply_to_visitor(self):
        h, fake = load({})
        res = h.handler(event(GOOD), None)
        self.assertEqual(res["statusCode"], 200)
        self.assertTrue(json.loads(res["body"])["ok"])
        kwargs = fake.one("sesv2").send_email.call_args.kwargs
        self.assertEqual(kwargs["ReplyToAddresses"], ["pat@example.org"])
        self.assertEqual(kwargs["Destination"]["ToAddresses"], ["owner@example.com"])
        self.assertEqual(kwargs["FromEmailAddress"], "website@example.com")
        self.assertIn("Pat", kwargs["Content"]["Simple"]["Subject"]["Data"])
        self.assertIn("vintage coats", kwargs["Content"]["Simple"]["Body"]["Text"]["Data"])

    def test_name_cannot_break_the_subject_line(self):
        h, fake = load({})
        h.handler(event({**GOOD, "name": "Pat\r\nBcc: x@example.com"}), None)
        subject = fake.one("sesv2").send_email.call_args.kwargs["Content"]["Simple"]["Subject"]["Data"]
        self.assertNotIn("\n", subject)
        self.assertNotIn("\r", subject)

    def test_several_recipients(self):
        h, fake = load({"TO_ADDRESSES": "a@example.com, b@example.com"})
        h.handler(event(GOOD), None)
        to = fake.one("sesv2").send_email.call_args.kwargs["Destination"]["ToAddresses"]
        self.assertEqual(to, ["a@example.com", "b@example.com"])

    def test_honeypot_is_dropped_quietly(self):
        h, fake = load({})
        res = h.handler(event({**GOOD, "website": "http://spam.example"}), None)
        self.assertEqual(res["statusCode"], 200)
        self.assertNotIn("sesv2", fake.calls)

    def test_bad_email_is_refused(self):
        h, fake = load({})
        res = h.handler(event({**GOOD, "email": "not-an-address"}), None)
        self.assertEqual(res["statusCode"], 400)
        self.assertIn("email", json.loads(res["body"])["message"])
        self.assertNotIn("sesv2", fake.calls)

    def test_empty_message_is_refused(self):
        h, _ = load({})
        res = h.handler(event({**GOOD, "message": "  "}), None)
        self.assertEqual(res["statusCode"], 400)

    def test_too_long_is_refused(self):
        h, _ = load({})
        res = h.handler(event({**GOOD, "message": "x" * 5001}), None)
        self.assertEqual(res["statusCode"], 400)

    def test_bad_json_is_refused(self):
        h, _ = load({})
        ev = event(GOOD)
        ev["body"] = "{not json"
        self.assertEqual(h.handler(ev, None)["statusCode"], 400)

    def test_urlencoded_and_base64_body(self):
        h, fake = load({})
        res = h.handler(event(GOOD, "application/x-www-form-urlencoded", b64=True), None)
        self.assertEqual(res["statusCode"], 200)
        self.assertIn("sesv2", fake.calls)

    def test_html_post_redirects_when_configured(self):
        h, _ = load({"REDIRECT_URL": "https://example.com/contact/"})
        res = h.handler(event(GOOD, "application/x-www-form-urlencoded"), None)
        self.assertEqual(res["statusCode"], 303)
        self.assertEqual(res["headers"]["Location"], "https://example.com/contact/?sent=1")
        bad = h.handler(event({**GOOD, "email": "x"}, "application/x-www-form-urlencoded"), None)
        self.assertIn("?error=", bad["headers"]["Location"])

    def test_turnstile_required_when_configured(self):
        h, fake = load({"TURNSTILE_SECRET_PARAMETER": "/form/turnstile"})
        res = h.handler(event(GOOD), None)  # no token
        self.assertEqual(res["statusCode"], 400)
        self.assertNotIn("sesv2", fake.calls)

    def test_turnstile_token_verified(self):
        h, fake = load({"TURNSTILE_SECRET_PARAMETER": "/form/turnstile"})
        reply = io.BytesIO(json.dumps({"success": True}).encode())
        with mock.patch.object(h.urllib.request, "urlopen", return_value=reply) as urlopen:
            res = h.handler(event({**GOOD, "cf-turnstile-response": "tok"}), None)
        self.assertEqual(res["statusCode"], 200)
        sent = urllib.parse.parse_qs(urlopen.call_args.args[1].decode())
        self.assertEqual(sent["secret"], ["turnstile-secret"])
        self.assertEqual(sent["remoteip"], ["203.0.113.9"])
        self.assertIn("sesv2", fake.calls)

    def test_turnstile_failure_blocks(self):
        h, fake = load({"TURNSTILE_SECRET_PARAMETER": "/form/turnstile"})
        reply = io.BytesIO(json.dumps({"success": False}).encode())
        with mock.patch.object(h.urllib.request, "urlopen", return_value=reply):
            res = h.handler(event({**GOOD, "cf-turnstile-response": "tok"}), None)
        self.assertEqual(res["statusCode"], 400)
        self.assertNotIn("sesv2", fake.calls)

    def test_turnstile_outage_blocks(self):
        h, _ = load({"TURNSTILE_SECRET_PARAMETER": "/form/turnstile"})
        with mock.patch.object(h.urllib.request, "urlopen", side_effect=OSError("down")):
            res = h.handler(event({**GOOD, "cf-turnstile-response": "tok"}), None)
        self.assertEqual(res["statusCode"], 400)

    def test_stores_copy_when_table_set(self):
        h, fake = load({"TABLE_NAME": "contact", "RETENTION_DAYS": "30"})
        h.handler(event(GOOD), None)
        item = fake.one("dynamodb").put_item.call_args.kwargs["Item"]
        self.assertEqual(item["email"], {"S": "pat@example.org"})
        received = int(item["received_at"]["N"])
        self.assertEqual(int(item["expires_at"]["N"]) - received, 30 * 86400)


if __name__ == "__main__":
    unittest.main()
