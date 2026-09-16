#!/usr/bin/env bash
# Regression tests for the home-scoped Treehouse root contract
# (bin/fm-wake-lib.sh fm_treehouse_home_root / fm_treehouse_task_root, carried by
# bin/fm-spawn.sh and bin/fm-teardown.sh).
#
# Treehouse names a pool after the repository it serves, so two Firstmate homes
# holding clones of one remote - the primary and a persistent secondmate -
# resolved to ONE shared pool and could be handed each other's live slots. Every
# home now allocates from its own deterministic root, records that root in the
# task's meta, and returns through it; a record that predates the field keeps
# resolving its original pool, and a root that does not contain the slot refuses.
# A slot whose claim names a task that still has a record refuses at spawn on
# every harness and backend, not only where a harness-specific guard catches it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-isolation)
# Every Treehouse root the code under test derives lands under this base, never
# under the operator's live ~/.treehouse.
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse-base"
mkdir -p "$TREEHOUSE_ROOT"

home_root() {  # <fm-home>
  FM_HOME="$1" bash -c '. "$1"; fm_treehouse_home_root "$2"' _ "$WAKE_LIB" "$1"
}

# --- fake runtime -----------------------------------------------------------
# The fake tmux answers the pane-path poll with FM_FAKE_PANE_PATH and appends
# every send-keys line to FM_FAKE_TMUX_LOG, so the test reads the exact
# `treehouse get` line the worker's pane received.
make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # `treehouse return ...` is logged so a teardown test can read the root it used.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
printf ' <%s>' "$@" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
printf '\n' >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_home <dir> <task-id>: a Firstmate home with a brief for the task.
make_home() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise per-home Treehouse allocation for $id.

## Firstmate spec
Record the slot and its root.
EOF
  touch "$home/state/.last-watcher-beat"
}

# make_pool_slot <project> <root> <pool-name> <slot>: a Treehouse-shaped slot
# <root>/.treehouse/<pool-name>/<slot>/project, a linked worktree of <project>, with the
# pool's state file, exactly as fm_treehouse_pool_slot recognizes it.
make_pool_slot() {
  local project=$1 root=$2/.treehouse pool=$3 slot=$4 wt
  wt="$root/$pool/$slot/project"
  mkdir -p "$root/$pool/$slot"
  git -C "$project" worktree add -q --detach "$wt"
  printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$wt" > "$root/$pool/treehouse-state.json"
  printf '%s\n' "$wt"
}

run_spawn() {  # <home> <project> <id> <pane-path> <fakebin> <tmux-log>
  local home=$1 project=$2 id=$3 pane=$4 fakebin=$5 log=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_TMUX_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off 2>&1
}

run_teardown() {  # <home> <id> <fakebin> <treehouse-log>
  local home=$1 id=$2 fakebin=$3 log=$4
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_TREEHOUSE_LOG="$log" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force
}

# --- root contract ----------------------------------------------------------

test_home_root_is_deterministic_distinct_and_canonical() {
  local dir=$TMP_ROOT/root-contract a b again via_link
  mkdir -p "$dir/home-a" "$dir/home-b"
  ln -s "$dir/home-a" "$dir/home-a-link"
  a=$(home_root "$dir/home-a") || fail "home root for home-a did not resolve"
  b=$(home_root "$dir/home-b") || fail "home root for home-b did not resolve"
  again=$(home_root "$dir/home-a") || fail "second home root for home-a did not resolve"
  via_link=$(home_root "$dir/home-a-link") || fail "home root through a symlink did not resolve"
  [ "$a" = "$again" ] || fail "home root is not deterministic: $a vs $again"
  [ "$a" = "$via_link" ] || fail "home root differs through a symlink to the same home: $a vs $via_link"
  [ "$a" != "$b" ] || fail "two homes resolved to the same Treehouse root: $a"
  case "$a" in
    "$TREEHOUSE_ROOT"/fm-home-[0-9a-f]*) ;;
    *) fail "home root is not <base>/fm-home-<hash> under TREEHOUSE_ROOT: $a" ;;
  esac
  case "$a" in *[!A-Za-z0-9/._-]*) fail "home root carries characters unsafe for a path: $a" ;; esac
  pass "fm_treehouse_home_root: deterministic per canonical home, distinct across homes, path-safe under the Treehouse base"
}

