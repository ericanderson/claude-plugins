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
# obviously-Forgejo, the hook gets out of the way. It also stays out of the
# way for `gh -R/--repo` and `fj -H/--host` (explicit target), resolves the
# repo from a leading `cd <dir> &&`, and ignores gh/fj mentioned only in
# quoted strings or heredoc bodies.
#
# Tests: bash plugins/git/tests/check-git-host.test.sh

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

# Drop text that is data rather than commands before matching: heredoc bodies,
# single-quoted strings, and double-quoted strings without a command
# substitution. So writing an issue body that mentions `gh issue create` to a
# file isn't mistaken for running it. Skipped when the command hands text to a
# shell or eval (`bash -c "…"`, `eval "…"`, `sh <<EOF`), since that text runs.
# Without perl, or if perl fails, match the raw command.
scan_line="$command_line"
shell_exec_re='(^|[^A-Za-z0-9_./-])(bash|sh|zsh|dash|ksh|eval)([[:space:]]|$)'
if [[ ! "$command_line" =~ $shell_exec_re ]] && command -v perl >/dev/null 2>&1; then
  scan_line="$(printf '%s' "$command_line" | perl -e '
    my @out; my @ends;
    for my $line (split /\n/, do { local $/; <STDIN> }) {
      if (@ends) {
        (my $t = $line) =~ s/^\t+//;
        shift @ends if $t eq $ends[0];
        next;
      }
      while ($line =~ /(?<!<)<<(?!<)-?[ \t]*([\x27"]?)([A-Za-z_][A-Za-z0-9_]*)\1/g) { push @ends, $2 }
      push @out, $line;
    }
    my $s = join "\n", @out;
    $s =~ s/(\x27[^\x27]*\x27)|"((?:[^"\\]|\\.)*)"/
      do { my $q = $2; defined $1 ? "\x27\x27" : ($q =~ m{\$\(|`} ? "\"$q\"" : "\"\"") } /ge;
    print $s;
  ')" || scan_line="$command_line"
fi

# Match `gh` / `fj` at a shell-word boundary, optionally followed by flags,
# then a repo-scoped subcommand. Deliberately generous — false positives here
# just mean we look up the origin unnecessarily.
subcommand_re='(issue|pr|pull|pull-request|release|repo)'
flag_re='([[:space:]]+-[^[:space:]]+(=[^[:space:]]+)?)*'
boundary='(^|[^A-Za-z0-9_-])'

gh_re="${boundary}gh${flag_re}[[:space:]]+${subcommand_re}([[:space:]]|$)"
fj_re="${boundary}fj${flag_re}[[:space:]]+${subcommand_re}([[:space:]]|$)"

# An explicit target overrides the cwd: `gh -R/--repo owner/repo` names a
# GitHub repo, `fj -H/--host <host>` names a Forgejo host.
gh_explicit_re="${boundary}gh[[:space:]].*(-R|--repo)([[:space:]=]|\$)"
fj_explicit_re="${boundary}fj[[:space:]].*(-H|--host)([[:space:]=]|\$)"

# Check each simple command on its own, so a flag on one doesn't excuse
# another.
uses_gh=false
uses_fj=false
while IFS= read -r segment; do
  if [[ "$segment" =~ $gh_re ]] && ! [[ "$segment" =~ $gh_explicit_re ]]; then
    uses_gh=true
  fi
  if [[ "$segment" =~ $fj_re ]] && ! [[ "$segment" =~ $fj_explicit_re ]]; then
    uses_fj=true
  fi
done < <(printf '%s\n' "$scan_line" | tr ';&|' '\n\n\n')

$uses_gh || $uses_fj || exit 0

# Honour a leading `cd <dir>` / `pushd <dir>` followed by `&&`, `||` or `;`:
# the CLI runs in that directory, not the session cwd. Also accepts a leading
# `(` subshell, `set …;` prefixes, `-L`/`-P`/`--` flags, and redirections such
# as `>/dev/null`. A target we can't expand (`$VAR`, `$(…)`, backticks) is
# ignored, keeping the session cwd.
repo_dir="${cwd:-$PWD}"
cd_re='^([[:space:]]*set[[:space:]][^;&|]*;)*[[:space:]]*\(?[[:space:]]*(cd|pushd)[[:space:]]+((-[LPe@]|--)[[:space:]]+)*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|()<>]+)([[:space:]]*[0-9]*>[>&]?[[:space:]]*[^[:space:];&|()<>]+)*[[:space:]]*(&&|\|\||;)'
if [[ "$command_line" =~ $cd_re ]]; then
  target="${BASH_REMATCH[5]}"
  target="${target#[\"\']}"
  target="${target%[\"\']}"
  home="${HOME:-}"
  case "$target" in
    "~"|"\$HOME"|"\${HOME}")             target="${home:+$home}" ;;
    "~/"*)                               target="${home:+$home/${target#\~/}}" ;;
    "\$HOME/"*)                          target="${home:+$home/${target#\$HOME/}}" ;;
    "\${HOME}/"*)                        target="${home:+$home/${target#\$\{HOME\}/}}" ;;
  esac
  if [[ -n "$target" && "$target" != *'$'* && "$target" != *'`'* ]]; then
    [[ "$target" == /* ]] || target="$repo_dir/$target"
    repo_dir="$target"
  fi
fi
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
