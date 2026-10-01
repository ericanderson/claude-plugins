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
# stdin, so it never appears in argv, the environment, or output.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi

method="$1"
path="${2#/}"
body="${3:-}"

# Resolve host and owner/name from origin unless overridden. Handles
# ssh://git@host:port/owner/name.git, git@host:owner/name.git, and
# https://host/owner/name.git.
origin="$(git config --get remote.origin.url 2>/dev/null || true)"
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
    origin_repo="${BASH_REMATCH[5]%.git}"
fi
host="${FORGEJO_HOST:-$origin_host}"
repo="${FORGEJO_REPO:-$origin_repo}"
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

# Look the host up directly, then through fj's alias table (e.g. host:port).
jq_token='(.aliases[$h] // $h) as $k | .hosts[$k].token // empty'
if [ -z "$(jq -r --arg h "$host" "$jq_token" "$keys")" ]; then
    echo "ERROR: no fj token for $host in $keys" >&2
    exit 1
fi

resp="$(mktemp "${TMPDIR:-/tmp}/forgejo-api.XXXXXX")"
trap 'rm -f "$resp"' EXIT

curl_args=(-sS -X "$method" -o "$resp" -w '%{http_code}'
    -H @- -H 'Accept: application/json')
if [ -n "$body" ]; then
    curl_args+=(-H 'Content-Type: application/json' --data-binary "$body")
fi

status="$(jq -r --arg h "$host" "\"Authorization: token \" + ($jq_token)" "$keys" \
    | curl "${curl_args[@]}" "https://$host/api/v1/$path")"

if [ "${status:0:1}" != "2" ]; then
    echo "ERROR: $method /api/v1/$path -> HTTP $status" >&2
    cat "$resp" >&2
    echo >&2
    exit 1
fi
cat "$resp"
