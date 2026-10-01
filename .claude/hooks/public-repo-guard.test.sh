#!/usr/bin/env bash
# Tests for public-repo-guard.sh. Run: bash .claude/hooks/public-repo-guard.test.sh
#
# Uses throwaway git repos, a local bare "origin", and a temp denylist whose
# private term is "secretproj". No network.

set -uo pipefail

hook="$(cd "$(dirname "$0")" && pwd)/public-repo-guard.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
export PUBLIC_REPO_DENYLIST="$t/deny"
printf '# test list\n\nsecretproj\nprivate\\.example\\.net\n' > "$PUBLIC_REPO_DENYLIST"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_GLOBAL=/dev/null

newrepo() { # newrepo <dir> → repo with one pushed commit (a.txt mentions secretproj)
  git init -q -b main "$1"
  git init -q --bare "$1.git"
  git -C "$1" remote add origin "$1.git"
  echo "old secretproj line" > "$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" commit -q -m init
  git -C "$1" push -q -u origin main 2>/dev/null
}
newrepo "$t/r"
cd "$t/r" || exit 1

pass=0; fail=0
# run <want: deny|ctx|none> <desc> <command> [cwd]  — 5 s watchdog per call
run() {
  local want="$1" desc="$2" cmd="$3" dir="${4:-$t/r}" out got
  out="$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | perl -e 'alarm shift; exec @ARGV' 5 "$hook")"
  local code=$?
  if (( code != 0 )); then got="exit $code"
  elif [[ -z "$out" ]]; then got=none
  elif jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null <<<"$out"; then got=deny
  else got=ctx; fi
  last="$out"
  if [[ "$got" == "$want" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s — want %s, got %s\n' "$desc" "$want" "$got"; fi
}
check() { # check <desc> [!] <command…>
  local desc="$1" ok; shift
  if [[ "$1" == "!" ]]; then shift; if "$@"; then ok=false; else ok=true; fi
  elif "$@"; then ok=true; else ok=false; fi
  if $ok; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n' "$desc"; fi
}

# --- Basics (carried over) ---
run none "non-publishing" "ls -la"
run none "git status" "git status"
run ctx  "clean commit" "git commit -m 'feat: thing'"
run deny "inline message hit" "git commit -m 'mention SecretProj here'"
echo "harmless new line" >> a.txt; git add a.txt
run ctx  "staged change next to an old denylisted line" "git commit -m x"
git reset -q --hard
echo "new private.example.net" > b.txt; git add b.txt
run deny "staged added line hit" "git commit -m 'add b'"
git reset -q b.txt; rm b.txt
printf 'body mentions secretproj\n' > "$t/body.md"
run deny "body file hit (absolute)" "gh pr create --title x --body-file $t/body.md"
run deny "body file hit (\$TMPDIR)" "gh pr create --title x --body-file \"\$TMPDIR/$(basename "$t")/body.md\""
run deny "commit -F hit" "git commit -F $t/body.md"
run ctx  "unresolvable body file" "gh pr create --body-file \"\$BODY\""
run ctx  "gh api inline field" "gh api repos/o/r/issues -F title=x"
PUBLIC_REPO_DENYLIST="$t/missing" run ctx "missing denylist -> reminder" "git commit -m 'mention secretproj'"

# --- Finding 1: FIFOs and devices must not hang the hook ---
mkfifo "$t/fifo"
run ctx  "FIFO body file is skipped, not read" "git commit -m ok -F $t/fifo"
check "FIFO is reported as unreadable" grep -q 'could not read: fifo' <<<"$last"
run ctx  "/dev/zero body file is skipped" "gh pr create --body-file /dev/zero"

# --- Findings 2, 3, 6: push scans every unpushed ref ---
git switch -q -c feat; echo "secretproj feature" > f.txt; git add f.txt; git commit -q -m feat; git switch -q main
run deny "push of another branch" "git push origin feat"
run deny "plain push while another branch is unpushed" "git push"
git branch -q -D feat
run ctx  "clean push" "git push origin HEAD"
git tag -a v1 -m "release secretproj notes"
run deny "annotated tag message" "git push --tags"
git tag -d v1 >/dev/null
newrepo "$t/fresh"; git -C "$t/fresh" update-ref -d refs/remotes/origin/main
echo "secretproj" > "$t/fresh/s.txt"; git -C "$t/fresh" add s.txt; git -C "$t/fresh" commit -q -m s
run deny "first push with no upstream or origin/HEAD" "git push -u origin main" "$t/fresh"

# --- Finding 4: command forms ---
run deny "git -c k=v commit" "git -c core.x=y commit -m secretproj"
run deny "git -C dir commit" "git -C $t/r commit -m secretproj"
run deny "absolute git path" "/usr/bin/git commit -m secretproj"
git switch -q -c feat2; echo "secretproj" > g.txt; git add g.txt; git commit -q -m g; git switch -q main
run deny "push; with no trailing space" "git push;echo done"
run deny "push&& with no space" "git push&&echo done"
run deny "push in a subshell" "(git push)"
git branch -q -D feat2

# --- Finding 5: commit-time gaps ---
echo "secretproj unstaged" >> a.txt
run deny "pathspec commit takes unstaged content" "git commit -m x a.txt"
git checkout -q -- a.txt
newrepo "$t/other"
echo "secretproj" > "$t/other/o.txt"; git -C "$t/other" add o.txt
run deny "cd into another repo before commit" "cd $t/other && git commit -m x"
git -C "$t/other" reset -q --hard
git switch -q -c feat3; echo "secretproj" > h.txt; git add h.txt; git commit -q -m h
run deny "gh pr create scans unpushed commits" "gh pr create --title x --body ok"
git switch -q main; git branch -q -D feat3

# --- Finding 7: more gh forms ---
run deny "gh release --notes-file" "gh release create v1 --notes-file $t/body.md"
run deny "gh gist create <file>" "gh gist create -d desc $t/body.md"
run deny "gh api -F key=@file" "gh api repos/o/r/issues -F body=@$t/body.md"
run deny "gh api --input" "gh api repos/o/r/issues --input $t/body.md"
run deny "gh repo edit --description" "gh repo edit --description 'secretproj tools'"
run deny "gh label create -d" "gh label create x -d secretproj"
run ctx  "piped stdin body is flagged" "cat x | gh pr create -F -"
check "piped stdin is called out" grep -q 'stdin was not scanned' <<<"$last"

# --- Read-only gh calls aren't publishing ---
run none "gh pr view" "gh pr view 9 --json state -q .state"
run none "gh pr list" "gh pr list --state open"
run none "gh pr checks" "gh pr checks 9"
run none "gh issue view with comments" "gh issue view 3 --comments"
run none "gh pr view mentioning a denylisted term" "gh pr view 9 --json body | grep secretproj"
run none "gh api GET" "gh api repos/o/r/pulls"
run none "gh api explicit GET" "gh api -X GET repos/o/r"
run none "gh repo view" "gh repo view o/r"
run none "gh label list" "gh label list"
# …while writes are still caught, with options in between.
run deny "gh -R before the group" "gh -R o/r pr create --title x --body secretproj"
run deny "gh option between group and verb" "gh pr -R o/r edit 3 --body secretproj"
run deny "gh pr comment" "gh pr comment 3 --body secretproj"
run deny "gh issue close with comment" "gh issue close 3 --comment secretproj"
run deny "gh api -f" "gh api repos/o/r/issues -f body=secretproj"
run deny "gh api -X PATCH --input" "gh api -X PATCH repos/o/r/issues/1 --input $t/body.md"
run ctx  "gh api -XPOST" "gh api -XPOST repos/o/r/dispatches"
run deny "gh api leading -f" "gh api -f body=secretproj repos/o/r/issues"
run ctx  "gh pr merge" "gh pr merge 3 --squash"

# --- Finding 8: file names ---
echo "clean" > "secretproj-notes.md"; git add secretproj-notes.md
run deny "staged file name" "git commit -m 'add notes'"
git reset -q secretproj-notes.md; rm secretproj-notes.md

# --- Finding 9: an invalid pattern fails closed ---
printf 'secretproj\nbad(\n' > "$t/deny-bad"
PUBLIC_REPO_DENYLIST="$t/deny-bad" run deny "invalid denylist pattern denies" "git commit -m fine"
check "invalid pattern is explained" grep -q 'invalid pattern' <<<"$last"

# --- Finding 11: no neighbouring text echoed ---
printf '.*secretproj.*\n' > "$t/deny-broad"
PUBLIC_REPO_DENYLIST="$t/deny-broad" run deny "broad pattern" "git commit -m 'password=hunter2 secretproj key=AKIA123'"
check "broad pattern doesn't echo neighbouring text" ! grep -q 'AKIA123\|hunter2' <<<"$last"
check "deny reason shows the denylist path relative to ~" ! grep -q "\"$HOME/" <<<"$last"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
