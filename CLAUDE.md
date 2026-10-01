# claude-plugins

## This repository is public

Everything you write here is published on GitHub: file contents, commit messages, branch names, and PR/issue titles, bodies, and comments. PR body edits stay visible in GitHub's edit history, and force-pushed commits stay reachable by SHA, so a leak can't be fully undone — get it right before publishing.

Never include:
- names of the user's private repos, projects, or organizations
- personal hostnames, domains, IPs, or ports beyond what is already on `main`
- local paths (`/Users/...`, vault or home-directory layouts), usernames, emails
- tokens, keys, or anything read from credential files
- details about the user's other projects, finances, or infrastructure

Use placeholders instead: `example.org`, `git.example.org`, `owner/repo`, `$HOME`. When a change comes from work in another (private) repo, describe the problem generically ("a per-repo stopgap script", "a downstream pipeline") rather than naming it.

`.claude/hooks/public-repo-guard.sh` checks publishing commands against a private denylist kept outside the repo. A block from it means: genericize the matched text and retry — don't repeat the matched text anywhere public.
