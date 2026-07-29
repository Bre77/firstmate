"""Twilio signed-request validation (fork-only firstmate feature).

The one implementation of Twilio's inbound-webhook signature algorithm
(HMAC-SHA1, keyed by the Account Auth Token, over the exact webhook URL with
every POST parameter sorted-by-key and appended with no delimiters). Two
callers share this module rather than each reimplementing the algorithm:
  - bin/fm-clickstack-listener.py, which validates a request it received
    directly (the direct-webhook path a home that owns its own public URL
    still uses; see docs/captain-messaging.md).
  - bin/fm-twilio-sig-verify.py, a small CLI that validates a signature
    against a STORED payload (url/signature/body) relayed by the alert-router,
    used from bin/fm-captain-msg-poll.sh since the router itself holds no
    Twilio Account Auth Token and cannot validate anything (see
    docs/captain-messaging.md "Inbound route").

Verified against Twilio's own documented canonical test vector (see
docs/captain-messaging.md "Verification").
"""

import hashlib
import hmac
import base64
from urllib.parse import parse_qsl


def twilio_signature_valid(url, form, signature, auth_token):
    """form is a str->str dict of every POST parameter Twilio sent."""
    if not auth_token or not signature or not url:
        return False
    s = url
    for key in sorted(form.keys()):
        s += key + form[key]
    digest = hmac.new(auth_token.encode("utf-8"), s.encode("utf-8"), hashlib.sha1).digest()
    computed = base64.b64encode(digest).decode("utf-8")
    return hmac.compare_digest(computed, signature)


def parse_form(raw_body):
    """Decode a raw application/x-www-form-urlencoded body into a str->str
    dict, keeping blank values (Twilio can send an empty Body)."""
    return dict(parse_qsl(raw_body, keep_blank_values=True))


def strip_channel_prefix(value):
    """Twilio's RCS "From"/"To" are channel-prefixed ("rcs:+<E.164>"); strip
    it before comparing against a plain E.164 configured destination."""
    if value.startswith("rcs:"):
        return value[len("rcs:"):]
    return value
