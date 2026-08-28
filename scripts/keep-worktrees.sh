#!/usr/bin/env bash
# Functional keep-worktrees tests against this repo (not mgreau/zen).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export GH_PAGER=cat
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

need git
need gh
need python3

PASSES=0
FAILS=0
FAILURES=()
CLEANUP_PRS=()
FAKE_CLAUDE_PID=""
WATCH_STARTED=0

RUN_ID=$(date +%Y%m%d%H%M%S)-$$
REPO_SHORT=ztest
ZEN_HOME="$ROOT/.run/zen-home"
BASE_PATH="$ZEN_HOME/repos"
ORIGIN_CLONE="$BASE_PATH/$REPO_SHORT"
LOG="$ROOT/.run/keep-worktrees.log"
mkdir -p "$ROOT/.run"

if [[ -z "${ZEN_BIN:-}" ]]; then
	for cand in "$ROOT/../zen-keep-worktrees/zen" "$ROOT/../zen/zen"; do
		if [[ -x "$cand" ]]; then
			ZEN_BIN=$cand
			break
		fi
	done
fi
if [[ -z "${ZEN_BIN:-}" || ! -x "$ZEN_BIN" ]]; then
	echo "set ZEN_BIN to a zen binary that honors ZEN_HOME" >&2
	exit 1
fi

FULL_NAME=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
ORIGIN_URL=$(git -C "$ROOT" remote get-url origin)
LOGIN=$(gh api user --jq .login)
export FULL_NAME ORIGIN_URL LOGIN ROOT ZEN_HOME BASE_PATH ORIGIN_CLONE REPO_SHORT ZEN_BIN

exec > >(tee -a "$LOG") 2>&1
echo "zen-tests keep-worktrees  run=$RUN_ID"
echo "zen=$ZEN_BIN  repo=$FULL_NAME  user=$LOGIN  ZEN_HOME=$ZEN_HOME"

cleanup() {
	set +e
	if [[ -n "$FAKE_CLAUDE_PID" ]]; then
		kill "$FAKE_CLAUDE_PID" 2>/dev/null
	fi
	if ((WATCH_STARTED)); then
		zen watch stop >/dev/null 2>&1
	fi
	git -C "$ROOT" checkout -q main 2>/dev/null || git -C "$ROOT" checkout -q HEAD
	local n
	for n in "${CLEANUP_PRS[@]:-}"; do
		close_pr "$n"
	done
}
trap cleanup EXIT

rm -rf "$ZEN_HOME"
mkdir -p "$ZEN_HOME/state" "$BASE_PATH"
ensure_origin_clone

# --- CLI path (self-authored PR; watch will not see it) ---
write_config "$(authors_yaml_lines "$LOGIN")"
CLI_MARKER="${RUN_ID}"
CLI_PR=$(open_cli_pr "$CLI_MARKER")
if [[ -z "$CLI_PR" || "$CLI_PR" == *[!0-9]* ]]; then
	echo "open_cli_pr failed: ${CLI_PR:-empty}" >&2
	exit 1
fi
CLEANUP_PRS+=("$CLI_PR")
CLI_BRANCH="harness/cli-${CLI_MARKER}"
echo "CLI PR #$CLI_PR ($CLI_BRANCH)"

wait_for "GitHub head SHA for #$CLI_PR" 60 pr_moved "$CLI_PR" "" || fail "no GitHub SHA for #$CLI_PR"
OID_A=$(pr_oid "$CLI_PR")

if ! zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/tmp/zen-review-a.json; then
	fail "zen review create #$CLI_PR"
else
	pass "zen review created worktree for #$CLI_PR"
fi

WT=$(worktree_path "$CLI_PR")
if [[ ! -d "$WT" ]]; then
	fail "worktree missing at $WT"
else
	pass "worktree exists $WT"
fi

if [[ "$(sha_head "$WT")" != "$OID_A" ]]; then
	fail "worktree HEAD $(sha_head "$WT") != GitHub $OID_A"
else
	pass "worktree on SHA A"
fi

if [[ ! -f "$WT/CLAUDE.local.md" ]]; then
	fail "CLAUDE.local.md not injected"
