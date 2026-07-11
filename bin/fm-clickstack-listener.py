#!/usr/bin/env python3
"""ClickStack + BetterStack webhook receiver listener (fork-only firstmate feature).

A small, dependency-light HTTP listener that accepts alert/status webhooks and
persists each accepted payload to the firstmate state inbox. It never contacts
the supervisor directly: surfacing to firstmate is done later, and decoupled, by
the watcher's check-shim polls (bin/fm-clickstack-poll.sh, bin/fm-betterstack-poll.sh)
enqueuing through the existing durable wake queue. Because the only per-request
work is a fast local atomic file write, a slow or absent supervisor can never
block or delay a webhook sender's delivery.

Two independent integrations share this one process and port:
  - ClickStack alerts, on any path other than /betterstack (the original,
    unchanged behavior; see docs/clickstack-webhook.md).
  - BetterStack status-page subscription webhooks, on /betterstack only, with a
    URL-query token instead of a header (BetterStack subscriptions cannot send
    custom headers; see docs/betterstack-webhook.md).
They share the process because the captain's reverse proxy forwards the whole
host to one port, so a second listener on a different port would be unreachable
without an out-of-repo proxy change. Each integration is independently gated by
its own CSHOOK_ENABLED / BSHOOK_ENABLED flag, set by the launcher from its own
gate file's presence (bin/fm-clickstack-recv.sh); a disabled integration's route
answers 404 regardless of the other's state.

Language choice (justified in the PR): Python 3 stdlib http.server with
ThreadingHTTPServer. It is a robust, zero-dependency long-running daemon - no
package manager, no lockfile, no vendored modules to review - and threading gives
concurrent request handling for free so a burst of alerts is served in parallel.
The listener is fronted by the captain's reverse proxy, which keeps http.server's
threat surface appropriate for internal single-tenant use.

Config is passed in by the launcher (bin/fm-clickstack-recv.sh) via environment:
  CSHOOK_BIND            bind address (default 127.0.0.1)
  CSHOOK_PORT            listen port (default 8092)
  CSHOOK_ENABLED         "1" iff the ClickStack gate is present (default "1")
  CSHOOK_SECRET          optional shared secret; empty disables secret checks
  CSHOOK_SECRET_HEADER   header carrying the secret (default X-ClickStack-Secret)
  CSHOOK_INBOX           inbox directory for accepted ClickStack payloads (required)
  CSHOOK_READY           path to touch once bound and listening (optional)
  CSHOOK_MAX_BODY        max accepted body bytes, shared by both routes (default 1048576)
  BSHOOK_ENABLED         "1" iff the BetterStack gate is present (default "0")
  BSHOOK_TOKEN           required token for the /betterstack route; empty rejects all
  BSHOOK_INBOX           inbox directory for accepted BetterStack payloads
"""

import hmac
import json
import os
import re
import signal
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BIND = os.environ.get("CSHOOK_BIND", "0.0.0.0")
try:
    PORT = int(os.environ.get("CSHOOK_PORT", "8111"))
except ValueError:
    PORT = 8092
CSHOOK_ENABLED = os.environ.get("CSHOOK_ENABLED", "1") == "1"
SECRET = os.environ.get("CSHOOK_SECRET", "")
SECRET_HEADER = os.environ.get("CSHOOK_SECRET_HEADER", "X-ClickStack-Secret")
INBOX = os.environ.get("CSHOOK_INBOX", "")
READY = os.environ.get("CSHOOK_READY", "")
try:
    MAX_BODY = int(os.environ.get("CSHOOK_MAX_BODY", "1048576"))
except ValueError:
    MAX_BODY = 1048576

BSHOOK_ENABLED = os.environ.get("BSHOOK_ENABLED", "0") == "1"
BSHOOK_TOKEN = os.environ.get("BSHOOK_TOKEN", "")
BSHOOK_INBOX = os.environ.get("BSHOOK_INBOX", "")
BSHOOK_ROUTE_PATH = "/betterstack"

# Candidate identifier fields, in priority order. When a webhook carries one, the
# inbox filename is derived from it so a ClickStack redelivery of the same alert
# atomically overwrites its prior file instead of piling up duplicates - the
# idempotency requirement. Payloads with none fall back to a unique time+counter
# name, so distinct alerts never collide.
ID_FIELDS = ("alertId", "alert_id", "incidentId", "incident_id", "groupKey",
             "group_key", "id", "fingerprint", "dedupKey", "dedup_key")