# --- two homes, one remote --------------------------------------------------

# The live incident: the primary and a secondmate each hold a clone of the same
# remote. Each spawn must ask Treehouse for a slot under its own home's root and
# record that root; the two roots must differ although the repositories share a
# remote and a name.
test_two_homes_with_clones_of_one_repo_allocate_to_different_roots() {
  local dir=$TMP_ROOT/two-homes upstream fakebin
  local home_a=$dir/home-a home_b=$dir/home-b proj_a proj_b root_a root_b wt_a wt_b out
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  fm_git_init_commit "$dir/upstream"
  upstream="$dir/upstream"
  make_home "$home_a" task-a
  make_home "$home_b" task-b
  git clone -q "$upstream" "$home_a/projects/shared-repo"
  git clone -q "$upstream" "$home_b/projects/shared-repo"
  proj_a="$home_a/projects/shared-repo"
  proj_b="$home_b/projects/shared-repo"
  root_a=$(home_root "$home_a") || fail "root for home-a did not resolve"
  root_b=$(home_root "$home_b") || fail "root for home-b did not resolve"
  [ "$root_a" != "$root_b" ] || fail "clones of one repo in two homes resolved to one root: $root_a"
  # Treehouse would name both pools identically; place each under its home's root.
  wt_a=$(make_pool_slot "$proj_a" "$root_a" shared-repo-e814d1 1)
  wt_b=$(make_pool_slot "$proj_b" "$root_b" shared-repo-e814d1 1)

  out=$(run_spawn "$home_a" "$proj_a" task-a "$wt_a" "$fakebin" "$dir/tmux-a.log") \
    || fail "spawn from home-a failed: $out"
  out=$(run_spawn "$home_b" "$proj_b" task-b "$wt_b" "$fakebin" "$dir/tmux-b.log") \
    || fail "spawn from home-b failed: $out"

  grep -Fq "treehouse get --root '$root_a'" "$dir/tmux-a.log" \
    || fail "home-a's pane did not receive treehouse get --root '$root_a': $(cat "$dir/tmux-a.log")"
  grep -Fq "treehouse get --root '$root_b'" "$dir/tmux-b.log" \
    || fail "home-b's pane did not receive treehouse get --root '$root_b': $(cat "$dir/tmux-b.log")"
  ! grep -Fq "$root_b" "$dir/tmux-a.log" || fail "home-a's pane was pointed at home-b's root"
  assert_grep "treehouse_root=$root_a" "$home_a/state/task-a.meta" "home-a's record did not carry its Treehouse root"
  assert_grep "treehouse_root=$root_b" "$home_b/state/task-b.meta" "home-b's record did not carry its Treehouse root"
  assert_grep "worktree=$wt_a" "$home_a/state/task-a.meta" "home-a's record did not carry its slot"
  assert_grep "task=task-a" "$root_a/.treehouse/shared-repo-e814d1/1/.fm-slot-owner" "home-a's slot was not claimed for task-a"
  assert_grep "task=task-b" "$root_b/.treehouse/shared-repo-e814d1/1/.fm-slot-owner" "home-b's slot was not claimed for task-b"
  pass "fm-spawn: two homes with clones of one repo allocate under two distinct home-scoped Treehouse roots and record them"
}

# --- teardown through the recorded root -------------------------------------

