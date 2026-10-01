#!/usr/bin/env bash
# PreToolUse hook: this repo is public, so check anything about to be published.
#
# Fires on Bash commands that publish: git commit / git push, gh
# pr/issue/release/gist/label/repo/project/workflow with a writing verb
# (create, edit, comment, …), and gh api calls that send data. For those it:
#   1. scans what would become public against a private denylist and denies
#      the call on a match:
#        - the command line, and files it names (--body-file, --notes-file,
#          -F/--file, --input, -f/-F key=@file, gist create <file>)
#        - commit: added lines and file names, staged and unstaged
#        - push / gh pr create: messages, added lines, and file names of every
#          local commit no remote has (all branches and tags), plus annotated
#          tag messages
#   2. otherwise lets the call through with a "this repo is PUBLIC" checklist
#      added to Claude's context.
#
# The denylist lives OUTSIDE the repo — committing it would publish the very
# terms it protects. One case-insensitive ERE per line; blank lines and lines
# starting with # are ignored. An invalid pattern denies every publishing call
# until fixed. Location:
#   ${PUBLIC_REPO_DENYLIST:-$HOME/.config/claude/public-repo-denylist}
#
# Only added lines are scanned, so text already public on main doesn't trip it.
# Fails open (no block) if jq is missing or the input can't be parsed.
#
# Tests: bash .claude/hooks/public-repo-guard.test.sh

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

max_file_bytes=1000000     # per named file
max_git_bytes=5000000      # per git query

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
[[ -n "$cmd" ]] || exit 0
cwd="${cwd:-$PWD}"

# `git`/`gh` anywhere a command word can start (including /usr/bin/git and
# $(which git)), any options in between, then the subcommand.
boundary='(^|[^A-Za-z0-9_.-])'
end='([^A-Za-z0-9_-]|$)'
commit_re="${boundary}git[^;&|]*[[:space:]]commit${end}"
push_re="${boundary}git[^;&|]*[[:space:]]push${end}"
# gh only when it writes: a publishing verb right after the command group
# (options allowed in between), or `gh api` with a body (-f/-F/--input) or a
# non-GET method. Read-only calls (view, list, status, checks, diff, plain
# api GETs) aren't scanned.
gh_flags='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?)*'
gh_groups='(pr|issue|release|gist|label|repo|project|workflow)'
gh_verbs='(create|edit|comment|review|merge|close|reopen|upload|delete|ready|lock|unlock|transfer|pin|unpin|rename|archive|unarchive|run|item-create|item-edit|item-add|field-create|copy)'
gh_re="${boundary}gh${gh_flags}[[:space:]]+${gh_groups}${gh_flags}[[:space:]]+${gh_verbs}${end}"
gh_api_write_re="${boundary}gh${gh_flags}[[:space:]]+api([[:space:]][^;&|]*)?[[:space:]]((-f|-F|--field|--raw-field|--input)([[:space:]=]|$)|(-X|--method)([[:space:]]+|=)?(POST|PUT|PATCH|DELETE|post|put|patch|delete)${end})"
gh_pr_create_re="${boundary}gh${gh_flags}[[:space:]]+pr${gh_flags}[[:space:]]+create${end}"

is_commit=false; is_push=false; is_gh=false; is_pr_create=false
[[ "$cmd" =~ $commit_re ]] && is_commit=true
[[ "$cmd" =~ $push_re ]] && is_push=true
[[ "$cmd" =~ $gh_re || "$cmd" =~ $gh_api_write_re ]] && is_gh=true
[[ "$cmd" =~ $gh_pr_create_re ]] && is_pr_create=true
$is_commit || $is_push || $is_gh || exit 0

