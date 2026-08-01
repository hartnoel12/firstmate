#!/usr/bin/env bash
# Regression test for stale turn-end hooks in a reused worktree slot
# (bin/fm-spawn.sh's scrub_stale_turnend_hooks).
#
# Task worktrees come from a pool, so a slot outlives the task that occupied it.
# Each occupant leaves a turn-end hook in the worktree naming its own
# state/<id>.turn-ended. Teardown removes those, but teardown is not the only way
# a slot comes back - a forced reclaim or an abandoned task returns one with the
# hook still on it - and the harnesses do not each read only their own hook file:
# grok loads <worktree>/.claude/settings.local.json as a project hook, so a
# claude crew's leftovers fire under a grok crew, waking firstmate for a task
# that no longer exists.
#
# Each case here plants a previous occupant's hook, proves by RUNNING it that it
# really does signal the dead task, then spawns the next task into the same slot
# and asserts nothing in the worktree still names that task.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-turnend-hook)
DEAD_ID=dead-task-z1

# A fake tmux/treehouse pair good enough to carry fm-spawn to the hook-install
# step: the pane reports the worktree as its cwd, and every other subcommand is
# a silent success.
make_fakebin() {  # <dir> <worktree>
  local dir=$1 wt=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' '$wt'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# One home, one project, one pool worktree, and a brief for <id>.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Plant the previous occupant's hook file, byte-for-byte the shape fm-spawn
# writes for a claude crew, naming DEAD_ID's turn-end signal.
plant_dead_claude_hook() {  # <case_dir>
  local case_dir=$1 signal
  signal="$case_dir/home/state/$DEAD_ID.turn-ended"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' \
    "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$signal'\"}]}]}}" \
    > "$case_dir/wt/.claude/settings.local.json"
  printf '%s\n' "$signal"
}

# Run the hook file's command exactly as a harness would, and answer whether it
# signalled the dead task. This is what makes the planted file a firing hook
# rather than a decorative one.
hook_fires_for_dead_task() {  # <case_dir> <hook-file>
  local case_dir=$1 hook=$2 signal command
  signal="$case_dir/home/state/$DEAD_ID.turn-ended"
  rm -f "$signal"
  [ -f "$hook" ] || return 1
  command=$(sed -n 's/.*"command":"\([^"]*\)".*/\1/p' "$hook")
  [ -n "$command" ] || return 1
  ( eval "$command" ) >/dev/null 2>&1 || true
  [ -f "$signal" ]
}

run_spawn() {  # <case_dir> <id> <harness>
  local case_dir=$1 id=$2 harness=$3
  FM_ROOT_OVERRIDE="$case_dir/home" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_BACKEND=tmux \
  FM_SPAWN_NO_GUARD=1 \
  PATH="$case_dir/fake/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --harness "$harness" \
    > "$case_dir/spawn.out" 2> "$case_dir/spawn.err"
}

# --- (a) a foreign harness's leftover hook ----------------------------------
#
# The dead task ran claude; the next occupant runs codex, which installs no
# worktree hook of its own. Nothing would overwrite the leftover file, and grok
# and claude both read it, so it survives to signal a task that is gone.
test_leftover_hook_is_scrubbed_on_slot_reuse() {
  local case_dir hook signal rc
  case_dir=$(make_case foreign-harness fresh-x1)
  make_fakebin "$case_dir/fake" "$case_dir/wt" >/dev/null
  hook="$case_dir/wt/.claude/settings.local.json"
  signal=$(plant_dead_claude_hook "$case_dir")

  hook_fires_for_dead_task "$case_dir" "$hook" \
    || fail "foreign-harness: the planted hook does not signal the dead task, so the case proves nothing"

  set +e
  run_spawn "$case_dir" fresh-x1 codex
  rc=$?
  set -e
  expect_code 0 "$rc" "foreign-harness: spawn failed: $(cat "$case_dir/spawn.err")"

  [ ! -f "$hook" ] \
    || fail "foreign-harness: the dead task's hook is still in the reused worktree slot"
  rm -f "$signal"
  ! hook_fires_for_dead_task "$case_dir" "$hook" \
    || fail "foreign-harness: the reused slot still signals $DEAD_ID"
  pass "a previous occupant's turn-end hook is scrubbed when the slot is reused"
}

# --- (b) every worktree-resident artifact, not just the claude one ----------

test_every_worktree_hook_artifact_is_scrubbed() {
  local case_dir rel rc
  case_dir=$(make_case all-artifacts fresh-x2)
  make_fakebin "$case_dir/fake" "$case_dir/wt" >/dev/null
  plant_dead_claude_hook "$case_dir" >/dev/null
  mkdir -p "$case_dir/wt/.opencode/plugins"
  # shellcheck disable=SC2016  # the opencode plugin's own $`...` template literal, written verbatim
  printf 'await $`touch %s`\n' "$case_dir/home/state/$DEAD_ID.turn-ended" \
    > "$case_dir/wt/.opencode/plugins/fm-turn-end.js"
  printf 'token=fm.aaaaaaaaaaaa\n' > "$case_dir/wt/.fm-grok-turnend"
  printf 'token=fm.bbbbbbbbbbbb\n' > "$case_dir/wt/.fm-kimi-turnend"

  set +e
  run_spawn "$case_dir" fresh-x2 codex
  rc=$?
  set -e
  expect_code 0 "$rc" "all-artifacts: spawn failed: $(cat "$case_dir/spawn.err")"

  for rel in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
             .fm-grok-turnend .fm-kimi-turnend; do
    [ ! -f "$case_dir/wt/$rel" ] || fail "all-artifacts: $rel survived the slot reuse"
  done
  pass "every worktree-resident turn-end artifact is scrubbed, not just the claude one"
}

# --- (c) the new occupant's own hook is installed, not scrubbed -------------
#
# The control: scrubbing runs before installation, so a claude crew still ends up
# with a working hook - naming ITS task, not the dead one.
test_new_hook_is_installed_and_names_the_new_task() {
  local case_dir hook rc
  case_dir=$(make_case reinstall fresh-x3)
  make_fakebin "$case_dir/fake" "$case_dir/wt" >/dev/null
  hook="$case_dir/wt/.claude/settings.local.json"
  plant_dead_claude_hook "$case_dir" >/dev/null

  set +e
  run_spawn "$case_dir" fresh-x3 claude
  rc=$?
  set -e
  expect_code 0 "$rc" "reinstall: spawn failed: $(cat "$case_dir/spawn.err")"

  assert_grep 'fresh-x3.turn-ended' "$hook" \
    "reinstall: the new task has no turn-end hook of its own"
  assert_no_grep "$DEAD_ID" "$hook" \
    "reinstall: the new task's hook still names the dead task"
  pass "the new occupant's own turn-end hook is installed and names its own task"
}

# --- (d) a project's own settings file is never deleted ---------------------
#
# .claude/settings.local.json is the one name here a project may legitimately
# own. A file that names no turn-end signal is not firstmate's to remove.
test_project_owned_settings_file_is_left_alone() {
  local case_dir hook rc
  case_dir=$(make_case project-owned fresh-x4)
  make_fakebin "$case_dir/fake" "$case_dir/wt" >/dev/null
  hook="$case_dir/wt/.claude/settings.local.json"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$hook"

  set +e
  run_spawn "$case_dir" fresh-x4 codex
  rc=$?
  set -e
  expect_code 0 "$rc" "project-owned: spawn failed: $(cat "$case_dir/spawn.err")"

  assert_grep 'Bash(ls:*)' "$hook" \
    "project-owned: a settings file that is not a firstmate hook was deleted"
  pass "a project's own .claude/settings.local.json is left alone"
}

# --- (e) a committed hook is reported rather than deleted -------------------
#
# Deleting a tracked file would leave the worktree dirty and block its own
# teardown, so the stale hook is named on stderr instead of removed.
test_committed_hook_is_reported_not_deleted() {
  local case_dir hook rc
  case_dir=$(make_case committed-hook fresh-x5)
  make_fakebin "$case_dir/fake" "$case_dir/wt" >/dev/null
  hook="$case_dir/wt/.claude/settings.local.json"
  plant_dead_claude_hook "$case_dir" >/dev/null
  git -C "$case_dir/wt" add -f .claude/settings.local.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "committed hook"

  set +e
  run_spawn "$case_dir" fresh-x5 codex
  rc=$?
  set -e
  expect_code 0 "$rc" "committed-hook: spawn failed: $(cat "$case_dir/spawn.err")"

  [ -f "$hook" ] || fail "committed-hook: a file the project committed was deleted"
  assert_grep 'committed to the project' "$case_dir/spawn.err" \
    "committed-hook: the stale committed hook was neither removed nor reported"
  [ -z "$(git -C "$case_dir/wt" status --porcelain -- .claude 2>/dev/null)" ] \
    || fail "committed-hook: the worktree was left dirty, which would block its own teardown"
  pass "a committed turn-end hook is reported rather than deleted"
}

test_leftover_hook_is_scrubbed_on_slot_reuse
test_every_worktree_hook_artifact_is_scrubbed
test_new_hook_is_installed_and_names_the_new_task
test_project_owned_settings_file_is_left_alone
test_committed_hook_is_reported_not_deleted