test_teardown_returns_through_recorded_root() {
  local dir=$TMP_ROOT/teardown-recorded home=$TMP_ROOT/teardown-recorded/home fakebin root wt
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  make_home "$home" task-r
  fm_git_init_commit "$home/projects/repo"
  root=$(home_root "$home") || fail "root did not resolve"
  wt=$(make_pool_slot "$home/projects/repo" "$root" repo-abc123 1)
  printf 'task=task-r\nhome=%s\n' "$home" > "$root/.treehouse/repo-abc123/1/.fm-slot-owner"
  fm_write_meta "$home/state/task-r.meta" \
    "window=firstmate:fm-task-r" "endpoint_task_id=task-r" \
    "worktree=$wt" "project=$home/projects/repo" "treehouse_root=$root" "kind=scout"
  run_teardown "$home" task-r "$fakebin" "$dir/treehouse.log" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown through the recorded root failed: $(cat "$dir/stderr")"
  grep -Fq "treehouse <return> <--root> <$root> <--force> <$wt>" "$dir/treehouse.log" \
    || fail "teardown did not return the slot through its recorded root: $(cat "$dir/treehouse.log")"
  assert_absent "$home/state/task-r.meta" "teardown left the task record"
  assert_absent "$root/.treehouse/repo-abc123/1/.fm-slot-owner" "teardown left the spent slot claim"
  pass "fm-teardown: a task returns its slot through the Treehouse root its record carries"
}

# --- legacy record ----------------------------------------------------------

# A record written before treehouse_root= existed names a slot in the pool
# Treehouse allocated at the time. It must return through THAT pool's root -
# read from the slot itself - never through the home-scoped root the home would
# use today, and never be moved or reinterpreted.
test_legacy_record_returns_through_its_original_root() {
  local dir=$TMP_ROOT/legacy home=$TMP_ROOT/legacy/home fakebin legacy_root wt home_scoped
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  make_home "$home" task-l
  fm_git_init_commit "$home/projects/repo"
  legacy_root="$TREEHOUSE_ROOT"
  wt=$(make_pool_slot "$home/projects/repo" "$legacy_root" repo-legacy 2)
  home_scoped=$(home_root "$home") || fail "root did not resolve"
  fm_write_meta "$home/state/task-l.meta" \
    "window=firstmate:fm-task-l" "endpoint_task_id=task-l" \
    "worktree=$wt" "project=$home/projects/repo" "kind=scout"
  run_teardown "$home" task-l "$fakebin" "$dir/treehouse.log" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a legacy record failed: $(cat "$dir/stderr")"
  grep -Fq "treehouse <return> <--root> <$legacy_root> <--force> <$wt>" "$dir/treehouse.log" \
    || fail "legacy record did not return through its original pool root: $(cat "$dir/treehouse.log")"
  ! grep -Fq "$home_scoped" "$dir/treehouse.log" \
    || fail "legacy record was returned through the home-scoped root it never used"
  assert_absent "$home/state/task-l.meta" "legacy teardown left the task record"
  pass "fm-teardown: a record without treehouse_root= still returns through the pool root that allocated it"
}

# --- mismatched root refuses ------------------------------------------------

test_mismatched_root_refuses_teardown_without_mutation() {
  local dir=$TMP_ROOT/mismatch home=$TMP_ROOT/mismatch/home fakebin wt other_root rc
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  make_home "$home" task-m
  fm_git_init_commit "$home/projects/repo"
  wt=$(make_pool_slot "$home/projects/repo" "$TREEHOUSE_ROOT" repo-mm 1)
  other_root=$(home_root "$home") || fail "root did not resolve"
  mkdir -p "$other_root"
  : > "$wt/sentinel"
  printf 'task=task-m\nhome=%s\n' "$home" > "$TREEHOUSE_ROOT/.treehouse/repo-mm/1/.fm-slot-owner"
  fm_write_meta "$home/state/task-m.meta" \
    "window=firstmate:fm-task-m" "endpoint_task_id=task-m" \
    "worktree=$wt" "project=$home/projects/repo" "treehouse_root=$other_root" "kind=scout"
  set +e
  run_teardown "$home" task-m "$fakebin" "$dir/treehouse.log" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown with a root that does not contain the slot succeeded"
  assert_contains "$(cat "$dir/stderr")" "REFUSED" "mismatched root did not refuse explicitly: $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "$other_root" "refusal did not name the recorded root"
  assert_present "$home/state/task-m.meta" "mismatched root changed the task record before refusing"
  assert_present "$wt/sentinel" "mismatched root touched the slot before refusing"
  assert_present "$TREEHOUSE_ROOT/.treehouse/repo-mm/1/.fm-slot-owner" "mismatched root removed the slot claim"
  [ ! -s "$dir/treehouse.log" ] || fail "mismatched root still called treehouse: $(cat "$dir/treehouse.log")"
  pass "fm-teardown: a recorded root that does not contain the slot refuses and changes nothing, even with --force"
}

