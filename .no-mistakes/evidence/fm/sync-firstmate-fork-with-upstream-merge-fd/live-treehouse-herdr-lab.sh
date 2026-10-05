#!/usr/bin/env bash
# Live validation driver (no-mistakes test phase, not committed to the repo).
# Drives the REAL bin/fm-spawn.sh / bin/fm-teardown.sh with the REAL treehouse
# CLI inside a throwaway Herdr lab session owned by bin/fm-herdr-lab.sh.
#
#   L1  two Firstmate homes holding clones of ONE remote spawn workers; each
#       lands in its own per-home Treehouse root (fork fix a511c39f) and the
#       root is recorded in the task meta.
#   L2  adversarial (fork fix + review N1): a herdr task whose endpoint is
#       proven gone has its slot claimed by a live task of a FOREIGN home;
#       --relaunch must refuse BEFORE minting a herdr tab/pane, and must name
#       the recorded endpoint.
#   L3  control: with the foreign claim removed, the same relaunch rebinds and (relaunch uses --harness grok: grok is not installed, so the fresh pane is inert)
#       creates exactly one fresh pane (proves L2's refusal is the guard, not
#       a broken path).
#   L4  teardown of each task returns its slot through the recorded root.
set -u
ROOT=${ROOT:?worktree root}
LAB="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-th.XXXXXX")
SESSION=$("$LAB" name thpool)
export HERDR_SESSION="$SESSION"
export TREEHOUSE_ROOT="$TMP/treehouse-base" TREEHOUSE_NO_UPDATE_CHECK=1
mkdir -p "$TREEHOUSE_ROOT"
FAILS=0
step() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }
lab() { "$LAB" run "$SESSION" "$@"; }
pane_count() { lab pane list | jq '[.result.panes[]?] | length'; }
tab_count() { lab tab list 2>/dev/null | jq '[.result.tabs[]?] | length' 2>/dev/null; }
meta_get() { sed -n "s/^$2=//p" "$1" | tail -1; }

cleanup() {
  step cleanup
  for wt in "${WTS[@]:-}"; do [ -n "$wt" ] && [ -d "$wt" ] && \
    (cd "$wt/.." && treehouse return --force "$wt" >/dev/null 2>&1); done
  "$LAB" teardown "$SESSION" && echo "lab $SESSION torn down (tripwire verified)"
  find "$TMP" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP"
}
WTS=()
trap cleanup EXIT

step "provision lab $SESSION"
"$LAB" provision "$SESSION" || exit 1

# --- disposable world: one remote, two homes, each with its own clone --------
git init -q -b main "$TMP/seed"
printf '# scratch\n' > "$TMP/seed/README.md"
git -C "$TMP/seed" add README.md
git -C "$TMP/seed" -c user.name=T -c user.email=t@example.invalid commit -qm initial
git clone -q --bare "$TMP/seed" "$TMP/remote.git"
mkhome() {  # <home> <task>
  local h=$1 id=$2
  mkdir -p "$h/state" "$h/data/$id" "$h/config" "$h/projects"
  printf 'off\n' > "$h/config/herdr-presentation-spaces"
  printf '# Task\n## Captain'"'"'s intent\nLive pool-isolation check.\n\n## Firstmate spec\nIdle.\n' > "$h/data/$id/brief.md"
  git clone -q "file://$TMP/remote.git" "$h/projects/proj"
}
HA="$TMP/home-a"; HB="$TMP/home-b"
mkhome "$HA" ta; mkhome "$HB" tb
spawn() {  # <home> <id>
  FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$1/projects/proj" "sh -c 'echo live-$2; exec sleep 900'" \
    --mode no-mistakes --yolo off --backend herdr
}

