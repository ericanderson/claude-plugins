#!/usr/bin/env bash
# Call the Forgejo REST API with the token fj (forgejo-cli) already stores.
# Use for things fj has no command for — milestones, mainly.
#
# Usage:
#   forgejo-api.sh METHOD PATH [JSON_BODY]
#
#   PATH is relative to /api/v1. A literal "{repo}" expands to
#   "repos/<owner>/<name>" for this checkout's origin.
#
# Examples:
#   forgejo-api.sh GET  '{repo}/milestones?state=all'
#   forgejo-api.sh POST '{repo}/milestones' '{"title":"Triage"}'
#   forgejo-api.sh PATCH '{repo}/issues/42' '{"milestone":3}'
#
# Prints the response body on stdout. Exits non-zero (body on stderr) on a
# non-2xx response.
#
# Overrides: FORGEJO_HOST (e.g. git.anderson.haus), FORGEJO_REPO (owner/name).
#
# The token is read from fj's keys file at call time and handed to curl on
# stdin, so it never appears in argv, the environment, or output. curl runs
# with -q (no .curlrc) and without CURL_HOME/XDG_CONFIG_HOME/CA-bundle
# overrides, so the caller's environment can't redirect, trace, or MITM it.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

method="$1"
path="${2#/}"
body="${3:-}"

case "$method" in
    GET|POST|PUT|PATCH|DELETE) ;;
    *) echo "ERROR: METHOD must be GET, POST, PUT, PATCH, or DELETE" >&2; exit 2 ;;
esac

# The body must be JSON. This also rules out curl's @file syntax, which would
# upload a local file.
if [ -n "$body" ] && ! printf '%s' "$body" | jq empty >/dev/null 2>&1; then
    echo "ERROR: JSON_BODY is not valid JSON" >&2
    exit 2
fi

# Resolve host[:port] and owner/name from origin unless overridden. Handles
# ssh://git@host:port/owner/name.git, git@host:owner/name.git, and
# https://host[:port]/owner/name.git.
origin="$(git config --get remote.origin.url 2>/dev/null || true)"
origin_host=""
origin_port=""
origin_repo=""
if [ -z "${FORGEJO_HOST:-}" ] || [ -z "${FORGEJO_REPO:-}" ]; then
    if [ -z "$origin" ]; then
        echo "ERROR: no origin remote; set FORGEJO_HOST and FORGEJO_REPO" >&2
        exit 1
    fi
    re='^([a-z+]+://)?([^@/]+@)?([^:/]+)(:[0-9]+)?[:/](.+)$'
    if [[ ! "$origin" =~ $re ]]; then
        echo "ERROR: can't parse origin '$origin'; set FORGEJO_HOST and FORGEJO_REPO" >&2
        exit 1
    fi
    origin_host="${BASH_REMATCH[3]}"
    origin_port="${BASH_REMATCH[4]}"
    origin_repo="${BASH_REMATCH[5]%.git}"
fi
if [ -n "${FORGEJO_HOST:-}" ]; then
    hostport="$FORGEJO_HOST"
    host="${FORGEJO_HOST%%:*}"
else
    hostport="$origin_host$origin_port"
    host="$origin_host"
fi
repo="${FORGEJO_REPO:-$origin_repo}"

if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "/$repo/" == */./* || "/$repo/" == */../* ]]; then
    echo "ERROR: repo '$repo' is not a plain owner/name" >&2
    exit 1
fi
path="${path//\{repo\}/repos/$repo}"

# fj >= 0.6 keeps keys under forgejo-cli.forgejo-cli; older versions used
# Cyborus.forgejo-cli.
keys=""
for d in "$HOME/Library/Application Support/forgejo-cli.forgejo-cli" \
         "$HOME/Library/Application Support/Cyborus.forgejo-cli" \
         "${XDG_DATA_HOME:-$HOME/.local/share}/forgejo-cli"; do
    if [ -f "$d/keys.json" ]; then keys="$d/keys.json"; break; fi
done
if [ -z "$keys" ]; then
    echo "ERROR: fj keys.json not found; run: fj -H https://$host auth add-token" >&2
    exit 1
fi

# Resolve the instance the way fj does: fj keys tokens by host[:port][/path]
# and maps an instance's SSH host[:port] to its HTTP host through .aliases.
# Try host:port first, then the bare host. The resolved name is used for both
# the token lookup and the request URL, so they can't diverge.
api_host="$(jq -r --arg a "$hostport" --arg b "$host" '
    . as $r
    | [$a, $b] | map($r.aliases[.] // .)
    | map(select($r.hosts[.].token != null)) | first // empty' "$keys")"
if [ -z "$api_host" ]; then
    echo "ERROR: no fj token for $hostport in $keys" >&2
    exit 1
fi

resp="$(mktemp "${TMPDIR:-/tmp}/forgejo-api.XXXXXX")"
trap 'rm -f "$resp"' EXIT

# -q must be first to skip .curlrc; -g turns off URL globbing ([] and {}).
curl_args=(-q -g -sS -X "$method" -o "$resp" -w '%{http_code}'
    -H @- -H 'Accept: application/json')
if [ -n "$body" ]; then
    curl_args+=(-H 'Content-Type: application/json' --data-raw "$body")
fi

status="$(jq -r --arg h "$api_host" '"Authorization: token " + .hosts[$h].token' "$keys" \
    | env -u CURL_HOME -u XDG_CONFIG_HOME -u CURL_CA_BUNDLE -u SSL_CERT_FILE \
          -u SSL_CERT_DIR -u CURL_SSL_BACKEND \
          curl "${curl_args[@]}" "https://$api_host/api/v1/$path")"

if [ "${status:0:1}" != "2" ]; then
    echo "ERROR: $method /api/v1/$path -> HTTP $status" >&2
    cat "$resp" >&2
    echo >&2
    exit 1
fi
cat "$resp"