test_spawn_refuses_slot_outside_home_root() {
  local dir=$TMP_ROOT/spawn-foreign-root home=$TMP_ROOT/spawn-foreign-root/home fakebin wt out rc
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  make_home "$home" task-f
  fm_git_init_commit "$home/projects/repo"
  # Treehouse hands back a slot from the shared legacy pool, not this home's root.
  wt=$(make_pool_slot "$home/projects/repo" "$TREEHOUSE_ROOT" repo-shared 1)
  set +e
  out=$(run_spawn "$home" "$home/projects/repo" task-f "$wt" "$fakebin" "$dir/tmux.log")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn accepted a slot outside its home's Treehouse root: $out"
  assert_contains "$out" "outside this home's Treehouse root" "spawn did not name the root mismatch: $out"
  assert_absent "$home/state/task-f.meta" "spawn published a record for a refused slot"
  assert_absent "$TREEHOUSE_ROOT/.treehouse/repo-shared/1/.fm-slot-owner" "spawn claimed a slot it refused"
  pass "fm-spawn: a slot Treehouse enters outside this home's root refuses rather than claiming it"
}

# --- runtime-independent ownership assertion ---------------------------------

# The slot's claim names a task whose record still exists in its home: that task
# is between spawn and teardown, so the slot is still its own whatever
# Treehouse's process lease says. The launch refuses without touching the claim.
test_spawn_refuses_slot_another_live_task_holds() {
  local dir=$TMP_ROOT/live-claim home=$TMP_ROOT/live-claim/home other_home=$TMP_ROOT/live-claim/other-home
  local fakebin root wt out rc
  mkdir -p "$dir" "$other_home/state"
  fakebin=$(make_fakebin "$dir")
  make_home "$home" task-n
  fm_git_init_commit "$home/projects/repo"
  root=$(home_root "$home") || fail "root did not resolve"
  wt=$(make_pool_slot "$home/projects/repo" "$root" repo-live 1)
  printf 'task=holder\nhome=%s\n' "$other_home" > "$root/.treehouse/repo-live/1/.fm-slot-owner"
  fm_write_meta "$other_home/state/holder.meta" "window=firstmate:fm-holder" "worktree=$wt" "kind=ship"
  set +e
  out=$(run_spawn "$home" "$home/projects/repo" task-n "$wt" "$fakebin" "$dir/tmux.log")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn launched into a slot another live task holds: $out"
  assert_contains "$out" "task holder of home $other_home still holds" "spawn did not name the live holder: $out"
  assert_grep "task=holder" "$root/.treehouse/repo-live/1/.fm-slot-owner" "spawn replaced the live holder's claim"
  assert_absent "$home/state/task-n.meta" "spawn published a record for a refused slot"

  # The same claim with the holder's record gone is stale: the launch proceeds
  # and the claim moves to the new task.
  rm -f "$other_home/state/holder.meta"
  out=$(run_spawn "$home" "$home/projects/repo" task-n "$wt" "$fakebin" "$dir/tmux2.log") \
    || fail "spawn refused a slot whose previous holder left no record: $out"
  assert_grep "task=task-n" "$root/.treehouse/repo-live/1/.fm-slot-owner" "spawn did not take over a stale claim"
  pass "fm-spawn: a slot claimed by a task that still has a record refuses on every runtime; a stale claim is replaced"
}