step "L1: spawn ta from home-a and tb from home-b (clones of one remote)"
spawn "$HA" ta > "$TMP/ta.out" 2>&1; rca=$?
spawn "$HB" tb > "$TMP/tb.out" 2>&1; rcb=$?
echo "spawn ta rc=$rca"; tail -3 "$TMP/ta.out"
echo "spawn tb rc=$rcb"; tail -3 "$TMP/tb.out"
MA="$HA/state/ta.meta"; MB="$HB/state/tb.meta"
RA=$(meta_get "$MA" treehouse_root); RB=$(meta_get "$MB" treehouse_root)
WA=$(meta_get "$MA" worktree); WB=$(meta_get "$MB" worktree)
WTS=("$WA" "$WB")
echo "ta: treehouse_root=$RA"; echo "ta: worktree=$WA"
echo "tb: treehouse_root=$RB"; echo "tb: worktree=$WB"
EXA=$(FM_HOME="$HA" bash -c '. "$1"; fm_treehouse_home_root "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$HA" "$HA/projects/proj")
EXB=$(FM_HOME="$HB" bash -c '. "$1"; fm_treehouse_home_root "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$HB" "$HB/projects/proj")
if [ "$rca" = 0 ] && [ "$rcb" = 0 ] && [ -n "$RA" ] && [ -n "$RB" ] && [ "$RA" != "$RB" ] \
   && [ "$RA" = "$EXA" ] && [ "$RB" = "$EXB" ] \
   && case "$(cd "$WA" && pwd -P)" in "$(cd "$RA" && pwd -P)"/.treehouse/*) true;; *) false;; esac \
   && case "$(cd "$WB" && pwd -P)" in "$(cd "$RB" && pwd -P)"/.treehouse/*) true;; *) false;; esac; then
  ok "L1 each home allocated from its own deterministic root; worktrees live under their recorded roots"
else
  bad "L1 per-home root isolation"; cat "$TMP/ta.out" "$TMP/tb.out"
fi
echo "--- treehouse status home-a root"; (cd "$HA/projects/proj" && treehouse status --root "$RA" --json)
echo "--- treehouse status home-b root"; (cd "$HB/projects/proj" && treehouse status --root "$RB" --json)
echo "--- ta claim: $(cat "$(dirname "$WA")/.fm-slot-owner" 2>/dev/null | tr '\n' ' ')"

step "L2: endpoint gone + slot claimed by a live foreign-home task -> relaunch must refuse with no new tab"
PA=$(meta_get "$MA" herdr_pane_id); TARGET_A=$(meta_get "$MA" window)
echo "ta recorded window=$TARGET_A herdr_pane_id=$PA"
lab pane close "$PA" >/dev/null 2>&1 || echo "note: pane close returned nonzero"
sleep 1
lab pane get "$PA" >/dev/null 2>&1 && bad "ta pane still present after close"
CLAIM="$(dirname "$WA")/.fm-slot-owner"
cp "$CLAIM" "$TMP/ta-claim.orig"
printf 'task=tb\nhome=%s\n' "$HB" > "$CLAIM"
echo "foreign claim now: $(tr '\n' ' ' < "$CLAIM") (record $HB/state/tb.meta exists: $([ -f "$MB" ] && echo yes))"
echo "lab panes before relaunch: $(lab pane list | jq -c '[.result.panes[] | {pane_id, cwd}]')"
P0=$(pane_count); T0=$(tab_count)
echo "before relaunch: panes=$P0 tabs=$T0"
FM_SPAWN_NO_GUARD=1 FM_HOME="$HA" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" ta --relaunch --harness grok > "$TMP/rl1.out" 2>&1; rl1=$?
P1=$(pane_count); T1=$(tab_count)
echo "lab panes after relaunch: $(lab pane list | jq -c '[.result.panes[] | {pane_id, cwd}]')"
echo "relaunch rc=$rl1"; cat "$TMP/rl1.out"
echo "after relaunch: panes=$P1 tabs=$T1"
if [ "$rl1" -ne 0 ] && grep -q "still held by task tb of foreign home" "$TMP/rl1.out" \
   && grep -q "inspect window $TARGET_A" "$TMP/rl1.out" && [ "$P0" = "$P1" ] && [ "$T0" = "$T1" ]; then
  ok "L2 relaunch refused on the foreign live claim, named the recorded endpoint, and minted no herdr tab/pane"
else
  bad "L2 relaunch foreign-claim refusal before rebind"
fi
[ "$(meta_get "$MA" window)" = "$TARGET_A" ] && ok "L2 ta record unchanged (window=$TARGET_A)" || bad "L2 ta record mutated"

step "L3: control - restore own claim, same relaunch rebinds with exactly one fresh pane"
cp "$TMP/ta-claim.orig" "$CLAIM"
FM_SPAWN_NO_GUARD=1 FM_HOME="$HA" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" ta --relaunch --harness grok > "$TMP/rl2.out" 2>&1; rl2=$?
P2=$(pane_count)
echo "relaunch rc=$rl2"; tail -5 "$TMP/rl2.out"
echo "panes before=$P1 after=$P2; new window=$(meta_get "$MA" window) pane=$(meta_get "$MA" herdr_pane_id)"
if [ "$rl2" -eq 0 ] && [ "$P2" -eq $((P1 + 1)) ] && [ "$(meta_get "$MA" herdr_pane_id)" != "$PA" ]; then
  ok "L3 relaunch rebind works when the slot is this task's own"
else
  bad "L3 control relaunch"; cat "$TMP/rl2.out"
fi

step "L4: teardown returns each slot through its recorded root"
td() {  # <home> <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" "$ROOT/bin/fm-teardown.sh" "$2"
}
td "$HA" ta > "$TMP/tda.out" 2>&1; tda=$?
td "$HB" tb > "$TMP/tdb.out" 2>&1; tdb=$?
echo "teardown ta rc=$tda"; tail -4 "$TMP/tda.out"
echo "teardown tb rc=$tdb"; tail -4 "$TMP/tdb.out"
SA=$(cd "$HA/projects/proj" && treehouse status --root "$RA" --json)
SB=$(cd "$HB/projects/proj" && treehouse status --root "$RB" --json)
echo "--- home-a root after teardown: $SA"; echo "--- home-b root after teardown: $SB"
if [ "$tda" = 0 ] && [ "$tdb" = 0 ] && [ ! -e "$MA" ] && [ ! -e "$MB" ] \
   && printf '%s' "$SA" | jq -e 'all(.[]; .status == "available")' >/dev/null \
   && printf '%s' "$SB" | jq -e 'all(.[]; .status == "available")' >/dev/null \
   && [ ! -e "$CLAIM" ] && [ ! -e "$(dirname "$WB")/.fm-slot-owner" ]; then
  ok "L4 both slots returned through their recorded roots and claims released"
  WTS=()
else
  bad "L4 teardown through recorded root"; cat "$TMP/tda.out" "$TMP/tdb.out"
fi

step "summary: FAILS=$FAILS"
exit "$FAILS"
