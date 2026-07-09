#!/bin/bash
# CI verification for the tab-target-label patch.
#
# herdr tab ids are positional — an id resolved before a concurrent close can
# point at a DIFFERENT tab by the time `tab close <id>` executes, so scripted
# cleanups can kill the wrong tab (and the live process inside it).
#
# Phase 1 reproduces that hazard with stale positional ids.
# Phase 2 verifies the patch: `tab close --label <label>` resolves atomically
# on the server and survives concurrent renumbering. Phase 2 is skipped when
# the binary under test does not support --label (pre-patch builds), and the
# script then exits nonzero via Phase 1 expectations only.
#
# HERDR_BIN overrides the binary under test (default: ~/.local/bin/herdr-real).
# Runs against an ISOLATED herdr server on a private socket — safe to run on
# a machine with a live herdr server.

set -u
SOCK="/tmp/herdr-repro-$$.sock"
export HERDR_SOCKET_PATH="$SOCK"
HERDR="${HERDR_BIN:-$HOME/.local/bin/herdr-real}"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

echo "=== Binary under test: $HERDR ($("$HERDR" --version 2>/dev/null))"
echo "=== Starting isolated herdr server on $SOCK"
"$HERDR" server >/tmp/herdr-repro-server.log 2>&1 &
SERVER_PID=$!
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "FATAL: server socket never appeared"; exit 1; }

hj() { "$HERDR" "$@" 2>/dev/null; }

# Workspace to hold the test tabs
WS_JSON=$(hj workspace create --cwd /tmp --label REPRO)
WS_ID=$(echo "$WS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['tab']['workspace_id'])")
echo "=== Workspace: $WS_ID"

make_tabs() {
  local prefix=$1
  for name in alpha bravo charlie; do
    T=$(hj tab create --workspace "$WS_ID" --label "$prefix-$name" --cwd /tmp)
    TID=$(echo "$T" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['tab']['tab_id'])")
    echo "    created $prefix-$name -> $TID"
  done
}