test_real_treehouse_root_round_trip() (
  fm_live_gate default-on FM_LIVE_TREEHOUSE_POOLS treehouse jq
  local dir="$TMP_ROOT/real-treehouse" mode cli_root recorded wt resolved expected
  local treehouse_env_root=
  mkdir -p "$dir/user" "$dir/home"
  fm_git_init_commit "$dir/repo"
  real_treehouse() (
    cd "$dir/repo" || exit 1
    env HOME="$dir/user" TREEHOUSE_ROOT="$treehouse_env_root" TREEHOUSE_NO_UPDATE_CHECK=1 treehouse "$@"
  )
  for mode in explicit symlink legacy-default legacy-config legacy-env; do
    rm -f "$dir/repo/treehouse.toml"
    treehouse_env_root=
    cli_root=
    recorded=
    case "$mode" in
      explicit|symlink)
        cli_root=$(home_root "$dir/home") || fail "real home root did not resolve"
        mkdir -p "$cli_root"
        if [ "$mode" = symlink ]; then
          ln -s "$cli_root" "$dir/root-link"
          cli_root="$dir/root-link"
        fi
        recorded="$cli_root"
        expected="$cli_root"
        wt=$(real_treehouse get --root "$cli_root" --lease --lease-holder "$mode" --no-fetch) \
          || fail "real Treehouse allocation failed for $mode"
        ;;
      *)
        case "$mode" in
          legacy-default) expected="$dir/user" ;;
          legacy-config)
            printf 'root = "configured"\n' > "$dir/repo/treehouse.toml"
            expected="$dir/repo/configured"
            ;;
          legacy-env)
            treehouse_env_root="$dir/env-root"
            expected="$treehouse_env_root"
            ;;
        esac
        wt=$(real_treehouse get --lease --lease-holder "$mode" --no-fetch) \
          || fail "real legacy Treehouse allocation failed for $mode"
        ;;
    esac
    resolved=$(FM_HOME="$dir/home" bash -c '
      . "$1"
      fm_treehouse_task_root "$2" "$3" || exit 1
      printf "%s\n" "$FM_TREEHOUSE_TASK_ROOT"
    ' _ "$WAKE_LIB" "$recorded" "$wt") || fail "real Treehouse slot reconciliation failed for $mode: $wt"
    [ "$resolved" = "$expected" ] || fail "$mode resolved $resolved instead of CLI root $expected"
    real_treehouse status --root "$resolved" --json | \
      jq -e --arg wt "$wt" --arg holder "$mode" 'any(.[]; .path == $wt and .lease_holder == $holder and .status == "leased")' >/dev/null \
      || fail "recovery status missed the real $mode slot"
    real_treehouse return --root "$resolved" --force "$wt" \
      || fail "return through reconciled CLI root failed for $mode"
    real_treehouse status --root "$resolved" --json | \
      jq -e --arg wt "$wt" 'any(.[]; .path == $wt and .lease_holder == "" and .status == "available")' >/dev/null \
      || fail "return did not release the real $mode slot"
  done
  pass "real Treehouse allocation, recovery, and return preserve explicit and legacy roots"
)

test_home_root_is_deterministic_distinct_and_canonical
test_two_homes_with_clones_of_one_repo_allocate_to_different_roots
test_teardown_returns_through_recorded_root
test_legacy_record_returns_through_its_original_root
test_mismatched_root_refuses_teardown_without_mutation
test_spawn_refuses_slot_outside_home_root
test_spawn_refuses_slot_another_live_task_holds
test_real_treehouse_root_round_trip
