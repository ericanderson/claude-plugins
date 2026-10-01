#!/usr/bin/env bash
# Tests for scripts/check-git-host.sh. Run: bash plugins/git/tests/check-git-host.test.sh

set -uo pipefail

hook="$(cd "$(dirname "$0")/.." && pwd)/scripts/check-git-host.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-git-host-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  git init -q "$tmp/$1"
  git -C "$tmp/$1" remote add origin "$2"
}
mkrepo gh-repo https://github.com/example/widgets.git
mkrepo fj-repo ssh://git@git.example.org:2222/example/widgets.git
gh_dir="$tmp/gh-repo"
fj_dir="$tmp/fj-repo"

pass=0
fail=0
hook_env=()   # extra `env` arguments for the next expect calls

# expect <allow|block> <cwd> <command> <description>
expect() {
  local want="$1" cwd="$2" cmd="$3" desc="$4" code got
  jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    | env ${hook_env[@]+"${hook_env[@]}"} "$hook" >/dev/null 2>&1
  code=$?
  case "$code" in
    0) got=allow ;;
    2) got=block ;;
    *) got="exit $code" ;;
  esac
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want %s, got %s\n  command: %s\n' "$desc" "$want" "$got" "$cmd"
  fi
}

# Existing behaviour.
expect block "$fj_dir" 'gh issue create --title x' 'gh in Forgejo repo'
expect block "$gh_dir" 'fj issue create x' 'fj in GitHub repo'
expect allow "$gh_dir" 'gh pr create --fill' 'gh in GitHub repo'
expect allow "$fj_dir" 'fj pr create x --base main' 'fj in Forgejo repo'
expect allow "$gh_dir" 'fj version' 'fj without a repo subcommand'
expect block "$gh_dir" 'git status && fj pr view 3' 'fj later in a chain'

# Leading cd / pushd.
expect allow "$fj_dir" "cd $gh_dir && gh issue create --title x" 'leading cd into GitHub repo'
expect allow "$gh_dir" "cd '$fj_dir'; fj issue view 3" 'leading quoted cd into Forgejo repo'
expect allow "$fj_dir" "pushd $gh_dir && gh pr list" 'leading pushd'
expect block "$gh_dir" "cd $gh_dir && fj issue view 3" 'leading cd into a GitHub repo still blocks fj'
expect allow "$fj_dir" "cd ../gh-repo && gh pr list" 'relative cd'

# Explicit target flags.
expect allow "$fj_dir" 'gh -R example/widgets issue list' 'gh -R before subcommand'
expect allow "$fj_dir" 'gh issue create --repo example/widgets --title x' 'gh --repo after subcommand'
expect allow "$fj_dir" 'gh pr view 3 --repo=example/widgets' 'gh --repo='
expect allow "$gh_dir" 'fj -H https://git.example.org issue view 3' 'fj -H'
expect allow "$gh_dir" 'fj issue view 3 --host https://git.example.org' 'fj --host after subcommand'
expect block "$fj_dir" 'gh -R x/y repo view; gh issue list' '-R on another command does not cover a later gh'

# Quoted and heredoc text is data, not a command.
expect allow "$fj_dir" "cat > \"\$TMPDIR/body.md\" <<'EOF'
Run gh issue create to file it.
EOF" 'heredoc body mentioning gh'
expect allow "$fj_dir" 'cat <<-EOF > f
	gh pr create
	EOF' '<<- heredoc with tab-indented terminator'
expect allow "$fj_dir" "echo 'gh issue create'" 'single-quoted text'
expect allow "$fj_dir" 'echo "use gh pr create here"' 'double-quoted text'
expect allow "$fj_dir" "echo \"don't run gh issue create\"" 'apostrophe inside double quotes'
expect block "$gh_dir" 'out="$(fj issue create "Title" --body-file f 2>&1)"' 'command substitution inside double quotes'
expect block "$fj_dir" "cat > f <<'EOF'
text
EOF
gh issue create --body-file f" 'command after the heredoc ends'
expect block "$gh_dir" 'tr a b <<< "x"
fj issue view 3' 'here-string is not a heredoc'

# Text handed to a shell or eval runs, so it isn't stripped.
expect block "$fj_dir" 'bash -c "gh issue create --title x"' 'bash -c with double quotes'
expect block "$fj_dir" "sh -c 'gh issue create --title x'" 'sh -c with single quotes'
expect block "$fj_dir" 'eval "gh issue create --title x"' 'eval'
expect block "$fj_dir" 'bash <<EOF
gh issue create --title x
EOF' 'heredoc fed to bash'

# A cd target we can't expand keeps the session cwd.
expect block "$fj_dir" 'cd "$(git rev-parse --show-toplevel)" && gh pr list' 'cd to $(…) keeps cwd'
expect block "$fj_dir" 'cd $REPO && gh pr list' 'cd to $VAR keeps cwd'
expect block "$fj_dir" 'cd `pwd` && gh pr list' 'cd to backticks keeps cwd'

# More leading-cd shapes.
expect allow "$fj_dir" "(cd $gh_dir && gh pr list)" 'subshell cd'
expect allow "$fj_dir" "pushd $gh_dir >/dev/null && gh pr list" 'pushd with redirection'
expect allow "$fj_dir" "cd $gh_dir 2>/dev/null && gh pr list" 'cd with stderr redirection'
expect allow "$fj_dir" "cd $gh_dir || exit 1; gh pr list" 'cd || exit'
expect allow "$fj_dir" "set -euo pipefail; cd $gh_dir && gh pr list" 'set prefix before cd'
expect allow "$fj_dir" "cd -P $gh_dir && gh pr list" 'cd -P'
expect allow "$fj_dir" "cd -- $gh_dir && gh pr list" 'cd --'
expect block "$gh_dir" "(cd $gh_dir && fj issue view 3)" 'subshell cd into GitHub repo still blocks fj'

# Failure modes resolve to a decision instead of erroring out.
hook_env=(-u HOME)
expect block "$fj_dir" 'cd ~/somewhere && gh issue create --title x' 'HOME unset: cd ~ keeps cwd'
mkdir -p "$tmp/badperl"
printf '#!/bin/sh\nexit 1\n' > "$tmp/badperl/perl"
chmod +x "$tmp/badperl/perl"
hook_env=(PATH="$tmp/badperl:$PATH")
expect block "$fj_dir" 'gh issue create --title x' 'perl failing falls back to the raw command'
hook_env=()

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
