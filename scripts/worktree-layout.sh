#!/usr/bin/env bash
# Functional tests for worktree_layout (zen: sibling vs nested placement).
#
# Fully local: no gh, no GitHub, no PRs. "origin" is a bare repo under .run/,
# which is all `zen work new` needs (it fetches origin/main and adds a
# worktree). The PR-review paths are covered by unit tests in zen itself.
#
# Isolation: zen on main derives its config directory from $HOME, and does not
# read $ZEN_HOME (that lives on an unmerged branch). So every zen invocation
# here runs with HOME pointed at a sandbox under .run/ -- which also keeps
# ~/.claude/projects out of the way, since zen scans it for agent sessions.
# The real ~/.zen is never read or written, and the last test asserts that.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

need git

PASSES=0
FAILS=0
FAILURES=()

RUN="$ROOT/.run/worktree-layout"
SANDBOX="$RUN/home"
BASE="$SANDBOX/repos"
UPSTREAM="$RUN/upstream.git"
CLONE="$BASE/ztest"
CLONE2="$BASE/ztest2"
LOG="$ROOT/.run/worktree-layout.log"

if [[ -z "${ZEN_BIN:-}" ]]; then
	for cand in "$ROOT/../zen-docs-nested-worktrees/zen" "$ROOT/../zen/zen"; do
		if [[ -x "$cand" ]]; then
			ZEN_BIN=$cand
			break
		fi
	done
fi
if [[ -z "${ZEN_BIN:-}" || ! -x "$ZEN_BIN" ]]; then
	echo "set ZEN_BIN to a zen binary built from the branch under test" >&2
	exit 1
fi

mkdir -p "$ROOT/.run"
exec > >(tee -a "$LOG") 2>&1
echo "zen-tests worktree-layout  run=$(date +%Y%m%d%H%M%S)"
echo "zen=$ZEN_BIN  sandbox HOME=$SANDBOX"

# Fingerprint the real zen state up front so the last test can prove the run
# left it alone. Captured before anything else runs.
REAL_ZEN="$HOME/.zen"
real_fingerprint() {
	if [[ -d "$REAL_ZEN" ]]; then
		find "$REAL_ZEN" -type f -exec shasum {} \; 2>/dev/null | sort
	fi
}
REAL_BEFORE=$(real_fingerprint)

# zen() from lib.sh isolates via ZEN_HOME, which this binary does not read.
# Override it with a HOME sandbox, which it does.
zen() {
	HOME="$SANDBOX" \
		GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig" \
		"$ZEN_BIN" "$@"
}

