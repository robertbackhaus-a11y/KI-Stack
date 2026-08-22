#!/usr/bin/env bash
set -Eeuo pipefail
PAYLOAD="${1:-}"; MANIFEST="${2:-}"; EXPECTED_SHA="${3:-}"; REVISION="${4:-unknown}"; RELEASE="1.5.10"
ROOT=/opt/ki-stack/searxng; SRC="$ROOT/src"; VENV="$ROOT/venv"; MARKER=/opt/ki-stack/integration/installation.json
STEP=initialize; CAUSE='command failed before an explicit internal cause was recorded'; TMP=''
on_exit(){
 code=$?
 if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
 if [ "$code" -ne 0 ]; then
  printf 'KI_STACK_PAYLOAD_DIAGNOSTIC|step=%s|exitCode=%s|cause=%s|revision=%s|root=%s|src=%s|venv=%s|marker=%s\n' "$STEP" "$code" "$CAUSE" "$REVISION" "$ROOT" "$SRC" "$VENV" "$MARKER" >&2
 fi
}
trap on_exit EXIT

# --- readiness -------------------------------------------------------------
# diag9 root cause: readiness previously executed a REAL /search request.
# SearXNG's /search always fans out to external engines; when those engines
# return 403/timeout, /search itself hangs/slows, and the retry loop (60x)
# saturates the uWSGI listen queue on 127.0.0.1:8888, taking down even plain
# diagnostic curls. The health check caused its own outage.
#
# Fix: readiness is now local-only and deterministic. It never calls
# /search and never depends on any external engine being reachable. It
# proves four things, each locally:
#   1) the uWSGI process is active (systemd)
#   2) the uWSGI port/socket (127.0.0.1:8888) is actually listening
#   3) the local HTTP endpoint answers (SearXNG's own liveness route)
#   4) the answering app is really SearXNG, not some other listener
# Steps 3+4 use SearXNG's built-in /healthz (liveness, returns plain "OK",
# no engine calls) and /config (static instance/engine metadata, also no
# engine calls) routes -- both ship in the pinned upstream revision
# 357662d86dd225bf8f0bfe5cfaa45bed09aef788 (see searx/webapp.py).
PROBE_STATUS=''; PROBE_BODY=''
http_probe(){
 # $1 = full URL. On success sets PROBE_STATUS/PROBE_BODY and returns 0.
 local url="$1" raw
 raw="$(curl --connect-timeout 5 --max-time 10 --silent --show-error -w '\n%{http_code}' "$url" 2>/dev/null)" || return 1
 PROBE_STATUS="${raw##*$'\n'}"
 PROBE_BODY="${raw%$'\n'*}"
 [ -n "$PROBE_STATUS" ]
}
uwsgi_process_active(){ systemctl is-active --quiet uwsgi 2>/dev/null; }
port_socket_present(){ ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':8888$'; }
local_http_endpoint_responds(){ http_probe "$1/healthz" && [ "$PROBE_STATUS" = "200" ]; }
response_is_searxng_app(){
 # PROBE_BODY currently holds the /healthz body from local_http_endpoint_responds.
 [ "$PROBE_BODY" = "OK" ] || return 1
 http_probe "$1/config" || return 1
 [ "$PROBE_STATUS" = "200" ] || return 1
 printf '%s' "$PROBE_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, dict)
assert isinstance(d.get("instance_name"), str)
assert isinstance(d.get("version"), str) and d["version"]
assert isinstance(d.get("engines"), list)
' >/dev/null 2>&1
}
readiness_probe(){
 # $1 = base URL without trailing slash, e.g. http://127.0.0.1/searxng
 # Purely local; never touches /search; never contacts an external engine.
 uwsgi_process_active || { CAUSE='uWSGI process is not active'; return 1; }
 port_socket_present || { CAUSE='SearXNG uWSGI port 8888 is not listening'; return 1; }
 local_http_endpoint_responds "$1" || { CAUSE='local SearXNG /healthz endpoint did not answer with HTTP 200'; return 1; }
 response_is_searxng_app "$1" || { CAUSE='local HTTP endpoint on port 8888 is not the SearXNG application'; return 1; }
 return 0
}
health_diagnostics(){
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=systemctl-status' >&2
 systemctl --no-pager --full status valkey-server uwsgi nginx >&2 2>&1 || true
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=journal' >&2
 journalctl --no-pager -n 120 -u valkey-server -u uwsgi -u nginx >&2 2>&1 || true
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=uwsgi-log' >&2
 tail -n 120 /var/log/uwsgi/app/searxng.log >&2 2>&1 || true
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=listeners' >&2
 ss -ltnp >&2 2>&1 || true
 # Diagnostics use the same local, no-search routes as readiness so a
 # failure investigation cannot itself re-trigger the diag9 queue storm.
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=direct-backend|url=http://127.0.0.1:8888/healthz' >&2
 curl --silent --show-error --max-time 10 --write-out '\nHTTP_STATUS=%{http_code}\n' 'http://127.0.0.1:8888/healthz' >&2 2>&1 || true
 echo 'KI_STACK_HEALTH_DIAGNOSTIC|section=nginx|url=http://127.0.0.1/searxng/healthz' >&2
 curl --silent --show-error --max-time 10 --write-out '\nHTTP_STATUS=%{http_code}\n' 'http://127.0.0.1/searxng/healthz' >&2 2>&1 || true
}
write_marker(){ install -d -m 0750 /opt/ki-stack/integration; python3 - "$MARKER" "$1" <<'PY'
import datetime,json,sys
json.dump({"schemaVersion":"1.0","managedBy":"KI-STACK-INTEGRATION-MANAGED","version":"1.5.10","release":"KI-Stack-Integration-Execute-v1.5.10","mode":sys.argv[2],"installedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"payloadId":"KI-STACK-SEARXNG-SOURCE-2026.6.28"},open(sys.argv[1],"w"),indent=2)
PY
chmod 0640 "$MARKER"; }
optional_search_functional_probe(){
 # Optional FUNCTIONAL test, not an installation readiness gate:
 #  - runs exactly once (never in a retry loop)
 #  - its result never changes the installer's exit code
 #  - a slow/unreachable external engine can therefore never make the
 #    installer itself fail or self-DoS its own listen queue (diag9)
 local out status body
 out="$(curl --connect-timeout 5 --max-time 20 --silent --write-out '\nHTTP_STATUS=%{http_code}' 'http://127.0.0.1/searxng/search?q=ki-stack&format=json' 2>/dev/null)" || true
 status="${out##*$'\n'HTTP_STATUS=}"
 body="${out%$'\n'HTTP_STATUS=*}"
 if [ "$status" = "200" ] && printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, dict) and isinstance(d.get("query"), str) and isinstance(d.get("number_of_results"), (int, float)) and all(isinstance(d.get(k), list) for k in ("results", "answers", "corrections", "infoboxes", "suggestions", "unresponsive_engines"))
' >/dev/null 2>&1; then
  echo 'KI_STACK_OPTIONAL_FUNCTIONAL_PROBE|check=search-api|status=pass' >&2
 else
  echo 'KI_STACK_OPTIONAL_FUNCTIONAL_PROBE|check=search-api|status=unavailable|note=external engines unreachable or slow; does not affect installation readiness' >&2
 fi
}
# Allows Test-KIStackSearXNGReadiness.sh to `source` this file and exercise
# the exact readiness_probe/local_http_endpoint_responds/response_is_searxng_app
# implementation above against mock local servers, with zero duplicated logic
# and without running any installation step.
if [ "${KI_STACK_SEARXNG_READINESS_SELFTEST:-0}" = "1" ]; then
 trap - EXIT
 return 0 2>/dev/null || exit 0
fi

STEP=existing-endpoint-readback
if readiness_probe 'http://127.0.0.1/searxng'; then
 STEP=existing-endpoint-enable
 systemctl enable valkey-server uwsgi nginx
 optional_search_functional_probe; write_marker adopted-existing; exit 0
fi
STEP=payload-sha256
test "$(sha256sum "$PAYLOAD" | cut -d' ' -f1)" = "$EXPECTED_SHA" || { CAUSE='payload SHA256 mismatch'; echo "$CAUSE" >&2; exit 61; }
export DEBIAN_FRONTEND=noninteractive
STEP=operating-system-dependencies
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv python3-pip python3-dev build-essential libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev nginx uwsgi uwsgi-plugin-python3 unzip valkey-server
STEP=payload-extraction
TMP="$(mktemp -d)"
unzip -q "$PAYLOAD" -d "$TMP/src"
STEP=content-manifest-validation
python3 - "$TMP/src" "$MANIFEST" <<'PY'
import hashlib,json,os,sys
root,manifest=sys.argv[1:]; data=json.load(open(manifest,encoding="utf-8")); actual=[]
for item in data["files"]:
 p=os.path.join(root,*item["path"].split("/"));
 if not os.path.isfile(p) or os.path.getsize(p)!=item["sizeBytes"] or hashlib.sha256(open(p,"rb").read()).hexdigest()!=item["sha256"]: actual.append(item["path"])
if actual: raise SystemExit("content mismatch: "+", ".join(actual[:10]))
PY
STEP=source-activation
id -u searxng >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --create-home --shell /usr/sbin/nologin searxng
install -d -o searxng -g searxng "$ROOT"; rm -rf "$SRC"; mv "$TMP/src" "$SRC"; chown -R searxng:searxng "$SRC"
STEP=python-environment
python3 -m venv "$VENV"; "$VENV/bin/python" -m pip install --upgrade pip setuptools wheel; "$VENV/bin/python" -m pip install -r "$SRC/requirements.txt" -r "$SRC/requirements-server.txt"
STEP=service-configuration
install -d /etc/searxng /etc/uwsgi/apps-available /etc/uwsgi/apps-enabled /etc/nginx/default.d
SECRET="$($VENV/bin/python -c 'import secrets;print(secrets.token_urlsafe(48))')"
cat > /etc/searxng/settings.yml <<EOF
use_default_settings: true
search: {formats: [html, json]}
server: {bind_address: "127.0.0.1", port: 8888, secret_key: "$SECRET", base_url: "http://localhost/searxng/"}
valkey: {url: "valkey://localhost:6379/0"}
EOF
cat > /etc/uwsgi/apps-available/searxng.ini <<EOF
[uwsgi]
plugin=python3
chdir=$SRC/searx
module=searx.webapp
callable=app
virtualenv=$VENV
pythonpath=$SRC
env=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
http-socket=127.0.0.1:8888
master=true
processes=2
threads=4
enable-threads=true
vacuum=true
die-on-term=true
EOF
ln -sfn /etc/uwsgi/apps-available/searxng.ini /etc/uwsgi/apps-enabled/searxng.ini
cat > /etc/nginx/default.d/searxng.conf <<'EOF'
location = /searxng { return 301 /searxng/; }
location /searxng { proxy_pass http://127.0.0.1:8888; proxy_set_header X-Script-Name /searxng; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }
EOF
STEP=service-start
systemctl enable valkey-server uwsgi nginx; systemctl restart valkey-server uwsgi nginx
STEP=local-readiness-readback
READY=0
for n in $(seq 1 60); do
 if readiness_probe 'http://127.0.0.1/searxng'; then READY=1; break; fi
 sleep 1
done
if [ "$READY" -ne 1 ]; then
 CAUSE="local SearXNG readiness check failed after 60 attempts (last cause: ${CAUSE})"
 health_diagnostics
 exit 62
fi
optional_search_functional_probe
write_marker managed
exit 0

