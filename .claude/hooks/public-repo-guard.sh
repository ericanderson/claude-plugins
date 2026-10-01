#!/usr/bin/env bash
# PreToolUse hook: this repo is public, so check anything about to be published.
#
# Fires on Bash commands that publish: git commit / git push, and gh
# pr/issue/release/gist/api. For those it:
#   1. scans the command line, any --body-file / -F / --file it names, and the
#      lines being added (staged diff for a commit, unpushed commits for a
#      push) against a private denylist, and denies the call on a match;
#   2. otherwise lets the call through with a "this repo is PUBLIC" checklist
#      added to Claude's context.
#
# The denylist lives OUTSIDE the repo — committing it would publish the very
# terms it protects. One case-insensitive ERE per line; blank lines and lines
# starting with # are ignored. Location:
#   ${PUBLIC_REPO_DENYLIST:-$HOME/.config/claude/public-repo-denylist}
#
# Only added lines are scanned, so text already public on main doesn't trip it.
# Fails open (no block) if jq is missing or the input can't be parsed.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
[[ -n "$cmd" ]] || exit 0
cwd="${cwd:-$PWD}"

boundary='(^|[^A-Za-z0-9_./-])'
commit_re="${boundary}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)"
push_re="${boundary}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)"
gh_re="${boundary}gh([[:space:]]+-[^[:space:]]+)*[[:space:]]+(pr|issue|release|gist|api)([[:space:]]|$)"

is_commit=false; is_push=false; is_gh=false
[[ "$cmd" =~ $commit_re ]] && is_commit=true
[[ "$cmd" =~ $push_re ]] && is_push=true
[[ "$cmd" =~ $gh_re ]] && is_gh=true
$is_commit || $is_push || $is_gh || exit 0

# Everything that will become public, one blob.
payload="$cmd"
unreadable=()

# Files named by --body-file / --file / -F (git commit -F, gh ... -F).
# Expand $HOME, $TMPDIR and ~ ourselves; anything else can't be resolved here.
file_re='(--body-file|--file|-F)(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)'
rest="$cmd"
while [[ "$rest" =~ $file_re ]]; do
  f="${BASH_REMATCH[3]}"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
  f="${f#[\"\']}"; f="${f%[\"\']}"
  [[ "$f" == "-" || "$f" == *=* ]] && continue   # stdin, or gh api -F key=value
  f="${f//\$\{TMPDIR\}/${TMPDIR:-}}"; f="${f//\$TMPDIR/${TMPDIR:-}}"
  f="${f//\$\{HOME\}/$HOME}"; f="${f//\$HOME/$HOME}"
  [[ "$f" == "~/"* ]] && f="$HOME/${f#\~/}"
  [[ "$f" == /* ]] || f="$cwd/$f"
  if [[ "$f" == *'$'* || ! -r "$f" ]]; then
    unreadable+=("$f")
  else
    payload+=$'\n'"$(cat "$f")"
  fi
done

added_lines() { grep -E '^\+' | grep -vE '^\+\+\+ '; }

if $is_commit; then
  payload+=$'\n'"$(git -C "$cwd" diff --cached 2>/dev/null | added_lines)"
  if [[ "$cmd" =~ [[:space:]](-a|--all|-[A-Za-z]*a[A-Za-z]*)([[:space:]]|$) ]]; then
    payload+=$'\n'"$(git -C "$cwd" diff 2>/dev/null | added_lines)"
  fi
fi

if $is_push; then
  range='@{upstream}..HEAD'
  git -C "$cwd" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 || range='origin/HEAD..HEAD'
  payload+=$'\n'"$(git -C "$cwd" log --format='%B' "$range" 2>/dev/null)"
  payload+=$'\n'"$(git -C "$cwd" log -p --format= "$range" 2>/dev/null | added_lines)"
fi

denylist="${PUBLIC_REPO_DENYLIST:-$HOME/.config/claude/public-repo-denylist}"
patterns=""
if [[ -r "$denylist" ]]; then
  patterns="$(grep -vE '^[[:space:]]*(#|$)' "$denylist" || true)"
fi

if [[ -n "$patterns" ]]; then
  hits="$(printf '%s\n' "$payload" | grep -noiE -f <(printf '%s\n' "$patterns") | sort -u -t: -k2 | head -10 || true)"
  if [[ -n "$hits" ]]; then
    reason="Blocked: this repo (claude-plugins) is PUBLIC, and what this command would publish matches the private denylist ($denylist):
$hits
Remove or genericize these (e.g. example.org, owner/repo) in the message, body file, or diff, then retry. Don't quote the matched text anywhere public."
    jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
      permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
  fi
fi

ctx="This repo (claude-plugins) is PUBLIC on GitHub. Before this publishes, check the commit message, PR/issue text, and diff for: private repo or project names, personal hostnames or IPs, local paths (/Users/...), usernames, emails, tokens or keys, and details of the user's other projects or finances. Use placeholders (example.org, owner/repo) instead. See CLAUDE.md."
if [[ -z "$patterns" ]]; then
  ctx+=" Note: no private denylist found at $denylist, so only this reminder ran."
fi
if (( ${#unreadable[@]} )); then
  ctx+=" The guard could not read: ${unreadable[*]} — re-read it yourself before publishing."
fi
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
exit 0