list_tabs() {
  hj tab list --workspace "$WS_ID" | python3 -c "
import json,sys
for t in json.load(sys.stdin)['result']['tabs']:
    print(f\"    {t['tab_id']}  number={t.get('number')}  label={t['label']}\")"
}

survivors() {
  hj tab list --workspace "$WS_ID" | python3 -c "
import json,sys
print(' '.join(t['label'] for t in json.load(sys.stdin)['result']['tabs']))"
}

resolve_label() {
  hj tab list --workspace "$WS_ID" | python3 -c "
import json,sys
tabs=json.load(sys.stdin)['result']['tabs']
print(next(t['tab_id'] for t in tabs if t['label']=='$1'))"
}

close_label_tabs() {
  local prefix=$1
  for name in alpha bravo charlie; do
    ID=$(hj tab list --workspace "$WS_ID" | python3 -c "
import json,sys
tabs=json.load(sys.stdin)['result']['tabs']
ids=[t['tab_id'] for t in tabs if t['label']=='$prefix-$name']
print(ids[0] if ids else '')")
    [ -n "$ID" ] && hj tab close "$ID" >/dev/null
  done
}

FAIL=0

echo ""
echo "=== PHASE 1: stale positional id (the bug) ==="
make_tabs repro
echo "=== Tabs after creation:"
list_tabs

# Step 1: resolve label 'repro-bravo' -> tab_id (what jfdi cleanup does).
# bravo sits between alpha and charlie, so when alpha closes, charlie slides
# down into bravo's old slot — the stale id then points at charlie.
STALE_ID=$(resolve_label repro-bravo)
echo "=== Resolved repro-bravo -> $STALE_ID (captured BEFORE concurrent close)"

# Step 2: a concurrent close happens (someone else closes repro-alpha)
ALPHA_ID=$(resolve_label repro-alpha)
echo "=== Concurrent event: closing repro-alpha ($ALPHA_ID)"
hj tab close "$ALPHA_ID" >/dev/null
sleep 0.5
echo "=== Tabs after repro-alpha closed:"
list_tabs

# Step 3: cleanup proceeds with its stale id
echo "=== Cleanup executes: tab close $STALE_ID  (believes it is closing repro-bravo)"
hj tab close "$STALE_ID" >/dev/null
sleep 0.5

S1=$(survivors)
echo "=== Survivors: $S1"
if echo "$S1" | grep -q "repro-bravo" && ! echo "$S1" | grep -q "repro-charlie"; then
  echo "PHASE 1 RESULT: BUG REPRODUCED — close($STALE_ID) killed repro-charlie (innocent bystander); repro-bravo (intended target) survived."
elif ! echo "$S1" | grep -q "repro-bravo" && echo "$S1" | grep -q "repro-charlie"; then
  echo "PHASE 1 RESULT: NOT REPRODUCED (stable tab IDs — v0.7.0+ does not renumber after close; stale ID still pointed at bravo and correctly closed it). Root cause moot; --label still valuable as atomic semantic targeting."
else
  echo "PHASE 1 RESULT: UNEXPECTED — survivors: $S1"
  FAIL=1
fi

close_label_tabs repro

echo ""
echo "=== PHASE 2: close by --label (the fix) ==="
# NB: herdr prints error responses to stderr, so capture both streams.
if ! "$HERDR" tab close --label __probe-no-such-tab__ 2>&1 | grep -q "tab_not_found"; then
  echo "PHASE 2 RESULT: FAILED — binary does not support tab close --label (patch missing from build?)"
  exit 1
fi

make_tabs fix
echo "=== Tabs after creation:"
list_tabs

# Same concurrent renumbering, but the cleanup targets the label, resolved
# atomically server-side at close time.
FIX_ALPHA_ID=$(resolve_label fix-alpha)
echo "=== Concurrent event: closing fix-alpha ($FIX_ALPHA_ID)"
hj tab close "$FIX_ALPHA_ID" >/dev/null
sleep 0.5
echo "=== Cleanup executes: tab close --label fix-bravo"
hj tab close --label fix-bravo >/dev/null
sleep 0.5

S2=$(survivors)
echo "=== Survivors: $S2"
if echo "$S2" | grep -q "fix-charlie" && ! echo "$S2" | grep -qw "fix-bravo"; then
  echo "PHASE 2 RESULT: FIX VERIFIED — label close removed fix-bravo (intended target); fix-charlie survived the renumbering."
else
  echo "PHASE 2 RESULT: FIX FAILED — survivors: $S2"
  FAIL=1
fi

# Bonus assertions: not-found and ambiguous labels must error, never close.
NF=$("$HERDR" tab close --label no-such-label-zzz 2>&1)
echo "$NF" | grep -q "tab_not_found" && echo "=== not-found label errors correctly" || { echo "=== FAIL: not-found label did not error: $NF"; FAIL=1; }

hj tab create --workspace "$WS_ID" --label dupe --cwd /tmp >/dev/null
hj tab create --workspace "$WS_ID" --label dupe --cwd /tmp >/dev/null
AMB=$("$HERDR" tab close --label dupe 2>&1)
echo "$AMB" | grep -q "tab_target_ambiguous" && echo "=== ambiguous label errors correctly (no tab closed)" || { echo "=== FAIL: ambiguous label did not error: $AMB"; FAIL=1; }

echo ""
echo "=== PHASE 3: get/focus by --label + positional backward compat ==="
# The patch re-routes get/focus/close through the same parse_tab_target ->
# runtime::tab_* -> Method::Tab* path. PHASE 2 only exercises close, so get and
# focus need direct coverage — a bad rebase can break them while close passes.
make_tabs read

# get --label resolves the intended tab
GB=$(hj tab get --label read-bravo | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['tab']['label'])" 2>/dev/null)
[ "$GB" = "read-bravo" ] && echo "=== get --label read-bravo -> $GB" || { echo "=== FAIL: get --label returned '$GB' (want read-bravo)"; FAIL=1; }

# focus --label resolves and focuses the intended tab
FC=$(hj tab focus --label read-charlie | python3 -c "import json,sys; t=json.load(sys.stdin)['result']['tab']; print(t['label'], t.get('focused'))" 2>/dev/null)
[ "$FC" = "read-charlie True" ] && echo "=== focus --label read-charlie -> $FC" || { echo "=== FAIL: focus --label returned '$FC' (want 'read-charlie True')"; FAIL=1; }

# positional tab_id still works (wire-format backward compat)
RA_ID=$(resolve_label read-alpha)
PA=$(hj tab get "$RA_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['tab']['label'])" 2>/dev/null)
[ "$PA" = "read-alpha" ] && echo "=== positional get $RA_ID -> $PA (backward compat)" || { echo "=== FAIL: positional get returned '$PA' (want read-alpha)"; FAIL=1; }

# get --label with no match errors
GNF=$("$HERDR" tab get --label no-such-label-zzz 2>&1)
echo "$GNF" | grep -q "tab_not_found" && echo "=== get --label not-found errors correctly" || { echo "=== FAIL: get --label not-found did not error: $GNF"; FAIL=1; }

# get with neither tab_id nor label is a usage error (exit 2), never a silent success
"$HERDR" tab get >/dev/null 2>&1; GC=$?
[ "$GC" = "2" ] && echo "=== get with no target exits 2 (usage error)" || { echo "=== FAIL: get with no target exited $GC (want 2)"; FAIL=1; }

close_label_tabs read

exit $FAIL