_SLUG_RE = re.compile(r"[^A-Za-z0-9._-]+")
_counter = 0
_counter_lock = threading.Lock()


def _next_seq():
    """Monotonic per-process sequence, safe across the threaded server."""
    global _counter
    with _counter_lock:
        _counter += 1
        return _counter


def _slug(value):
    """Sanitize an arbitrary id into a safe, bounded inbox filename stem."""
    s = _SLUG_RE.sub("-", str(value)).strip("-.")
    return s[:96] if s else ""


def _derive_id(raw):
    """Return a stable id slug for a payload, or '' when none is present."""
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return ""
    if not isinstance(obj, dict):
        return ""
    for key in ID_FIELDS:
        if key in obj and obj[key] not in (None, ""):
            slug = _slug(obj[key])
            if slug:
                return slug
    # ClickStack nests some ids one level down (e.g. {"alert": {"id": ...}}).
    for parent in ("alert", "incident"):
        child = obj.get(parent)
        if isinstance(child, dict):
            for key in ("id", "alertId", "alert_id"):
                if child.get(key) not in (None, ""):
                    slug = _slug(child[key])
                    if slug:
                        return "%s-%s" % (_slug(parent), slug)
    return ""


def _inbox_name(raw, seq):
    stem = _derive_id(raw)
    if stem:
        return "alert-%s.json" % stem
    return "alert-%d-%06d.json" % (time.time_ns(), seq)


# BetterStack status-page webhooks carry event_type "incident", "maintenance",
# or "component_update", each with its own nested id object. Deduping on that
# id (per BetterStack's own docs) means a re-fired update to an in-progress
# incident lands as the SAME file, overwritten in place with the latest full
# state (each delivery's incident_updates/maintenance_updates array is the
# complete history to date, so the newest payload is always a superset).
_BS_EVENT_ID_PATH = {
    "incident": "incident",
    "maintenance": "maintenance",
    "component_update": "component_update",
}


def _derive_betterstack_id(raw):
    """Return an "<event_type>-<id>" slug for a BetterStack payload, or ''."""
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return ""
    if not isinstance(obj, dict):
        return ""
    event_type = obj.get("event_type")
    parent_key = _BS_EVENT_ID_PATH.get(event_type)
    if parent_key:
        child = obj.get(parent_key)
        if isinstance(child, dict) and child.get("id") not in (None, ""):
            slug = _slug(child["id"])
            if slug:
                return "%s-%s" % (_slug(event_type), slug)
    # An unrecognized event_type still dedupes on a top-level id if present.
    if obj.get("id") not in (None, ""):
        slug = _slug(obj["id"])
        if slug:
            return slug
    return ""


def _betterstack_inbox_name(raw, seq):
    stem = _derive_betterstack_id(raw)
    if stem:
        return "event-%s.json" % stem
    return "event-%d-%06d.json" % (time.time_ns(), seq)


def _write_inbox(inbox_dir, raw_bytes, name_fn):
    """Atomically persist the raw payload to inbox_dir; return the basename."""
    seq = _next_seq()
    name = name_fn(raw_bytes.decode("utf-8", "replace"), seq)
    final = os.path.join(inbox_dir, name)
    tmp = "%s.tmp.%d.%d.%s" % (final, os.getpid(), seq, os.urandom(4).hex())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, raw_bytes)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, final)  # atomic; a same-id redelivery overwrites in place
    return name


def _secret_ok(handler):
    if not SECRET:
        return True
    supplied = handler.headers.get(SECRET_HEADER, "")
    if not supplied:
        # Also accept the secret as a query parameter, for proxies that cannot
        # inject a custom header.
        qs = parse_qs(urlparse(handler.path).query)
        vals = qs.get("secret") or qs.get("token")
        supplied = vals[0] if vals else ""
    # Constant-time comparison to avoid leaking the secret through timing.
    return hmac.compare_digest(str(supplied), str(SECRET))


