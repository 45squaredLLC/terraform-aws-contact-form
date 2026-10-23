"""Contact form backend: check the submission, then email it to the site owner.

One POST per form submission (JSON or a plain HTML form post). Steps:
1. A filled-in honeypot field means a bot: answer "ok" and do nothing.
2. Check the fields (email address, required message, length limits).
3. If a Turnstile secret is configured, verify the visitor's token with Cloudflare.
4. Send the message with SES, Reply-To set to the visitor.
5. Optionally keep a copy in DynamoDB.

Only the standard library and boto3 (which the Lambda runtime includes).
"""

import base64
import json
import os
import re
import time
import urllib.parse
import urllib.request
import uuid

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
TO_ADDRESSES = [a.strip() for a in os.environ.get("TO_ADDRESSES", "").split(",") if a.strip()]
FROM_ADDRESS = os.environ.get("FROM_ADDRESS", "")
SUBJECT_PREFIX = os.environ.get("SUBJECT_PREFIX", "New message from your website")
TURNSTILE_PARAM = os.environ.get("TURNSTILE_SECRET_PARAMETER", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "365"))
REDIRECT_URL = os.environ.get("REDIRECT_URL", "")
HONEYPOT_FIELD = os.environ.get("HONEYPOT_FIELD", "website")

TURNSTILE_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
EMAIL_RE = re.compile(r"^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$")
LIMITS = {"name": 200, "email": 254, "phone": 50, "subject": 200, "message": 5000}

_turnstile_secret = None


def handler(event, context):
    form = parse_body(event)
    html_post = "application/x-www-form-urlencoded" in _header(event, "content-type")

    if form.get(HONEYPOT_FIELD):
        return reply(True, "ok", html_post)

    error = validate(form)
    if error:
        return reply(False, error, html_post, status=400)

    if TURNSTILE_PARAM:
        ip = event.get("requestContext", {}).get("http", {}).get("sourceIp", "")
        if not turnstile_ok(form.get("cf-turnstile-response", ""), ip):
            return reply(False, "The spam check failed. Please try again.", html_post, status=400)

    send_email(form)
    if TABLE_NAME:
        save(form)
    return reply(True, "ok", html_post)


def parse_body(event):
    """The form fields as a dict of strings, from JSON or a urlencoded form post."""
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8", "replace")
    if "application/json" in _header(event, "content-type"):
        try:
            data = json.loads(body or "{}")
        except ValueError:
            return {}
        if not isinstance(data, dict):
            return {}
        return {str(k): str(v).strip() for k, v in data.items() if v is not None}
    return {k: v.strip() for k, v in urllib.parse.parse_qsl(body)}


def validate(form):
    """An error message for the visitor, or "" when the form is fine."""
    if not EMAIL_RE.match(form.get("email", "")):
        return "Please enter a valid email address."
    if not form.get("message"):
        return "Please enter a message."
    for field, limit in LIMITS.items():
        if len(form.get(field, "")) > limit:
            return f"The {field} is too long (limit {limit} characters)."
    return ""


def turnstile_ok(token, ip):
    if not token:
        return False
    data = urllib.parse.urlencode({"secret": turnstile_secret(), "response": token, "remoteip": ip})
    try:
        with urllib.request.urlopen(TURNSTILE_URL, data.encode(), timeout=5) as resp:
            return bool(json.load(resp).get("success"))
    except (OSError, ValueError):
        return False


def turnstile_secret():
    """Read once per container from SSM Parameter Store (SecureString)."""
    global _turnstile_secret
    if _turnstile_secret is None:
        ssm = boto3.client("ssm", region_name=REGION)
        param = ssm.get_parameter(Name=TURNSTILE_PARAM, WithDecryption=True)
        _turnstile_secret = param["Parameter"]["Value"]
    return _turnstile_secret


def send_email(form):
    lines = [f"{label}: {form[key]}" for key, label in
             (("name", "Name"), ("email", "Email"), ("phone", "Phone"), ("subject", "Subject"))
             if form.get(key)]
    body = "\n".join(lines) + "\n\n" + form["message"] + "\n\n(Reply to this email to answer them.)\n"
    who = " ".join((form.get("name") or form["email"]).split())  # no line breaks in a subject
    subject = f"{SUBJECT_PREFIX}: {who}"[:200]
    boto3.client("sesv2", region_name=REGION).send_email(
        FromEmailAddress=FROM_ADDRESS,
        Destination={"ToAddresses": TO_ADDRESSES},
        ReplyToAddresses=[form["email"]],
        Content={"Simple": {
            "Subject": {"Data": subject, "Charset": "UTF-8"},
            "Body": {"Text": {"Data": body, "Charset": "UTF-8"}},
        }},
    )


def save(form):
    now = int(time.time())
    item = {k: {"S": form[k]} for k in LIMITS if form.get(k)}
    item["id"] = {"S": str(uuid.uuid4())}
    item["received_at"] = {"N": str(now)}
    item["expires_at"] = {"N": str(now + RETENTION_DAYS * 86400)}
    boto3.client("dynamodb", region_name=REGION).put_item(TableName=TABLE_NAME, Item=item)


def reply(ok, message, html_post, status=200):
    """JSON for fetch() callers; a redirect back to the site for a plain HTML form post."""
    if html_post and REDIRECT_URL:
        sep = "&" if "?" in REDIRECT_URL else "?"
        location = f"{REDIRECT_URL}{sep}{'sent=1' if ok else 'error=' + urllib.parse.quote(message)}"
        return {"statusCode": 303, "headers": {"Location": location}, "body": ""}
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": ok, "message": message}),
    }


def _header(event, name):
    headers = event.get("headers") or {}
    return next((str(v).lower() for k, v in headers.items() if k.lower() == name), "")
