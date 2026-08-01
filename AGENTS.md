# Repository automation notes

## GitHub authentication and publishing

- GitHub CLI is installed at `C:\Program Files\GitHub CLI\gh.exe`.
- The user authenticates `gh` as `SergioAG1994` through the Windows keyring. Never store, print, or commit the token.
- In the managed Codex sandbox, GitHub network calls can fail with a socket-permission error and make `gh auth status` misleadingly report an invalid token. If that happens, rerun the authentication check with network escalation before asking the user to log in again.
- The connected GitHub plugin can read `SergioAG1994/LabApp`, but its current GitHub App installation cannot write repository contents or refs (`403 Resource not accessible by integration`). Use local `git` plus authenticated `gh` for publishing unless a write-capable plugin connection is later verified.
- Commands that contact GitHub, including `gh repo view`, `git fetch`, `git push`, and `git ls-remote`, may require network escalation in the managed sandbox.
- Before publishing, fetch `origin/main`, confirm the local branch is not behind, stage explicit paths, run the relevant checks, commit, push, and verify the remote SHA.
- Push directly to `main` only when the user explicitly requests a direct main-branch merge; otherwise use a feature branch and pull request.
