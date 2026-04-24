#!/usr/bin/env bash
# SessionStart hook: tell Claude which git host the current repo lives on, so
# it drafts the right CLI (gh vs fj) from the start instead of learning by
# getting blocked by check-git-host.sh.
#
# Emits a SessionStart hookSpecificOutput JSON object with a one-line hint.
# Silent when there's no git repo, or when the host is GitLab/Bitbucket (which
# this plugin doesn't handle).

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="$PWD"

origin_url="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || true)"
[[ -n "$origin_url" ]] || exit 0

case "$origin_url" in
  *github.com*)
    msg="Git host: GitHub ($origin_url). Use \`gh\` for issues/PRs."
    ;;
  *gitlab.*|*bitbucket.*)
    exit 0
    ;;
  *)
    msg="Git host: Forgejo ($origin_url). Use \`fj\` (forgejo-cli) for issues/PRs, not \`gh\`. The forgejo-issue / forgejo-pr skills cover the syntax."
    ;;
esac

jq -n --arg msg "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