else
	pass "context injected"
fi
CTX_A=$(cksum <"$WT/CLAUDE.local.md" | awk '{print $1}')

# New file so rendered context (changed-file list) is not identical to A.
git -C "$ROOT" checkout -q "$CLI_BRANCH"
printf 'b-file %s\n' "$CLI_MARKER" >"$ROOT/b-${CLI_MARKER}.txt"
git -C "$ROOT" add "b-${CLI_MARKER}.txt"
git -C "$ROOT" commit -q -m "harness: CLI SHA B ${CLI_MARKER}"
git -C "$ROOT" push -q origin "$CLI_BRANCH"
wait_for "GitHub SHA B for #$CLI_PR" 60 pr_moved "$CLI_PR" "$OID_A" || fail "GitHub did not move to SHA B"
OID_B=$(pr_oid "$CLI_PR")

zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/tmp/zen-review-b.json || fail "zen review refresh #$CLI_PR"
if [[ "$(sha_head "$WT")" != "$OID_B" ]]; then
	fail "after push, worktree HEAD $(sha_head "$WT") != $OID_B"
else
	pass "worktree fast-forwarded to SHA B"
fi
CTX_B=$(cksum <"$WT/CLAUDE.local.md" | awk '{print $1}')
if [[ "$CTX_A" == "$CTX_B" ]]; then
	fail "CLAUDE.local.md unchanged after HEAD move"
else
	pass "context rewritten on SHA move"
fi

# Dirty skip
printf '\nlocal dirty\n' >>"$WT/hello.txt"
push_pr_commit "$CLI_BRANCH" "harness: CLI SHA C while dirty ${CLI_MARKER}"
wait_for "GitHub SHA C for #$CLI_PR" 60 pr_moved "$CLI_PR" "$OID_B" || fail "GitHub did not move to SHA C"
OID_C=$(pr_oid "$CLI_PR")
zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/tmp/zen-review-dirty.json || true
if [[ "$(sha_head "$WT")" != "$OID_B" ]]; then
	fail "dirty worktree was moved (HEAD $(sha_head "$WT"), wanted still $OID_B)"
else
	pass "dirty worktree not fast-forwarded"
fi
if ! grep -q "local dirty" "$WT/hello.txt"; then
	fail "local dirty edit was discarded"
else
	pass "local dirty edit kept"
fi
# restore for later scenarios
git -C "$WT" checkout -q -- hello.txt

# Catch up now that the tree is clean (onto C)
zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/dev/null
if [[ "$(sha_head "$WT")" != "$OID_C" ]]; then
	fail "clean refresh to C: HEAD $(sha_head "$WT") != $OID_C"
else
	pass "clean worktree caught up to C"
fi

# Live agent skip: binary named claude in the worktree cwd. macOS ps comm is a
# path; zen matches filepath.Base. lsof -c matches the executable name.
mkdir -p "$ZEN_HOME/bin"
printf '#include <unistd.h>\nint main(void) { for (;;) sleep(60); return 0; }\n' | cc -o "$ZEN_HOME/bin/claude" -x c - || {
	fail "could not compile fake claude (need a C compiler)"
}
push_pr_commit "$CLI_BRANCH" "harness: CLI SHA D while agent ${CLI_MARKER}"
wait_for "GitHub SHA D for #$CLI_PR" 60 pr_moved "$CLI_PR" "$OID_C" || fail "GitHub did not move to SHA D"
OID_D=$(pr_oid "$CLI_PR")
(cd "$WT" && "$ZEN_HOME/bin/claude") &
FAKE_CLAUDE_PID=$!
claude_in_wt() { lsof -nP -a -d cwd -c claude -Fn 2>/dev/null | grep -Fq "$WT"; }
wait_for "lsof sees claude in worktree" 15 claude_in_wt || {
	fail "lsof did not see fake claude (pid $FAKE_CLAUDE_PID comm=$(ps -p $FAKE_CLAUDE_PID -o comm= 2>/dev/null))"
}
zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/tmp/zen-review-agent.json || true
if [[ "$(sha_head "$WT")" != "$OID_C" ]]; then
	fail "live agent: worktree moved (HEAD $(sha_head "$WT"))"
