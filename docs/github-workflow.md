# GitHub sync and review workflow

The canonical repository is **https://github.com/open-orcha/LearnChat**, private, with
`main` as the default and integration branch. The existing workspace root is the Git root;
`muse-runtime`, `QChat`, `QChat-iOS` and `docs` remain in place. No prior component Git history
was present when this monorepo was initialized. The initial snapshot preserves existing source
and build inputs; it does not publish the local Orcha conversation history. Keep the repository
private until component rebranding, independent QA and human approval are complete.

## Before making changes

Read `AGENTS.md`, `docs/orcha-project-preferences.md`, and the full Orcha task/thread.
Check the project's live autonomy and review chain. Inspect the working tree and fetch:

```sh
git status --short
git remote -v
git branch -vv
git fetch origin
git log --oneline --left-right HEAD...origin/main
```

If clean and behind on `main`, use `git pull --ff-only`. If there are uncommitted changes or
branches have diverged, identify the owner and coordinate through Orcha before reconciling.
Never reset/clean/stash another agent's work, force-push, or silently overwrite a conflict.
Do not switch branches underneath a running service or another agent in the shared workspace.
For independent work, use a separate worktree outside this workspace when appropriate:

```sh
git worktree add -b task/short-description ../qchat-task origin/main
```

A worktree has no local `.env`, models or SDK settings; supply local prerequisites deliberately.
Do not start a second runtime on the production ports. Coordinate changes touching app source
with MobileAppAgent, and runtime/mobile integration checks with QAAgent.

## Publish a completed task

1. Reconcile the latest source and review requirements with its owners. Run relevant checks
   from [validation](validation.md) and inspect their actual result.
2. Stage explicit files or reviewed component directories. Inspect both content and file names:

   ```sh
   git add path/to/reviewed-file
   git diff --cached --stat
   git diff --cached
   git diff --cached --check
   git status --short
   ```

   Exclude `.env`, keys/signing material, model weights, generated builds, local SDK settings,
   chat stores, logs, runtime state and `.orcha`, `.claude`, `.codex`, `.agents`. `.gitignore`
   is protection against accidents, not a substitute for reviewing the staged snapshot.
3. Use the configured authorized author identity; do not invent an identity. For this migration,
   Kedar requested the work and commits use his existing configured name/email. Include a
   `Requested-by: Kedar` trailer. Read `requested_by` from the Orcha agent protocol endpoint
   for the task. The PR body must start with `> 🧑 Triggered by @<github_login> via Orcha task
   <task_id>` followed by a blank line; use the human alias without `@` if login is absent.
   Add `Co-authored-by: <alias> <git_email>` on the final branch commit when the protocol
   supplies an email (or `<github_login>@users.noreply.github.com` when only login is known).
   If both are absent, skip that trailer; never invent an email. Do not amend published `main`.
4. Commit reviewed work and push the intended branch. For a task worktree, create a PR to
   `main` and follow the required review/autonomy gate. Use a body file with `gh pr create
   --body-file` for multiline descriptions. Full autonomy permits merges only to `main`;
   Build-to-PR leaves the PR for the human. Never treat that permission as human acceptance.
5. In the canonical workspace, once clean and coordinated, `git fetch origin` then
   `git pull --ff-only` incorporates the reviewed merge. A direct initial publication is
   authorized for this repository-creation task; it is not permission to bypass future reviews.
6. Verify synchronization:

   ```sh
   git fetch origin
   git status --short
   git rev-parse HEAD
   git rev-parse '@{upstream}'
   git ls-remote origin refs/heads/main
   ```

   The local and remote hashes must match for the published snapshot; a later dirty working
   tree means new work still needs review. Do not automatically commit every file change.
7. Post a GitHub commit/PR link, guide paths, check results and any remaining human steps to the
   originating Orcha task. Stop at its human verification checkpoint. If Orcha auto-completes
   implementation at full autonomy, preserve a separate explicit request to Kedar for review.

## Local Orcha association

The local project is associated with `open-orcha/LearnChat` through the supported
`PUT /api/containers/{container_id}/github` API, with JSON `{"repo":"open-orcha/LearnChat"}`.
Verify using the matching GET, which must return the same `repo`. The portal's repository
setting is the human-facing equivalent. Discover this installation's URL and container from
its ignored `.claude/orcha.json`; never copy those local identifiers into the repository or
edit the database directly. Other clones need their own Orcha setup/binding.

Git CLI access and the portal's GitHub integration have separate credentials/permissions.
If the binding is correct but portal browsing is denied, authorize this private repository in
the portal's existing GitHub integration; do not put tokens in committed files or task messages.
