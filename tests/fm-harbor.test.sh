#!/usr/bin/env bash
# Behavior tests for Harbor, the read-only loopback backlog dashboard
# (bin/fm-harbor.sh / bin/fm-harbor.py; fork-only firstmate feature).
#
# Render-path tests build a real backlog through tasks-axi's own CLI (never a
# second hand-rolled backlog parser) and assert the four captain-facing groups
# render correctly, including the harder cases: a captain hold's reason, a
# non-captain hold staying out of the prominent group, a blocked-by id
# resolved to the blocker's title, a full bare PR URL, and HTML-escaping of
# special characters in a title.
#
# Live-server tests bind an ephemeral loopback port (retried) and drive it
# with a real curl, so the HTTP response, the auto-refresh tag, reflecting a
# live backlog change with no restart, and the singleton lock are all
# exercised end to end. curl, python3, and tasks-axi are the real host tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

HARBOR_SH="$ROOT/bin/fm-harbor.sh"
HARBOR_PY="$ROOT/bin/fm-harbor.py"
TMP_ROOT=$(fm_test_tmproot fm-harbor-tests)

hb_alive() { kill -0 "$1" 2>/dev/null; }

SERVE_PIDS=()
hb_cleanup() {
  local pid
  for pid in "${SERVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap hb_cleanup EXIT

hb_home() {  # <name>: fresh FM_HOME with the dirs fm-harbor.sh expects
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

axi() {  # <backlog-file> <tasks-axi args...>
  local file=$1
  shift
  tasks-axi "$@" --file "$file" >/dev/null
}

# hb_fixture_backlog <backlog-file>: one task per render group, plus the
# harder CSV/grouping cases - an embedded quote+comma in a title, a captain
# hold, a non-captain hold, a multi-field blocked-by resolution, and a PR link.
hb_fixture_backlog() {
  local f=$1
  axi "$f" add flight-a "Ship the widget" --kind ship --repo demo --start
  axi "$f" add held-captain-a 'Needs a "yes" from you, captain' --kind ship --repo demo --queue
  axi "$f" hold held-captain-a --reason "captain decision pending on rollout window" --kind captain
  axi "$f" add held-other-a "Waiting on an external release" --kind ship --repo demo --queue
  axi "$f" hold held-other-a --reason "blocked on upstream vendor patch" --kind external
  axi "$f" add queued-plain-a "Plain queued item" --kind ship --repo demo --queue
  axi "$f" add blocked-a "Needs flight-a first" --kind ship --repo demo --queue
  axi "$f" block blocked-a --by flight-a
  axi "$f" add done-a "Ship it" --kind ship --repo demo --queue
  axi "$f" "done" done-a --pr https://github.com/example/demo/pull/7
}

# hb_section <html> <start-heading> <end-heading>: substring between two
# "<h2>...</h2>" markers, so a group assertion cannot pass by matching text
# that actually landed in a different section.
hb_section() {
  local html=$1 start=$2 end=$3 rest
  rest=${html#*"$start"}
  [ -z "$end" ] || rest=${rest%%"$end"*}
  printf '%s' "$rest"
}

test_render_groups_by_captain_priority() {
  local home f html waiting in_flight queued
  home=$(hb_home render-groups)
  f="$home/data/backlog.md"
  hb_fixture_backlog "$f"

  html=$(python3 "$HARBOR_PY" render --file "$f")

  waiting=$(hb_section "$html" '<h2>Waiting on you</h2>' '<h2>In flight</h2>')
  assert_contains "$waiting" "Needs a &quot;yes&quot; from you, captain" \
    "captain-held title must render escaped in Waiting on you"
  assert_contains "$waiting" "captain decision pending on rollout window" \
    "captain hold reason must render as recorded"
  assert_not_contains "$waiting" "Waiting on an external release" \
    "a non-captain hold must not land in the captain-prominent group"

  in_flight=$(hb_section "$html" '<h2>In flight</h2>' '<h2>Queued / blocked</h2>')
  assert_contains "$in_flight" "Ship the widget" "in-flight task must render"

  queued=$(hb_section "$html" '<h2>Queued / blocked</h2>' '<h2>Recently done</h2>')
  assert_contains "$queued" "Plain queued item" "plain queued task must render"
  assert_contains "$queued" "Waiting on an external release" \
    "a non-captain hold must render in the queued/blocked group"
  assert_contains "$queued" "blocked on upstream vendor patch" \
    "non-captain hold reason must render as recorded"
  assert_contains "$queued" "Blocked by:" "a blocked task must show a blocked-by note"
  assert_contains "$queued" "Ship the widget" \
    "blocked-by must resolve the blocker id to its title"

  assert_contains "$html" "Recently done" "done tail heading must render"
  assert_contains "$html" \
    '<a href="https://github.com/example/demo/pull/7">https://github.com/example/demo/pull/7</a>' \
    "a PR link must render as the full bare URL, not shorthand"

  pass "render groups the backlog by captain priority with correct escaping and resolution"
}

test_render_is_read_only() {
  local home f before after
  home=$(hb_home read-only)
  f="$home/data/backlog.md"
  hb_fixture_backlog "$f"
  before=$(cksum "$f")

  python3 "$HARBOR_PY" render --file "$f" >/dev/null

  after=$(cksum "$f")
  [ "$before" = "$after" ] || fail "render must never modify the backlog file"
  pass "render never mutates the backlog file"
}

test_render_handles_missing_backlog() {
  local home html
  home=$(hb_home no-backlog)
  html=$(python3 "$HARBOR_PY" render --file "$home/data/backlog.md")
  assert_contains "$html" "Nothing in flight right now." "an absent backlog must render as empty, not error"
  assert_contains "$html" "Nothing waiting on you right now." "an absent backlog must render as empty, not error"
  assert_contains "$html" "The queue is empty." "an absent backlog must render as empty, not error"
  assert_contains "$html" "Nothing completed yet." "an absent backlog must render as empty, not error"
  pass "render handles a backlog file that does not exist yet"
}

test_loopback_only_and_no_extra_knobs() {
  assert_grep 'BIND = "127.0.0.1"' "$HARBOR_PY" "the listener bind address must be the hardcoded loopback constant"
  assert_no_grep '"0.0.0.0"' "$HARBOR_PY" "no code path may bind a public interface"
  local serve_help
  serve_help=$(python3 "$HARBOR_PY" serve --help 2>&1)
  assert_not_contains "$serve_help" "--bind" "serve must expose no bind knob, only --port"
  pass "harbor binds loopback only and exposes no bind configuration"
}

hb_free_port() {  # echoes a free-ish ephemeral port
  echo $(( 20000 + (RANDOM % 20000) ))
}

hb_start_serve() {  # <home> [port]: starts fm-harbor.sh serve; echoes "<pid> <port>"
  local home=$1 port=${2:-} ready pid
  ready="$home/state/.harbor.ready"
  for _ in 1 2 3 4 5; do
    port=${2:-$(hb_free_port)}
    rm -f "$ready"
    FM_HOME="$home" "$HARBOR_SH" serve --port "$port" >"$home/serve.out" 2>&1 &
    pid=$!
    local i=0
    while [ "$i" -lt 40 ]; do
      [ -f "$ready" ] && { SERVE_PIDS+=("$pid"); printf '%s %s\n' "$pid" "$port"; return 0; }
      hb_alive "$pid" || break
      sleep 0.1
      i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -n "${2:-}" ] && break  # an explicit port is not worth retrying past
  done
  fail "harbor server never bound a port after retries"$'\n'"$(cat "$home/serve.out" 2>/dev/null)"
}

hb_stop_serve() {  # <pid>
  local pid=$1
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ] && hb_alive "$pid"; do sleep 0.1; i=$((i + 1)); done
}

test_serve_reflects_live_changes_with_no_restart() {
  local home f pid port body queued_before done_section
  home=$(hb_home serve-live)
  f="$home/data/backlog.md"
  hb_fixture_backlog "$f"

  read -r pid port < <(hb_start_serve "$home")

  body=$(curl -s "http://127.0.0.1:$port/")
  assert_contains "$body" 'meta http-equiv="refresh" content="30"' "the page must carry a client auto-refresh tag"
  queued_before=$(hb_section "$body" '<h2>Queued / blocked</h2>' '<h2>Recently done</h2>')
  assert_contains "$queued_before" "Plain queued item" "the queued item must render before it ships"
  done_section=$(hb_section "$body" '<h2>Recently done</h2>' '')
  assert_not_contains "$done_section" "Plain queued item" "the queued item must not already read as done"

  axi "$f" "done" queued-plain-a --note "shipped during the live test"

  body=$(curl -s "http://127.0.0.1:$port/")
  done_section=$(hb_section "$body" '<h2>Recently done</h2>' '')
  assert_contains "$done_section" "Plain queued item" \
    "a task completed via tasks-axi must move to Recently done on the next request, with no restart"

  hb_stop_serve "$pid"
  hb_alive "$pid" && fail "harbor server must exit on TERM"
  assert_absent "$home/state/.harbor.ready" "the ready marker must be removed on shutdown"
  pass "the server re-reads the backlog fresh on every request and shuts down cleanly"
}

test_start_status_stop_and_singleton() {
  local home port out
  home=$(hb_home start-stop)
  hb_fixture_backlog "$home/data/backlog.md"
  port=$(hb_free_port)

  out=$(FM_HOME="$home" "$HARBOR_SH" start --port "$port")
  assert_contains "$out" "harbor: started pid=" "start must report it started"
  assert_contains "$out" "http://127.0.0.1:$port/" "start must print the URL"
  local pid
  pid=$(cat "$home/state/.harbor.lock/pid" 2>/dev/null)
  [ -n "$pid" ] && SERVE_PIDS+=("$pid")

  out=$(FM_HOME="$home" "$HARBOR_SH" status)
  assert_contains "$out" "harbor: running pid=" "status must report running"

  out=$(FM_HOME="$home" "$HARBOR_SH" start --port "$port")
  assert_contains "$out" "already running" "a second start must not open a second server"

  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/healthz" | grep -q '^200$' \
    || fail "the running server must answer its health check"

  out=$(FM_HOME="$home" "$HARBOR_SH" stop)
  assert_contains "$out" "harbor: stopped pid=" "stop must report it stopped"

  FM_HOME="$home" "$HARBOR_SH" status >/dev/null 2>&1
  expect_code 1 $? "status after stop"

  pass "start/status/stop lifecycle and the singleton guard behave correctly"
}

test_render_groups_by_captain_priority
test_render_is_read_only
test_render_handles_missing_backlog
test_loopback_only_and_no_extra_knobs
test_serve_reflects_live_changes_with_no_restart
test_start_status_stop_and_singleton