git_sandbox() { GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig" git "$@"; }

# write_config <global-layout|-> [ztest2-layout|-]
# "-" omits the key entirely, which is how an untouched config behaves.
write_config() {
	local global=$1 repo2=${2:--}
	mkdir -p "$SANDBOX/.zen/state"
	# Note: `[[ cond ]] && echo` as the last statement of the block returns
	# non-zero when cond is false, which under `set -e` would abort the run.
	{
		echo "repos:"
		echo "  ztest:"
		echo "    full_name: acme/ztest"
		echo "    base_path: ${BASE}"
		echo "  ztest2:"
		echo "    full_name: acme/ztest2"
		echo "    base_path: ${BASE}"
		if [[ "$repo2" != "-" ]]; then
			echo "    worktree_layout: ${repo2}"
		fi
		echo "authors: []"
		echo "agent: claude"
		echo "terminal: iterm"
		echo "branch_prefix: harness"
		if [[ "$global" != "-" ]]; then
			echo "worktree_layout: ${global}"
		fi
	} >"$SANDBOX/.zen/config.yaml"
}

seed_upstream() {
	local seed="$RUN/seed"
	git init -q --bare -b main "$UPSTREAM"
	git init -q -b main "$seed"
	git_sandbox -C "$seed" config user.email harness@example.com
	git_sandbox -C "$seed" config user.name Harness
	echo "hello" >"$seed/hello.txt"
	git_sandbox -C "$seed" add hello.txt
	git_sandbox -C "$seed" commit -q -m "initial"
	git_sandbox -C "$seed" remote add origin "$UPSTREAM"
	git_sandbox -C "$seed" push -q -u origin main
	rm -rf "$seed"
}

exists() { [[ -e "$1" ]]; }

echo "--- setup"
rm -rf "$RUN"
mkdir -p "$SANDBOX/.zen/state" "$BASE"
cat >"$SANDBOX/.gitconfig" <<'EOF'
[user]
	name = Harness
	email = harness@example.com
[init]
	defaultBranch = main
EOF
seed_upstream
git_sandbox clone -q "$UPSTREAM" "$CLONE"
git_sandbox clone -q "$UPSTREAM" "$CLONE2"

echo
echo "--- T1: default config places worktrees beside the clone"
write_config -
if ! out=$(zen work new ztest feat-a --no-terminal 2>&1); then
	fail "zen work new (default layout) failed: $out"
fi
if exists "$BASE/ztest-feat-a"; then
	pass "default layout created $BASE/ztest-feat-a"
else
	fail "default layout did not create the sibling worktree"
fi
if exists "$CLONE/_worktrees"; then
	fail "default layout created _worktrees/ inside the clone"
else
	pass "default layout left the clone untouched"
fi
if grep -q "_worktrees" "$CLONE/.git/info/exclude" 2>/dev/null; then
	fail "default layout wrote _worktrees to info/exclude"
else
	pass "default layout wrote nothing to info/exclude"
fi

echo
echo "--- T2: nested places worktrees inside the clone, invisibly to git"
write_config nested
if ! out=$(zen work new ztest feat-b --no-terminal 2>&1); then
	fail "zen work new (nested) failed: $out"
fi
if exists "$CLONE/_worktrees/ztest-feat-b"; then
	pass "nested layout created $CLONE/_worktrees/ztest-feat-b"
else
	fail "nested layout did not create the worktree inside the clone"
fi
status=$(git_sandbox -C "$CLONE" status --porcelain)
if [[ -z "$status" ]]; then
	pass "git status in the clone is clean"
else
	fail "git status in the clone is dirty: $status"
fi
if git_sandbox -C "$CLONE" check-ignore -q "_worktrees/"; then
	pass "git check-ignore confirms _worktrees/ is ignored"
else
	fail "git does not ignore _worktrees/"
fi
if [[ -f "$CLONE/.gitignore" ]]; then
	fail "zen created a committed .gitignore"
else
	pass "committed .gitignore was not touched"
fi

echo
echo "--- T3: transition -- a sibling worktree is still found under nested"
# feat-a was created in T1 under the old layout. With nested configured, zen
# must resolve it where it actually is rather than computing a nested path,
# finding nothing, and attempting a duplicate `git worktree add`.
out=$(zen work new ztest feat-a --no-terminal 2>&1 || true)
if grep -q "already exists" <<<"$out" && grep -q "$BASE/ztest-feat-a" <<<"$out"; then
	pass "zen found the sibling worktree at its real path"
else
	fail "zen did not resolve the pre-existing sibling worktree; got: $out"
fi
if exists "$CLONE/_worktrees/ztest-feat-a"; then
	fail "zen created a duplicate nested worktree for feat-a"
else
	pass "no duplicate worktree was created"
fi
listing=$(zen work 2>&1 || true)
if grep -q "ztest-feat-a" <<<"$listing" && grep -q "ztest-feat-b" <<<"$listing"; then
	pass "both layouts are listed side by side during the drain"
else
	fail "zen work did not list both worktrees; got: $listing"
fi

echo
echo "--- T4: per-repo override beats the global default"
write_config nested sibling
if ! out=$(zen work new ztest2 feat-c --no-terminal 2>&1); then
	fail "zen work new (per-repo override) failed: $out"
fi
if exists "$BASE/ztest2-feat-c"; then
	pass "per-repo sibling override created $BASE/ztest2-feat-c"
else
	fail "per-repo override did not take effect"
fi
if exists "$CLONE2/_worktrees"; then
	fail "per-repo override still nested the worktree"
else
	pass "overridden repo has no _worktrees/"
fi

echo
echo "--- T5: an invalid layout is rejected at load, not silently defaulted"
write_config bogus
out=$(zen work new ztest feat-d --no-terminal 2>&1 || true)
if grep -qi "worktree_layout" <<<"$out"; then
	pass "invalid worktree_layout rejected with a clear message"
else
	fail "invalid worktree_layout was not reported; got: $out"
fi
if exists "$BASE/ztest-feat-d" || exists "$CLONE/_worktrees/ztest-feat-d"; then
	fail "a worktree was created despite an invalid config"
else
	pass "no worktree created from an invalid config"
fi

echo
echo "--- T6: the real ~/.zen and real checkouts were never touched"
if [[ "$(real_fingerprint)" == "$REAL_BEFORE" ]]; then
	pass "real $REAL_ZEN is byte-for-byte unchanged"
else
	fail "real $REAL_ZEN was modified by this run"
fi
leaked=()
for d in "$HOME/src/zen" "$HOME/src/flox-skills"; do
	[[ -e "$d/_worktrees" ]] && leaked+=("$d/_worktrees")
done
if ((${#leaked[@]} == 0)); then
	pass "no _worktrees/ appeared in real checkouts"
else
	fail "run leaked into real checkouts: ${leaked[*]}"
fi

echo
echo "passes=$PASSES fails=$FAILS"
if ((FAILS > 0)); then
	printf '  %s\n' "${FAILURES[@]}" >&2
	exit 1
fi