def _betterstack_token_ok(handler):
    # No safe empty default: BetterStack status-page webhook subscriptions
    # cannot deliver a custom header, so the URL token is the only guard. An
    # unset token (not yet generated, or the route disabled) rejects everyone.
    if not BSHOOK_TOKEN:
        return False
    qs = parse_qs(urlparse(handler.path).query)
    vals = qs.get("token")
    supplied = vals[0] if vals else ""
    return hmac.compare_digest(str(supplied), str(BSHOOK_TOKEN))


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-clickstack/1.0"
    # Drop a stalled/slow-loris connection instead of pinning a server thread.
    timeout = 15

    def _reply(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_GET(self):
        # Liveness probe used by the launcher/arm to confirm the port is serving.
        path = urlparse(self.path).path
        if path in ("/healthz", "/health"):
            self._reply(HTTPStatus.OK, {"status": "ok"})
        else:
            self._reply(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def _read_body(self):
        """Read and bound-check the request body, replying and returning None
        on any error so callers can just check for None and stop."""
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0:
            self._reply(HTTPStatus.BAD_REQUEST, {"error": "bad content-length"})
            return None
        if length > MAX_BODY:
            self._reply(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "payload too large"})
            return None
        raw = self.rfile.read(length) if length else b""
        if not raw:
            self._reply(HTTPStatus.BAD_REQUEST, {"error": "empty body"})
            return None
        return raw

    def do_POST(self):
        path = urlparse(self.path).path
        if path in (BSHOOK_ROUTE_PATH, BSHOOK_ROUTE_PATH + "/"):
            self._handle_betterstack()
        else:
            self._handle_clickstack()

    def _handle_clickstack(self):
        if not CSHOOK_ENABLED:
            self._reply(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if not _secret_ok(self):
            self._reply(HTTPStatus.UNAUTHORIZED, {"error": "invalid or missing secret"})
            return
        raw = self._read_body()
        if raw is None:
            return
        try:
            name = _write_inbox(INBOX, raw, _inbox_name)
        except OSError as exc:
            # A persist failure must be a hard error: never ack an alert we did
            # not durably store, or ClickStack would consider it delivered.
            self.log_error("inbox write failed: %s", exc)
            self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "cannot persist payload"})
            return
        # 202 Accepted: the alert is safely on disk; firstmate is woken later and
        # asynchronously by the watcher poll, decoupled from this response.
        self._reply(HTTPStatus.ACCEPTED, {"status": "accepted", "inbox": name})

    def _handle_betterstack(self):
        if not BSHOOK_ENABLED:
            self._reply(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if not _betterstack_token_ok(self):
            self._reply(HTTPStatus.UNAUTHORIZED, {"error": "invalid or missing token"})
            return
        raw = self._read_body()
        if raw is None:
            return
        try:
            name = _write_inbox(BSHOOK_INBOX, raw, _betterstack_inbox_name)
        except OSError as exc:
            # Same durability requirement as ClickStack: never ack an event we
            # did not persist, or BetterStack would consider it delivered and
            # not retry.
            self.log_error("inbox write failed: %s", exc)
            self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "cannot persist payload"})
            return
        # Any 2xx satisfies BetterStack's delivery contract; 202 matches the
        # ClickStack route and signals the same "durably queued, not yet acted
        # on" semantics.
        self._reply(HTTPStatus.ACCEPTED, {"status": "accepted", "inbox": name})

    def log_message(self, fmt, *args):
        # Quiet by default; the daemon's stdout/stderr is captured by the arm.
        sys.stderr.write("clickstack-listener: " + (fmt % args) + "\n")


def _install_signal_handlers(httpd):
    def _shutdown(_signum, _frame):
        try:
            if READY and os.path.exists(READY):
                os.remove(READY)
        except OSError:
            pass
        # Raise out of serve_forever's poll loop (this handler runs on the main
        # thread) so the finally-block below shuts the server down cleanly.
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)


def main():
    if not INBOX:
        sys.stderr.write("clickstack-listener: CSHOOK_INBOX not set\n")
        return 2
    os.makedirs(INBOX, exist_ok=True)
    if BSHOOK_ENABLED:
        if not BSHOOK_INBOX:
            sys.stderr.write("clickstack-listener: BSHOOK_INBOX not set\n")
            return 2
        os.makedirs(BSHOOK_INBOX, exist_ok=True)
    try:
        httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    except OSError as exc:
        sys.stderr.write("clickstack-listener: cannot bind %s:%d: %s\n" % (BIND, PORT, exc))
        return 1
    httpd.daemon_threads = True
    _install_signal_handlers(httpd)
    if READY:
        try:
            with open(READY, "w", encoding="utf-8") as fh:
                fh.write("%s:%d\n" % (BIND, PORT))
        except OSError:
            pass
    sys.stderr.write("clickstack-listener: listening on %s:%d\n" % (BIND, PORT))
    try:
        httpd.serve_forever(poll_interval=0.5)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        try:
            httpd.shutdown()
        except Exception:
            pass
        httpd.server_close()
        try:
            if READY and os.path.exists(READY):
                os.remove(READY)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