else
	pass "live agent skipped fast-forward"
fi
kill "$FAKE_CLAUDE_PID" 2>/dev/null || true
FAKE_CLAUDE_PID=""
sleep 3
zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/dev/null
if [[ "$(sha_head "$WT")" != "$OID_D" ]]; then
	fail "after agent exit, HEAD $(sha_head "$WT") != $OID_D"
else
	pass "after agent exit, worktree caught up to D"
fi

# Force-push: --json never resets; y on TTY does
git -C "$ROOT" checkout -q "$CLI_BRANCH"
git -C "$ROOT" reset -q --hard HEAD~1
printf 'rewritten %s\n' "$CLI_MARKER" >"$ROOT/hello.txt"
git -C "$ROOT" add hello.txt
git -C "$ROOT" commit -q -m "harness: rewritten GitHub head ${CLI_MARKER}"
git -C "$ROOT" push -q --force-with-lease origin "$CLI_BRANCH"
wait_for "rewritten GitHub SHA for #$CLI_PR" 60 pr_moved "$CLI_PR" "$OID_D" || fail "GitHub did not rewrite the PR head"
OID_R=$(pr_oid "$CLI_PR")
HEAD_BEFORE_RESET=$(sha_head "$WT")
zen review "$CLI_PR" --repo "$REPO_SHORT" --json --no-terminal >/tmp/zen-review-nff.json || true
if [[ "$(sha_head "$WT")" != "$HEAD_BEFORE_RESET" ]]; then
	fail "--json reset the rewritten worktree"
else
	pass "--json did not reset --hard"
fi
printf 'y\n' | zen review "$CLI_PR" --repo "$REPO_SHORT" --no-terminal >/tmp/zen-review-reset.txt || true
if [[ "$(sha_head "$WT")" != "$OID_R" ]]; then
	fail "confirmed reset: HEAD $(sha_head "$WT") != $OID_R"
else
	pass "confirmed reset moved worktree onto rewritten head"
fi

# --- Watch / inbox (bot PR so we are a requested reviewer) ---
echo "Opening bot PRs via Actions (review-requested:@me)..."
BOT_A_MARKER="botA-${RUN_ID}"
BOT_B_MARKER="botB-${RUN_ID}"
BOT_A=$(open_bot_pr "$BOT_A_MARKER")
CLEANUP_PRS+=("$BOT_A")
echo "bot PR A #$BOT_A"

# Notify: first sighting, author not in authors:, no worktree
write_config "$(authors_yaml_lines "$LOGIN")"
zen watch start
WATCH_STARTED=1
sleep 2
wait_for "notify log for #$BOT_A" 90 grep -q "New PR review request: #${BOT_A}" "$ZEN_HOME/state/watch.log" || fail "timeout waiting for inbox notify #$BOT_A"
if grep -q "New PR review request: #${BOT_A}" "$ZEN_HOME/state/watch.log"; then
	pass "inbox notified for non-author PR #$BOT_A"
else
	fail "no inbox notify for #$BOT_A"
fi
BOT_A_WT=$(worktree_path "$BOT_A")
if [[ -d "$BOT_A_WT" ]]; then
	fail "watch created a worktree for non-author #$BOT_A"
else
	pass "authors: gates create (no worktree for #$BOT_A)"
fi

# Upgrade: seen_prs absorbs current inbox; no second "new" for a PR already listed
zen watch stop
WATCH_STARTED=0
BOT_B=$(open_bot_pr "$BOT_B_MARKER")
CLEANUP_PRS+=("$BOT_B")
echo "bot PR B #$BOT_B (legacy seen_prs)"
python3 - <<PY
import json, os, time
p = os.path.join("$ZEN_HOME", "state", "last_check.json")
json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "pr_count": 1, "seen_prs": ["1"]}, open(p, "w"), indent=2)
PY
: >"$ZEN_HOME/state/watch.log"
zen watch start
WATCH_STARTED=1
sleep 25
if grep -q "New PR review request: #${BOT_B}" "$ZEN_HOME/state/watch.log"; then
	fail "upgrade re-notified #$BOT_B despite seen_prs"
