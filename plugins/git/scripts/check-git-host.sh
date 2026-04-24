#!/usr/bin/env bash
# PreToolUse hook: block `gh` in Forgejo repos and `fj` in GitHub repos.
#
# Reads the tool-call JSON on stdin. If the command invokes `gh` or `fj` on a
# repo-scoped subcommand (issue/pr/release/repo) and the CLI disagrees with the
# repo's origin host, exit 2 with a message on stderr — Claude sees that and
# retries with the correct tool.
#
# Conservative by design: only blocks on a clear mismatch. If jq isn't
# installed, there's no git repo in cwd, or the origin is neither GitHub nor
# obviously-Forgejo, the hook gets out of the way.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[[ "$tool_name" == "Bash" ]] || exit 0

command_line="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[[ -n "$command_line" ]] || exit 0

# Match `gh` / `fj` at a shell-word boundary, optionally followed by flags,
# then a repo-scoped subcommand. Deliberately generous — false positives here
# just mean we look up the origin unnecessarily.
subcommand_re='(issue|pr|pull|pull-request|release|repo)'
flag_re='([[:space:]]+-[^[:space:]]+(=[^[:space:]]+)?)*'
boundary='(^|[^A-Za-z0-9_-])'

gh_re="${boundary}gh${flag_re}[[:space:]]+${subcommand_re}([[:space:]]|$)"
fj_re="${boundary}fj${flag_re}[[:space:]]+${subcommand_re}([[:space:]]|$)"

uses_gh=false
uses_fj=false
printf '%s' "$command_line" | grep -qE "$gh_re" && uses_gh=true
printf '%s' "$command_line" | grep -qE "$fj_re" && uses_fj=true

$uses_gh || $uses_fj || exit 0

repo_dir="${cwd:-$PWD}"
origin_url="$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true)"
[[ -n "$origin_url" ]] || exit 0

# Classify. Anything that isn't GitHub/GitLab/Bitbucket we treat as Forgejo —
# codeberg.org, self-hosted instances, etc. GitLab/Bitbucket get a pass because
# neither `gh` nor `fj` applies there.
case "$origin_url" in
  *github.com*)   host=github ;;
  *gitlab.*|*bitbucket.*) exit 0 ;;
  *)              host=forgejo ;;
esac

if $uses_gh && [[ "$host" == "forgejo" ]]; then
  cat >&2 <<EOF
[git plugin] Blocked: this command uses 'gh' (GitHub CLI), but the repo's
origin is:
  $origin_url
That's a Forgejo instance, not GitHub. Use 'fj' (forgejo-cli) instead. The
forgejo-issue and forgejo-pr skills cover the syntax.
EOF
  exit 2
fi

if $uses_fj && [[ "$host" == "github" ]]; then
  cat >&2 <<EOF
[git plugin] Blocked: this command uses 'fj' (Forgejo CLI), but the repo's
origin is:
  $origin_url
That's a GitHub repo. Use 'gh' instead.
EOF
  exit 2
fi

exit 0
