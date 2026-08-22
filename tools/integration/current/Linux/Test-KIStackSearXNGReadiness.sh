#!/usr/bin/env bash
# Regression tests for the local, deterministic SearXNG readiness probe
# introduced in diag10 (see install-searxng-payload.sh / diag9 root cause).
#
# This sources the PRODUCTION script's function definitions directly
# (KI_STACK_SEARXNG_READINESS_SELFTEST=1 short-circuits before any install
# step runs) so there is exactly one implementation under test -- nothing
# here is a re-implementation that could drift from what actually ships.
#
# Covers the three regression scenarios required for the diag10 fix:
#   1) external engines unreachable, local SearXNG app up   -> ready
#   2) local SearXNG process/port down                      -> not ready
#   3) some other HTTP app answering on the port             -> not ready
# plus static contract checks that the readiness gate never references
# /search and that the optional functional probe stays separate from it.
#
# Usage: bash Linux/Test-KIStackSearXNGReadiness.sh
# Exit code 0 = all checks passed, 1 = at least one failed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install-searxng-payload.sh"
FIXTURES="$HERE/readiness-selftest-fixtures"

export KI_STACK_SEARXNG_READINESS_SELFTEST=1
# shellcheck source=install-searxng-payload.sh
source "$INSTALLER" dummy dummy dummy dummy
unset KI_STACK_SEARXNG_READINESS_SELFTEST

FAIL=0
note(){ printf 'KI_STACK_READINESS_SELFTEST|%s\n' "$1"; }
assert_true(){ if [ "$1" -eq 0 ]; then note "PASS: $2"; else note "FAIL: $2"; FAIL=1; fi; }

start_server(){ python3 "$1" "$2" >/tmp/ki-stack-readiness-selftest-server.log 2>&1 & echo $!; }
stop_server(){ kill "$1" >/dev/null 2>&1 || true; wait "$1" 2>/dev/null || true; }

# --- Scenario 1: local app healthy; external engines are irrelevant --------
pid="$(start_server "$FIXTURES/real_searxng.py" 18888)"; sleep 1
r=1
if local_http_endpoint_responds 'http://127.0.0.1:18888' && response_is_searxng_app 'http://127.0.0.1:18888'; then r=0; fi
stop_server "$pid"
assert_true "$r" 'local SearXNG app healthy => probe reports ready (no /search call, external engines never contacted)'

# --- Scenario 2: local process/port down ------------------------------------
r=0
local_http_endpoint_responds 'http://127.0.0.1:18889' && r=1
assert_true "$r" 'no listener on the SearXNG port => probe reports not ready'

# --- Scenario 3: wrong HTTP app on the port ---------------------------------
pid="$(start_server "$FIXTURES/wrong_app.py" 18890)"; sleep 1
r=0
if local_http_endpoint_responds 'http://127.0.0.1:18890' && response_is_searxng_app 'http://127.0.0.1:18890'; then r=1; fi
stop_server "$pid"
assert_true "$r" 'non-SearXNG app answering on the port => probe reports not ready (identity check, not just /healthz)'

# --- Static contract: readiness gate never references /search --------------
readiness_block="$(sed -n '/^readiness_probe(){/,/^}/p' "$INSTALLER")"
loop_block="$(sed -n '/^STEP=local-readiness-readback/,/^if \[ "\$READY" -ne 1 \]; then/p' "$INSTALLER")"
r=0
printf '%s%s' "$readiness_block" "$loop_block" | grep -q 'search?q=' && r=1
assert_true "$r" 'readiness gate (readiness_probe + retry loop) never issues a /search request or contacts an external engine'

# --- Static contract: optional functional probe exists, stays separate ----
r=0
grep -q 'optional_search_functional_probe(){' "$INSTALLER" || r=1
total="$(grep -o 'optional_search_functional_probe' "$INSTALLER" | wc -l)"
calls=$((total - 1))  # subtract the one function-definition occurrence
[ "$calls" -eq 2 ] || r=1   # called once on the adopted-existing path, once after the loop on the managed path -- never inside the 60x retry loop
printf '%s' "$loop_block" | grep -q 'optional_search_functional_probe' && r=1
assert_true "$r" 'optional search-functional probe is present, runs once per path, and is not part of the retry loop'

if [ "$FAIL" -eq 0 ]; then
 echo 'KI_STACK_READINESS_SELFTEST|result=all-passed'
 exit 0
fi
echo 'KI_STACK_READINESS_SELFTEST|result=failures-present'
exit 1