else
	pass "seen_prs upgrade did not re-announce #$BOT_B"
fi

# Create + FF: put the bot in authors:
zen watch stop
WATCH_STARTED=0
write_config "$(authors_yaml_lines "$LOGIN" "github-actions[bot]")"
: >"$ZEN_HOME/state/watch.log"
# already notified_new from previous polls; drop state so create still runs
# (create does not depend on notified_new). Keep applied_shas empty.
python3 - <<PY
import json, os, time
p = os.path.join("$ZEN_HOME", "state", "last_check.json")
json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "pr_count": 0, "notified_new": ["${REPO_SHORT}:${BOT_A}", "${REPO_SHORT}:${BOT_B}"]}, open(p, "w"), indent=2)
PY
zen watch start
WATCH_STARTED=1
BOT_B_WT=$(worktree_path "$BOT_B")
wait_for "watch created worktree #$BOT_B" 120 test -d "$BOT_B_WT" || fail "timeout waiting for worktree #$BOT_B"
if [[ -d "$BOT_B_WT" ]]; then
	pass "watch created worktree for bot author #$BOT_B"
else
	fail "watch did not create $BOT_B_WT"
fi
OID_BOT_B0=$(sha_head "$BOT_B_WT")
BOT_B_BRANCH=$(gh pr view "$BOT_B" --repo "$FULL_NAME" --json headRefName --jq .headRefName)
git -C "$ROOT" fetch -q origin "$BOT_B_BRANCH"
git -C "$ROOT" checkout -q -B "$BOT_B_BRANCH" "origin/$BOT_B_BRANCH"
push_pr_commit "$BOT_B_BRANCH" "harness: bot SHA move ${BOT_B_MARKER}"
wait_for "GitHub SHA move #$BOT_B" 60 pr_moved "$BOT_B" "$OID_BOT_B0" || fail "bot PR did not move on GitHub"
wait_for "watch FF #$BOT_B" 90 heads_match "$BOT_B_WT" "$BOT_B" || fail "watch did not fast-forward #$BOT_B"
if [[ "$(sha_head "$BOT_B_WT")" == "$(pr_oid "$BOT_B")" ]]; then
	pass "watch fast-forwarded #$BOT_B"
else
	fail "watch did not FF #$BOT_B (HEAD $(sha_head "$BOT_B_WT") GitHub $(pr_oid "$BOT_B"))"
fi

# Draft → push → undraft: one refresh, not a new notify
: >"$ZEN_HOME/state/watch.log"
gh api -X PATCH "repos/${FULL_NAME}/pulls/${BOT_B}" -f draft=true >/dev/null
sleep 20
OID_DRAFT=$(sha_head "$BOT_B_WT")
push_pr_commit "$BOT_B_BRANCH" "harness: bot while draft ${BOT_B_MARKER}"
sleep 25
if [[ "$(sha_head "$BOT_B_WT")" != "$OID_DRAFT" ]]; then
	fail "watch moved a draft while ignore_drafts is true"
else
	pass "watch left draft #$BOT_B alone"
fi
gh api -X PATCH "repos/${FULL_NAME}/pulls/${BOT_B}" -F draft=false >/dev/null
wait_for "watch catch-up after undraft #$BOT_B" 90 heads_match "$BOT_B_WT" "$BOT_B" || fail "watch did not catch up after undraft"
if [[ "$(sha_head "$BOT_B_WT")" == "$(pr_oid "$BOT_B")" ]]; then
	pass "watch caught up after undraft"
else
	fail "undraft did not catch up #$BOT_B"
fi
if grep -q "New PR review request: #${BOT_B}" "$ZEN_HOME/state/watch.log"; then
	fail "undraft re-fired new-review notify for #$BOT_B"
else
	pass "undraft did not send a second new-review notify"
fi

zen watch stop
WATCH_STARTED=0

echo
echo "passed=$PASSES  failed=$FAILS"
if ((FAILS)); then
	printf '  - %s\n' "${FAILURES[@]}"
	exit 1
fi
echo "keep-worktrees functional scenarios passed against $FULL_NAME"
