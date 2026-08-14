#!/usr/bin/env python3
"""Harbor: a read-only, loopback-only backlog dashboard (fork-only firstmate feature).

Renders the current tasks-axi backlog as one auto-refreshing HTML page, grouped
the way the captain thinks about it: work in flight, work waiting on him, queued
or blocked work, and a short recent-done tail. It never writes to the backlog or
any fleet state - every group comes straight from `tasks-axi list` output parsed
fresh on each render, so there is no cache and no second backlog format to keep
in sync.

tasks-axi's `list` output is a brace-headed pseudo-CSV: a `tasks[N]{field,...}:`
header line followed by one indented data row per task. Quoting matches neither
Python's csv module default (doubled quotes) nor JSON: a field is double-quoted
only when it needs escaping, and an embedded quote is backslash-escaped, so rows
are parsed with csv.reader(doublequote=False, escapechar="\\").

Two entry points share this one file so the render is defined exactly once:
  render   print the full HTML page for --file's backlog to stdout
  serve    run a loopback HTTP server that calls render() fresh on every request

Usage:
  fm-harbor.py render --file <backlog.md>
  fm-harbor.py serve --file <backlog.md> --port <port> [--ready <path>]
"""

import argparse
import csv
import html
import io
import os
import signal
import subprocess
import sys
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DONE_TAIL = 8
REFRESH_SECONDS = 30
BIND = "127.0.0.1"  # never configurable: loopback-only is a hard safety rule.
TRUNCATION_MARKER = "(truncated,"  # tasks-axi list's at-source title-truncation tag.


class AxiError(Exception):
    """tasks-axi could not be run or returned a non-zero exit."""


