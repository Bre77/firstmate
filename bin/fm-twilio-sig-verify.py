#!/usr/bin/env python3
"""Validate a STORED Twilio inbound-webhook payload against its signature
(fork-only firstmate feature; see docs/captain-messaging.md "Inbound route").

Used by bin/fm-captain-msg-poll.sh to validate a captain-msg reply relayed by
the alert-router (Teslemetry/tools PR 26): the router holds no Twilio Account
Auth Token and cannot validate a signature itself, so it relays the exact
url/signature/body it received and this validates them downstream, using the
one HMAC-SHA1 implementation in fm_twilio_sig.py (shared with
bin/fm-clickstack-listener.py's direct-webhook path).

Usage:
  fm-twilio-sig-verify.py --url <url> --signature <sig> --body-file <path>
    Auth token read from stdin (never argv/env, mirroring fm-captain-msg.sh's
    secret handling).
  On a valid signature: prints the decoded form fields as one JSON object
  (str->str) to stdout and exits 0.
  On an invalid or unverifiable signature: prints nothing to stdout, a reason
  to stderr, and exits 1.
"""

import argparse
import json
import sys

from fm_twilio_sig import parse_form, twilio_signature_valid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--body-file", required=True)
    args = parser.parse_args()

    auth_token = sys.stdin.read().strip()
    if not auth_token:
        sys.stderr.write("fm-twilio-sig-verify: no auth token on stdin\n")
        return 1

    try:
        with open(args.body_file, "r", encoding="utf-8") as fh:
            raw_body = fh.read()
    except OSError as exc:
        sys.stderr.write("fm-twilio-sig-verify: cannot read --body-file: %s\n" % exc)
        return 1

    form = parse_form(raw_body)
    if not twilio_signature_valid(args.url, form, args.signature, auth_token):
        sys.stderr.write("fm-twilio-sig-verify: signature does not match\n")
        return 1

    json.dump(form, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