# Which repo the git commands act on: `git -C <dir>`, else a leading
# `cd <dir> &&`, else the session cwd. Unexpandable targets keep the cwd.
expand_dir() { # expand_dir <raw> → absolute dir on stdout, or nothing
  local t="$1"
  t="${t#[\"\']}"; t="${t%[\"\']}"
  case "$t" in
    "~")     t="${HOME:-}" ;;
    "~/"*)   [[ -n "${HOME:-}" ]] && t="$HOME/${t#\~/}" || t="" ;;
    "\$HOME"|"\${HOME}") t="${HOME:-}" ;;
    "\$HOME/"*)   [[ -n "${HOME:-}" ]] && t="$HOME/${t#\$HOME/}" || t="" ;;
    "\${HOME}/"*) [[ -n "${HOME:-}" ]] && t="$HOME/${t#\$\{HOME\}/}" || t="" ;;
  esac
  [[ -z "$t" || "$t" == *'$'* || "$t" == *'`'* ]] && return
  [[ "$t" == /* ]] || t="$cwd/$t"
  printf '%s' "$t"
}
word='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|()<>]+)'
repo_dir="$cwd"
cd_re='^([[:space:]]*set[[:space:]][^;&|]*;)*[[:space:]]*\(?[[:space:]]*(cd|pushd)[[:space:]]+((-[LPe@]|--)[[:space:]]+)*'"$word"'[^;&|]*(&&|\|\||;)'
gitC_re="${boundary}git[[:space:]]+-C[[:space:]]*${word}"
if [[ "$cmd" =~ $gitC_re ]]; then
  d="$(expand_dir "${BASH_REMATCH[2]}")"; [[ -n "$d" ]] && repo_dir="$d"
elif [[ "$cmd" =~ $cd_re ]]; then
  d="$(expand_dir "${BASH_REMATCH[5]}")"; [[ -n "$d" ]] && repo_dir="$d"
fi
g() { git -C "$repo_dir" "$@" 2>/dev/null | head -c "$max_git_bytes"; }

# Everything that will become public, one blob.
payload="$cmd"
unreadable=()
notes=()

add_file() { # add_file <raw path>
  local f="$1"
  f="${f#[\"\']}"; f="${f%[\"\']}"
  f="${f#@}"
  if [[ "$f" == "-" ]]; then
    [[ "$cmd" == *"<<"* ]] || notes+=("content piped on stdin was not scanned")
    return
  fi
  f="${f//\$\{TMPDIR\}/${TMPDIR:-}}"; f="${f//\$TMPDIR/${TMPDIR:-}}"
  f="${f//\$\{HOME\}/${HOME:-}}"; f="${f//\$HOME/${HOME:-}}"
  [[ "$f" == "~/"* ]] && f="${HOME:-}/${f#\~/}"
  [[ "$f" == /* ]] || f="$repo_dir/$f"
  # Regular files only: a FIFO or device could hang the hook, and a hook that
  # times out doesn't block the call.
  if [[ "$f" == *'$'* || ! -f "$f" || ! -r "$f" ]]; then
    unreadable+=("$(basename -- "$f")")
  else
    payload+=$'\n'"$(head -c "$max_file_bytes" -- "$f")"
  fi
}

# Named files: --body-file/--notes-file/--file/--input/-F <path>, and gh
# -f/-F/--field/--raw-field key=@path. A plain key=value field is inline text,
# already in the command line.
file_re='(--body-file|--notes-file|--file|--input|--field|--raw-field|-F|-f)(=|[[:space:]]+)'"$word"
rest="$cmd"
while [[ "$rest" =~ $file_re ]]; do
  flag="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[3]}"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
  f="${f#[\"\']}"; f="${f%[\"\']}"
  if [[ "$f" == *=* ]]; then
    [[ "${f#*=}" == @* ]] && add_file "${f#*=}"
    continue
  fi
  [[ "$flag" == "-f" || "$flag" == "--field" || "$flag" == "--raw-field" ]] && continue
  add_file "$f"
done

# gh gist create <file>…: every positional argument is a file to publish.
gist_re="${boundary}gh[^;&|]*[[:space:]]gist[[:space:]]+create[[:space:]]+([^;&|]*)"
if [[ "$cmd" =~ $gist_re ]]; then
  skip=false
  read -ra toks <<<"${BASH_REMATCH[2]}"
  for tok in ${toks[@]+"${toks[@]}"}; do
    if $skip; then skip=false; continue; fi
    case "$tok" in
      -d|--desc|-f|--filename) skip=true ;;
      -*) ;;
      *) add_file "$tok" ;;
    esac
  done
fi

added_lines() { grep -E '^\+' | grep -vE '^\+\+\+ '; }

if $is_commit; then
  payload+=$'\n'"$(g diff --cached | added_lines)"
  payload+=$'\n'"$(g diff --cached --name-only)"
  # pathspec, -a, -o and -i commits take working-tree content too.
  payload+=$'\n'"$(g diff | added_lines)"
  payload+=$'\n'"$(g diff --name-only)"
fi

if $is_push || $is_pr_create; then
  # Every local commit that no remote has, whichever refs the push names
  # (refspecs, --all, --mirror, --tags, a merge just before the push).
  unpushed=(--branches --tags --not --remotes)
  payload+=$'\n'"$(g log --format='%B' "${unpushed[@]}")"
  payload+=$'\n'"$(g log -p --format= "${unpushed[@]}" | added_lines)"
  payload+=$'\n'"$(g log --name-only --format= "${unpushed[@]}")"
  payload+=$'\n'"$(g for-each-ref --format='%(contents)' refs/tags)"
fi

denylist="${PUBLIC_REPO_DENYLIST:-$HOME/.config/claude/public-repo-denylist}"
denylist_shown="$denylist"
if [[ -n "${HOME:-}" && "$denylist" == "$HOME"/* ]]; then
  denylist_shown="~/${denylist#"$HOME"/}"
fi
patterns=""
if [[ -r "$denylist" ]]; then
  patterns="$(grep -vE '^[[:space:]]*(#|$)' "$denylist" || true)"
fi

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

if [[ -n "$patterns" ]]; then
  # Report which denylist entries matched, not the matched text: a broad
  # pattern like `.*name.*` would otherwise echo whole lines (and any secrets
  # next to the name) back into Claude's context.
  shown=""
  while IFS= read -r p; do
    grep -qiE -- "$p" <<<"$payload" 2>/dev/null
    case $? in
      0) shown+="  - ${p:0:80}"$'\n' ;;
      1) ;;
      *) deny "Blocked: the private denylist ($denylist_shown) has an invalid pattern, so nothing can be checked. Ask the user to fix it (each line must be a valid extended regex) before publishing from this public repo." ;;
    esac
  done <<<"$patterns"
  if [[ -n "$shown" ]]; then
    deny "Blocked: this repo (claude-plugins) is PUBLIC, and what this command would publish matches these private denylist entries ($denylist_shown):
${shown}Remove or genericize that text (e.g. example.org, owner/repo) in the message, body file, file names, diff, or unpushed commits, then retry. Don't quote it anywhere public."
  fi
fi

ctx="This repo (claude-plugins) is PUBLIC on GitHub. Before this publishes, check the commit message, PR/issue text, file names, and diff for: private repo or project names, personal hostnames or IPs, local paths (/Users/...), usernames, emails, tokens or keys, and details of the user's other projects or finances. Use placeholders (example.org, owner/repo) instead. See CLAUDE.md."
if [[ -z "$patterns" ]]; then
  ctx+=" Note: no private denylist found at $denylist_shown, so only this reminder ran."
fi
if (( ${#unreadable[@]} )); then
  ctx+=" The guard could not read: ${unreadable[*]} — re-read it yourself before publishing."
fi
if (( ${#notes[@]} )); then
  ctx+=" Also: ${notes[*]} — check it yourself."
fi
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
exit 0
