# zen-tests

A throwaway GitHub repo for **functional** zen tests. Open PRs and force-push here instead of on [mgreau/zen](https://github.com/mgreau/zen).

The default branch is a tiny fixture (`hello.txt`). Scripts under `scripts/` drive zen against this repo with an isolated `ZEN_HOME`, so a day-to-day `~/.zen` (Aider, Terminal.app, live watch state) is left alone.

## What this covers

[`scripts/keep-worktrees.sh`](scripts/keep-worktrees.sh) is the keep-worktrees / SHA-refresh plan ([zen#18](https://github.com/mgreau/zen/issues/18)):

| Scenario | How |
|---|---|
| SHA A → B, worktree + `CLAUDE.local.md` catch up | `zen review --json --no-terminal` |
| Dirty worktree: files not discarded | tracked edit, then review |
| Live agent (`claude` cwd in the tree): skip | `exec -a claude /bin/sleep` |
| Force-push: `--json` does not reset; `y` on a TTY does | rewrite + `git push --force-with-lease` |
| Inbox “new” without `authors:` / no worktree | Actions bot PR + requested reviewer |
| Upgrade: `seen_prs` does not re-announce | `last_check.json` before first poll |
| Watch create + fast-forward | bot in `authors:` |
| Draft (`ignore_drafts: true`) → push → undraft → one refresh | watch log + HEAD |

Merged cleanup is not in this script (`cleanup_after_days` cannot be 0). That stays a unit test.

## Requirements

- `gh` authenticated (`gh auth login`)
- `git`, `python3`
- A zen binary that honors **`ZEN_HOME`** (config/state directory). Build from a keep-worktrees branch, or any zen that documents `ZEN_HOME` in [configuration.md](https://github.com/mgreau/zen/blob/main/docs/configuration.md).
- Write access to **your fork** of this repo (or this repo, if you are a collaborator). The script opens PRs on `origin`.

You do not need Aider, Terminal.app, or your daily `~/.zen/config.yaml`. The script writes a throwaway config (`agent: claude`, `terminal: iterm`).

Watch/inbox scenarios use [`.github/workflows/open-review-pr.yml`](.github/workflows/open-review-pr.yml). The repo must allow GitHub Actions to create PRs:

Settings → Actions → General → Workflow permissions → **Read and write** and **Allow GitHub Actions to create and approve pull requests**.

On a new GitHub repo the default is read-only; `gh api --method PUT /repos/<you>/zen-tests/actions/permissions/workflow -f default_workflow_permissions=write` is the API equivalent.

## Run

Fork or clone this repo so `origin` is a GitHub remote you can push to.

```bash
git clone git@github.com:<you>/zen-tests.git
cd zen-tests

# zen built from the branch under test
export ZEN_BIN=/path/to/zen

./scripts/keep-worktrees.sh
```

If `ZEN_BIN` is unset, the script looks for `../zen-keep-worktrees/zen` then `../zen/zen`.

The run directory is `.run/` (gitignored): isolated zen home, origin clone, logs.

## Why an Actions bot PR?

`zen watch` only sees PRs in `review-requested:@me` (or re-review). You cannot request a review from yourself, so a PR you open never hits the inbox. [`.github/workflows/open-review-pr.yml`](.github/workflows/open-review-pr.yml) opens a PR as `github-actions[bot]` and requests the repo owner.

CLI catch-up (`zen review`) does not need that; those PRs are opened as you.

## Others

1. Fork `zen-tests` (do not open test PRs against someone else's copy if you can avoid it).
2. Enable Actions on the fork (Actions tab → enable workflows) so `open-review-pr` can run.
3. Point `ZEN_BIN` at the zen you are testing.
4. Run `./scripts/keep-worktrees.sh`.
