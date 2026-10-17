# LearnChat agent working agreement

Read this file and `docs/orcha-project-preferences.md` before working. Read the assigned
Orcha task's full description, definition of done, protocol and thread on every wake.

- This is one repository: `open-orcha/LearnChat`, private, default branch `main`.
- Keep the existing paths: `muse-runtime/`, `LearnChat/` (Android), `LearnChat-iOS/`, `docs/`.
  The running Mac service refers to this workspace; moving folders needs coordination.
- Follow `docs/github-workflow.md` for reconciliation, review, attribution and publication.
  Before editing, inspect Git status and fetch the remote. Never discard, stash, commit or
  overwrite another agent's unfinished changes without coordinating with that agent.
- Coordinate Android/iOS work with MobileAppAgent and validation with QAAgent through
  Orcha requests. Do not restart the live runtime or change network exposure for a
  repository/documentation task. Do not count HTTP health as a completed phone chat.
- Stage explicit reviewed paths; inspect the staged diff and file list. Keep credentials,
  signing material, model weights, builds, caches, chat data, logs and all local Orcha
  state out of Git. Do not use broad `git add .` or force-push.
- Attribute work to the requesting human under the configured repository workflow.
  Include a `Requested-by: <human name>` commit trailer and name the requester in any PR.
  Do not invent an email address or change global Git identity.
- Commit and push completed, reviewed deliverables within the task's authorization and
  effective Orcha autonomy. Verify remote and local commits match; post a GitHub link,
  checks and remaining human steps to the originating Orcha task thread.
- Stop for the named human verification step. If Orcha auto-completes implementation,
  preserve a separate explicit human verification request. Never self-certify that step.
- New models are future work unless explicitly assigned. Do not add or change the repository
  license without Kedar's direction.