def _run_tasks_axi(backlog_file, args):
    try:
        proc = subprocess.run(
            ["tasks-axi", *args, "--file", backlog_file],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except FileNotFoundError as exc:
        raise AxiError("tasks-axi is not installed or not on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise AxiError("tasks-axi did not respond in time") from exc
    if proc.returncode != 0:
        detail = (proc.stdout + proc.stderr).strip() or "unknown error"
        raise AxiError(detail)
    return proc.stdout


def _parse_rows(output):
    """Parse a `tasks[N]{field,...}:` block into a list of field->value dicts.
    A zero-count listing has no such header (just a "tasks: 0 ..." summary
    line), which correctly yields an empty list here."""
    lines = output.splitlines()
    fields = None
    data_lines = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("tasks[") and stripped.endswith(":") and "{" in stripped:
            fields = stripped[stripped.index("{") + 1: stripped.rindex("}")].split(",")
            data_lines = lines[i + 1:]
            break
    if fields is None:
        return []
    rows = []
    for line in data_lines:
        if not line.strip() or line.strip().startswith("help["):
            break
        reader = csv.reader(io.StringIO(line.strip()), doublequote=False, escapechar="\\")
        values = next(reader, [])
        rows.append(dict(zip(fields, values)))
    return rows


def _is_truncated(title):
    return TRUNCATION_MARKER in (title or "")


def _full_title(backlog_file, task_id, cache):
    """The complete title for task_id, fetched once via `show --full` and
    cached: several rows or blocked-by references can name the same id."""
    if task_id in cache:
        return cache[task_id]
    output = _run_tasks_axi(backlog_file, ["show", task_id, "--full"])
    prefix = "  title: "
    title = task_id
    for line in output.splitlines():
        if not line.startswith(prefix):
            continue
        raw = line[len(prefix):]
        if raw.startswith('"'):
            reader = csv.reader(io.StringIO(raw), doublequote=False, escapechar="\\")
            values = next(reader, [raw])
            title = values[0] if values else ""
        else:
            title = raw
        break
    cache[task_id] = title
    return title


def _resolved_title(row, backlog_file, cache):
    """A row's title, with any at-source truncation replaced by the full text."""
    title = row.get("title", "")
    if not _is_truncated(title):
        return title
    try:
        return _full_title(backlog_file, row.get("id", ""), cache)
    except AxiError:
        return title


def _list_tasks(backlog_file, state=None, fields=None, limit=None):
    args = ["list"]
    if state:
        args += ["--state", state]
    if fields:
        args += ["--fields", ",".join(fields)]
    if limit:
        args += ["--limit", str(limit)]
    return _parse_rows(_run_tasks_axi(backlog_file, args))


def _split_ids(value):
    if not value or value == "none" or value == "-":
        return []
    return [v.strip() for v in value.split(",") if v.strip()]


def _pr_url(links_value):
    for entry in _split_ids(links_value):
        if entry.startswith("pr:"):
            return entry[len("pr:"):]
    return None


def _is_captain_held(row):
    return row.get("held") == "yes" and row.get("hold_kind") == "captain"


def _gather_groups(backlog_file):
    """Fetch and group backlog rows via tasks-axi's own read commands only -
    no independent parsing of data/backlog.md itself."""
    id_title = {}
    for row in _list_tasks(backlog_file):
        id_title[row.get("id", "")] = row.get("title", "")

    in_flight = _list_tasks(
        backlog_file, state="in_flight",
        fields=["held", "hold_kind", "hold_reason", "links"],
    )
    held = _list_tasks(
        backlog_file, state="held",
        fields=["hold_kind", "hold_reason", "hold_until", "links", "blocked_by"],
    )
    queued = _list_tasks(
        backlog_file, state="queued",
        fields=["held", "hold_kind", "hold_reason", "hold_until", "blocked_by", "links"],
    )
    done = _list_tasks(
        backlog_file, state="done", fields=["links", "closed"], limit=DONE_TAIL,
    )

    waiting_on_you = [row for row in held if row.get("hold_kind") == "captain"]
    queued_blocked = [row for row in queued if not _is_captain_held(row)]

    return {
        "id_title": id_title,
        "in_flight": in_flight,
        "waiting_on_you": waiting_on_you,
        "queued_blocked": queued_blocked,
        "done": done,
        "backlog_file": backlog_file,
        "full_title_cache": {},
    }


def _esc(value):
    return html.escape(value or "", quote=True)


def _blocked_by_line(row, id_title, backlog_file, cache):
    ids = _split_ids(row.get("blocked_by", ""))
    if not ids:
        return None
    labels = []
    for i in ids:
        title = id_title.get(i, "")
        if _is_truncated(title):
            try:
                title = _full_title(backlog_file, i, cache)
            except AxiError:
                pass
        labels.append(f"{title} ({i})" if title else i)
    return "Blocked by: " + ", ".join(_esc(label) for label in labels)


def _hold_line(row):
    reason = row.get("hold_reason")
    if not reason or reason == "-":
        return None
    until = row.get("hold_until")
    suffix = f" (until {_esc(until)})" if until and until != "-" else ""
    return f"{_esc(reason)}{suffix}"


def _pr_line(row):
    url = _pr_url(row.get("links", ""))
    if not url:
        return None
    safe = _esc(url)
    return f'PR: <a href="{safe}">{safe}</a>'


def _title_html(row, backlog_file, cache):
    raw_title = row.get("title", row.get("id", ""))
    if not _is_truncated(raw_title):
        return _esc(raw_title)
    return _esc(_resolved_title(row, backlog_file, cache))


def _task_card(row, notes, backlog_file, cache):
    title = _title_html(row, backlog_file, cache)
    task_id = _esc(row.get("id", ""))
    repo = _esc(row.get("repo", ""))
    kind = _esc(row.get("kind", ""))
    note_html = "".join(f'<div class="note">{n}</div>' for n in notes if n)
    return (
        '<div class="task">'
        f'<div class="title">{title} <span class="id">{task_id}</span></div>'
        f'<div class="context">{repo} &middot; {kind}</div>'
        f"{note_html}"
        "</div>"
    )


def _section(heading, empty_text, cards, extra_class=""):
    body = "".join(cards) if cards else f'<p class="empty">{_esc(empty_text)}</p>'
    return (
        f'<section class="group {extra_class}">'
        f"<h2>{_esc(heading)}</h2>{body}</section>"
    )


def _render_groups(groups):
    id_title = groups["id_title"]
    backlog_file = groups["backlog_file"]
    cache = groups["full_title_cache"]

    waiting_cards = [
        _task_card(row, [_hold_line(row), _pr_line(row)], backlog_file, cache)
        for row in groups["waiting_on_you"]
    ]
    in_flight_cards = []
    for row in groups["in_flight"]:
        notes = [_pr_line(row)]
        if row.get("held") == "yes" and row.get("hold_kind") != "captain":
            notes.append(_hold_line(row))
        in_flight_cards.append(_task_card(row, notes, backlog_file, cache))
    queued_cards = [
        _task_card(
            row,
            [_blocked_by_line(row, id_title, backlog_file, cache), _hold_line(row)],
            backlog_file, cache,
        )
        for row in groups["queued_blocked"]
    ]
    done_cards = [
        _task_card(row, [_pr_line(row)], backlog_file, cache)
        for row in groups["done"]
    ]

    return "".join([
        _section("Waiting on you", "Nothing waiting on you right now.",
                  waiting_cards, extra_class="waiting"),
        _section("In flight", "Nothing in flight right now.", in_flight_cards),
        _section("Queued / blocked", "The queue is empty.", queued_cards),
        _section("Recently done", "Nothing completed yet.", done_cards),
    ])


PAGE_STYLE = """
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         max-width: 880px; margin: 2rem auto; padding: 0 1.25rem; color: #1b1f24;
         background: #fafafa; }
  h1 { margin-bottom: 0.1rem; }
  .meta { color: #666; margin-top: 0; margin-bottom: 1.75rem; font-size: 0.9rem; }
  section.group { margin-bottom: 2rem; }
  h2 { border-bottom: 1px solid #ddd; padding-bottom: 0.3rem; }
  .waiting { background: #fff6e5; border: 1px solid #f0c766; border-radius: 8px;
             padding: 0.75rem 1rem 0.25rem; }
  .waiting h2 { color: #8a5a00; border-bottom-color: #f0c766; }
  .task { padding: 0.6rem 0; border-bottom: 1px solid #eee; }
  .task:last-child { border-bottom: none; }
  .title { font-weight: 600; }
  .id { font-weight: 400; font-family: ui-monospace, Menlo, monospace;
        font-size: 0.8rem; color: #888; white-space: nowrap; }
  .context { color: #666; font-size: 0.85rem; }
  .note { font-size: 0.9rem; color: #444; margin-top: 0.15rem; }
  .note a { color: #0a5bd6; word-break: break-all; }
  .empty { color: #888; font-style: italic; }
  .error { background: #fde8e8; border: 1px solid #e5a1a1; border-radius: 8px;
           padding: 1rem; color: #7a1f1f; }
"""


def render(backlog_file):
    generated = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    try:
        body = _render_groups(_gather_groups(backlog_file))
    except AxiError as exc:
        body = f'<div class="error">Could not read the backlog: {_esc(str(exc))}</div>'
    return (
        "<!doctype html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        f'<meta http-equiv="refresh" content="{REFRESH_SECONDS}">'
        "<title>Harbor</title>"
        f"<style>{PAGE_STYLE}</style></head><body>"
        "<h1>Harbor</h1>"
        f'<p class="meta">Updated {_esc(generated)} &middot; refreshes every {REFRESH_SECONDS}s</p>'
        f"{body}</body></html>\n"
    )


def cmd_render(args):
    sys.stdout.write(render(args.file))
    return 0


def _make_handler(backlog_file):
    class Handler(BaseHTTPRequestHandler):
        server_version = "fm-harbor/1.0"
        timeout = 15

        def do_GET(self):
            path = urlparse(self.path).path
            if path in ("/healthz", "/health"):
                body = b'{"status":"ok"}'
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except BrokenPipeError:
                    pass
                return
            page = render(backlog_file).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(page)
            except BrokenPipeError:
                pass

        def log_message(self, fmt, *args_):
            sys.stderr.write("harbor: " + (fmt % args_) + "\n")

    return Handler


def cmd_serve(args):
    try:
        httpd = ThreadingHTTPServer((BIND, args.port), _make_handler(args.file))
    except OSError as exc:
        sys.stderr.write(f"harbor: cannot bind {BIND}:{args.port}: {exc}\n")
        return 1
    httpd.daemon_threads = True

    def _shutdown(_signum, _frame):
        if args.ready and os.path.exists(args.ready):
            try:
                os.remove(args.ready)
            except OSError:
                pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    if args.ready:
        try:
            with open(args.ready, "w", encoding="utf-8") as fh:
                fh.write(f"{BIND}:{args.port}\n")
        except OSError:
            pass
    sys.stderr.write(f"harbor: listening on {BIND}:{args.port}\n")
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
        if args.ready and os.path.exists(args.ready):
            try:
                os.remove(args.ready)
            except OSError:
                pass
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-harbor.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_render = sub.add_parser("render", help="print the HTML page to stdout")
    p_render.add_argument("--file", required=True, help="path to the backlog markdown file")
    p_render.set_defaults(func=cmd_render)

    p_serve = sub.add_parser("serve", help="run the loopback HTTP server")
    p_serve.add_argument("--file", required=True, help="path to the backlog markdown file")
    p_serve.add_argument("--port", type=int, required=True)
    p_serve.add_argument("--ready", default="", help="path to touch once bound and listening")
    p_serve.set_defaults(func=cmd_serve)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
