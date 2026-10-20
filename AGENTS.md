# Repository instructions

## Sync before work

- At the start of every task, before inspecting project files to investigate, plan, or edit, fetch GitHub and compare local `HEAD` with its upstream. Do not rely on a previous session's sync.
- Run:

  ```bash
  git fetch origin --prune
  git status --short --branch
  git rev-list --left-right --count HEAD...@{upstream}
  ```

  `0 0` means in sync, `0 N` means GitHub is ahead, and `N 0` means local is ahead.

- If only GitHub is ahead, sync before reading or editing:
  - clean tree: `git pull --ff-only`;
  - dirty tree: commit the local changes, then `git pull --rebase`, resolve any conflicts, and push.
- If both local and GitHub have new commits, commit local work, rebase the unpublished local commits onto upstream (or merge if they are already published), resolve conflicts, push, then start the task.
- If only local is ahead, commit and push the local changes before continuing.
- If `HEAD` matches upstream but the working tree is dirty, commit and push the changes before starting.
- Do not start until local and GitHub match and the working tree is clean, unless the user explicitly approved working offline.
- If edits are already underway and GitHub is newer, sync first and re-read the upstream versions of the affected files before continuing.
- Never discard local work to make the sync succeed.
- If the fetch fails, stop and report it; do not work from possibly stale files unless the user explicitly says to work offline.

## Git workflow

- After every edit, commit the change and push the current branch to GitHub (`origin`) immediately.
- After each successful push, start your response with `Pushed to {branch} #{short_commit_hash}`, then put everything else after it.
- Do not finish a response with uncommitted or unpushed changes.
- Do not ask for confirmation before committing or pushing.
- Never force-push or rewrite published history unless the user explicitly asks.
- If a commit or push fails, stop and report the exact error; do not claim the change is saved.
