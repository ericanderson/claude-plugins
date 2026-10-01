#!/usr/bin/env bash
# Tests for scripts/forgejo-api.sh. Run: bash plugins/git/tests/forgejo-api.test.sh
#
# Offline: a stub curl on PATH records its argv, environment, and stdin, and a
# fake keys.json lives under a temp HOME. No network, no real token.

set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/forgejo-api.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/forgejo-api-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
unset XDG_DATA_HOME
keysdir="$HOME/Library/Application Support/forgejo-cli.forgejo-cli"
mkdir -p "$keysdir" "$tmp/bin" "$tmp/log"
cat > "$keysdir/keys.json" <<'EOF'
{
  "hosts": {
    "git.example.test": {"type": "Application", "name": "u", "token": "TESTTOKEN"},
    "port.example.test:8443": {"type": "Application", "name": "u", "token": "PORTTOKEN"}
  },
  "aliases": {
    "ssh.example.test:2222": "git.example.test",
    "evil.test": "git.example.test"
  }
}
EOF

# Stub curl: log argv (one per line), env, and stdin; write the response body
# to the -o file and print $STUB_STATUS as the http_code.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
log="$STUB_LOG"
: > "$log/argv"
out=""
prev=""
for a in "$@"; do
  printf '%s\n' "$a" >> "$log/argv"
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
env > "$log/env"
cat > "$log/stdin"
printf '%s' "${STUB_BODY:-[]}" > "$out"
printf '%s' "${STUB_STATUS:-200}"
EOF
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log"

pass=0
fail=0
check() { # check <description> [!] <condition...>
  local desc="$1" ok; shift
  if [ "$1" = "!" ]; then shift; if "$@"; then ok=false; else ok=true; fi
  elif "$@"; then ok=true; else ok=false; fi
  if $ok; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n' "$desc"; fi
}

# run [env assignments…] -- args…  → sets $out, $err, $code; clears the log
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "$tmp/log/"*
  out="$(env ${envs[@]+"${envs[@]}"} "$script" "$@" 2>"$tmp/err")"
  code=$?
  err="$(cat "$tmp/err")"
}
called() { [ -f "$tmp/log/argv" ]; }
argv_has() { grep -qxF -- "$1" "$tmp/log/argv"; }
url() { tail -n 1 "$tmp/log/argv"; }

H=(FORGEJO_HOST=git.example.test FORGEJO_REPO=o/r)

# Happy path and token handling.
run "${H[@]}" -- GET '{repo}/milestones'
check "GET succeeds" [ "$code" -eq 0 ]
check "GET prints body" [ "$out" = "[]" ]
check "-q is curl's first argument" [ "$(head -n 1 "$tmp/log/argv")" = "-q" ]
check "-g disables globbing" argv_has -g
check "URL is built from host and {repo}" [ "$(url)" = "https://git.example.test/api/v1/repos/o/r/milestones" ]
check "token reaches curl on stdin" [ "$(cat "$tmp/log/stdin")" = "Authorization: token TESTTOKEN" ]
check "token not in curl argv" ! grep -q TESTTOKEN "$tmp/log/argv"
check "token not in curl env" ! grep -q TESTTOKEN "$tmp/log/env"
check "token not in output" ! grep -q TESTTOKEN <<<"$out$err"

# The caller's environment can't reconfigure curl.
run "${H[@]}" CURL_HOME="$tmp" XDG_CONFIG_HOME="$tmp" CURL_CA_BUNDLE=/x SSL_CERT_FILE=/x SSL_CERT_DIR=/x -- GET '{repo}'
check "curl env drops CURL_HOME/XDG_CONFIG_HOME/CA overrides" \
  ! grep -qE '^(CURL_HOME|XDG_CONFIG_HOME|CURL_CA_BUNDLE|SSL_CERT_FILE|SSL_CERT_DIR)=' "$tmp/log/env"

# METHOD allowlist.
run "${H[@]}" -- FOO '{repo}'
check "unknown METHOD exits 2" [ "$code" -eq 2 ]
check "unknown METHOD never calls curl" ! called
run "${H[@]}" -- $'GET /x HTTP/1.1\r\nX-Injected: 1\r\nX:' '{repo}'
check "METHOD with CRLF exits 2 without calling curl" eval '[ "$code" -eq 2 ] && ! called'

# JSON_BODY must be JSON; no @file upload.
run "${H[@]}" -- POST '{repo}/issues' '@/etc/hosts'
check "@file body exits 2" [ "$code" -eq 2 ]
check "@file body never calls curl" ! called
run "${H[@]}" -- PATCH '{repo}/issues/1' '{"milestone":3}'
check "JSON body sent with --data-raw" eval 'argv_has --data-raw && argv_has "{\"milestone\":3}"'
check "--data-binary not used" ! argv_has --data-binary

# Host resolution follows fj: aliases, host:port keys, token stays with its host.
run FORGEJO_HOST=evil.test FORGEJO_REPO=o/r -- GET '{repo}'
check "aliased host sends to the alias target, not the alias" [ "$(url)" = "https://git.example.test/api/v1/repos/o/r" ]
run FORGEJO_HOST=nope.test FORGEJO_REPO=o/r -- GET '{repo}'
check "unknown host exits 1 without calling curl" eval '[ "$code" -eq 1 ] && ! called'

git init -q "$tmp/ssh-repo"
git -C "$tmp/ssh-repo" remote add origin ssh://git@ssh.example.test:2222/o/r.git
out="$(cd "$tmp/ssh-repo" && rm -f "$tmp/log/"* && "$script" GET '{repo}' 2>&1)"; code=$?
check "ssh origin with port resolves through the alias" eval '[ "$code" -eq 0 ] && [ "$(url)" = "https://git.example.test/api/v1/repos/o/r" ]'

git init -q "$tmp/port-repo"
git -C "$tmp/port-repo" remote add origin https://port.example.test:8443/o/r.git
out="$(cd "$tmp/port-repo" && rm -f "$tmp/log/"* && "$script" GET '{repo}' 2>&1)"; code=$?
check "https origin keeps its port" eval '[ "$code" -eq 0 ] && [ "$(url)" = "https://port.example.test:8443/api/v1/repos/o/r" ]'
check "https origin with port uses that host's token" [ "$(cat "$tmp/log/stdin")" = "Authorization: token PORTTOKEN" ]

# owner/name must be plain.
run FORGEJO_HOST=git.example.test FORGEJO_REPO=../../x -- GET '{repo}'
check "../ in repo exits 1" eval '[ "$code" -eq 1 ] && ! called'
run FORGEJO_HOST=git.example.test FORGEJO_REPO=o/.. -- GET '{repo}'
check "/.. in repo exits 1" eval '[ "$code" -eq 1 ] && ! called'

# Non-2xx.
run "${H[@]}" STUB_STATUS=404 STUB_BODY='{"message":"nope"}' -- GET '{repo}'
check "non-2xx exits 1" [ "$code" -eq 1 ]
check "non-2xx body goes to stderr" grep -q nope <<<"$err"

# Missing jq.
mkdir -p "$tmp/nojq"
for t in bash env sed cat git mktemp rm; do ln -sf "$(command -v "$t")" "$tmp/nojq/$t"; done
ln -sf "$tmp/bin/curl" "$tmp/nojq/curl"
run "${H[@]}" PATH="$tmp/nojq" -- GET '{repo}'
check "missing jq says so" eval '[ "$code" -eq 1 ] && grep -q "jq is required" <<<"$err"'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
