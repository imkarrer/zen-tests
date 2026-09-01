.PHONY: keep-worktrees worktree-layout

# ZEN_BIN must be a zen that honors ZEN_HOME (see README).
keep-worktrees:
	./scripts/keep-worktrees.sh

# Local-only; needs no gh and no ZEN_HOME support (see README).
worktree-layout:
	./scripts/worktree-layout.sh
