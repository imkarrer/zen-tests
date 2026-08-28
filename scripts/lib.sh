#!/usr/bin/env bash
# Shared helpers for zen-tests scripts.

pass() { echo "PASS  $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL  $*" >&2; FAILS=$((FAILS + 1)); FAILURES+=("$*"); }
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }

wait_for() {
	local desc=$1 timeout=$2
	shift 2
	local i=0
	while ((i < timeout)); do
		if "$@"; then
			return 0
		fi
		sleep 2
		i=$((i + 2))
	done
	echo "timeout (${timeout}s): $desc" >&2
	return 1
}

sha_head() { git -C "$1" rev-parse HEAD; }

# GitHub head SHA for a PR number on $FULL_NAME.
pr_oid() {
	gh api "repos/${FULL_NAME}/pulls/$1" --jq .head.sha
}

worktree_path() {
	echo "${BASE_PATH}/${REPO_SHORT}-pr-$1"
}

zen() {
	ZEN_HOME="$ZEN_HOME" "$ZEN_BIN" "$@"
}

write_config() {
	local authors_yaml=$1
	mkdir -p "$ZEN_HOME/state" "$BASE_PATH"
	cat >"$ZEN_HOME/config.yaml" <<EOF
repos:
  ${REPO_SHORT}:
    full_name: ${FULL_NAME}
    base_path: ${BASE_PATH}
authors:
${authors_yaml}
poll_interval: 15s
agent: claude
terminal: iterm
ignore_drafts: true
watch:
  dispatch_interval: 5s
  cleanup_interval: 1h
  session_scan_interval: 10s
  cleanup_after_days: 5
  concurrency: 1
  max_retries: 3
EOF
}

authors_yaml_lines() {
	local a
	for a in "$@"; do
		printf '  - %s\n' "$a"
	done
}

ensure_origin_clone() {
	if [[ ! -d "$ORIGIN_CLONE/.git" ]]; then
		git clone "$ORIGIN_URL" "$ORIGIN_CLONE"
	else
		git -C "$ORIGIN_CLONE" fetch origin
		git -C "$ORIGIN_CLONE" checkout -q --detach origin/HEAD 2>/dev/null || git -C "$ORIGIN_CLONE" checkout -q main
	fi
}

# True when GitHub's PR head SHA is set and not equal to $2 (a previous SHA).
pr_moved() {
	local got
	got=$(pr_oid "$1")
	[[ -n "$got" && "$got" != "$2" ]]
}

heads_match() {
	[[ $(sha_head "$1") == $(pr_oid "$2") ]]
}

# Open a self-authored PR from $ROOT. Prints the PR number.
open_cli_pr() {
	local marker=$1
	local branch="harness/cli-${marker}"
	git -C "$ROOT" checkout -q -B "$branch" origin/HEAD
	printf '\ncli %s A\n' "$marker" >>"$ROOT/hello.txt"
	git -C "$ROOT" add hello.txt
	git -C "$ROOT" commit -q -m "harness: CLI SHA A ${marker}"
	git -C "$ROOT" push -q -u origin "$branch"
	local url
	url=$(gh pr create --repo "$FULL_NAME" --head "$branch" --title "harness cli ${marker}" \
		--body "zen-tests CLI catch-up. Safe to close.")
	gh pr view "$url" --json number --jq .number
}

push_pr_commit() {
	local branch=$1
	local msg=$2
	git -C "$ROOT" checkout -q "$branch"
	printf '\n%s\n' "$msg" >>"$ROOT/hello.txt"
	git -C "$ROOT" add hello.txt
	git -C "$ROOT" commit -q -m "$msg"
	git -C "$ROOT" push -q origin "$branch"
}

# Trigger Actions to open a bot PR; print its number.
open_bot_pr() {
	local marker=$1
	local i=0
	while ((i < 90)); do
		if gh workflow run open-review-pr.yml --repo "$FULL_NAME" -f "marker=${marker}" 2>/dev/null; then
			break
		fi
		sleep 5
		i=$((i + 5))
	done
	if ((i >= 90)); then
		echo "could not dispatch open-review-pr.yml (enable Actions on $FULL_NAME?)" >&2
		return 1
	fi
	local n=""
	i=0
	while ((i < 180)); do
		n=$(gh pr list --repo "$FULL_NAME" --search "harness review ${marker} in:title" --state open --json number --jq '.[0].number // empty' || true)
		if [[ -n "$n" ]]; then
			echo "$n"
			return 0
		fi
		sleep 5
		i=$((i + 5))
	done
	echo "timeout waiting for bot PR title 'harness review ${marker}'" >&2
	return 1
}

close_pr() {
	local n=$1
	gh pr close "$n" --repo "$FULL_NAME" --delete-branch --comment "zen-tests run ${RUN_ID} finished." >/dev/null 2>&1 || true
}
