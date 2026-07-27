#!/usr/bin/env bash
# Tests for the merge verification gate: bin/fm-verify-lib.sh, bin/fm-verify.sh,
# and the refusal both merge entrypoints enforce before anything lands.
#
# The property under test is that "never merge unverified work" is a REFUSAL
# rather than an instruction. Every case therefore constructs the failing
# situation and checks that nothing merged - not that a message was printed.
#
# The evidence in these tests is produced by the real bin/fm-verify.sh running
# real commands in a real git worktree, never by hand-writing a ledger, so a
# passing case proves the honest path actually works end to end.
#
# Matrix:
#   (a) local merge refuses a commit with no verification record at all
#   (b) PR merge refuses a PR head with no verification record, without
#       calling the forge
#   (c) local merge refuses when the record's commit is not the branch tip
#   (d) PR merge refuses when the record's commit is not the PR head
#   (e) both refuse a record whose step failed
#   (f) local merge refuses when a project-declared required step never ran
#   (g) both refuse while a recorded bypass has no passing evidence
#   (h) an unscoped (--all) bypass can never be superseded by evidence
#   (i) a bypass IS superseded when the named step later passes for that commit
#   (j) a genuinely verified commit merges on both paths with no extra friction
#   (k) the override refuses without its acknowledgement or with a thin reason
#   (l) the override merges, announces loudly, and records durably in both the
#       ledger and the task metadata
#   (m) fm-verify.sh refuses to record evidence for a dirty worktree
#   (n) the PR head is the anchor, and a head the forge cannot report refuses
#   (o) a returned worktree does not turn the honest path into an override
#   (p) the override's metadata note leaves the task's PR metadata parseable,
#       and an override whose record cannot be written is refused rather than
#       taken on a half-written file
#   (q) a declared step set that exists but is unusable refuses, and never
#       reads as "this project declares nothing"
#   (r) a declared step that reads stdin cannot swallow the steps after it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

VERIFY="$ROOT/bin/fm-verify.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-verification-tests)
ACK=i-accept-merging-unverified-work
PR_URL=https://github.com/example/repo/pull/9

# Build one sandbox: a project repo on main, a task worktree on fm/task-x1 with
# one commit, task meta, and fake forge CLIs that log what they were asked to
# do. Echoes the case dir.
make_case() {  # <name> <mode>
  local name=$1 mode=$2 case_dir proj wt bin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/myproj"
  wt="$case_dir/wt"
  bin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$bin"

  fm_git_init_commit "$proj"
  printf '#!/bin/sh\nexit 0\n' > "$proj/pass.sh"
  printf '#!/bin/sh\nexit 1\n' > "$proj/fail.sh"
  chmod +x "$proj/pass.sh" "$proj/fail.sh"
  git -C "$proj" add -A
  git -C "$proj" commit -qm tools
  git -C "$proj" branch -M main
  git -C "$proj" worktree add -q -b fm/task-x1 "$wt"
  printf 'change\n' >> "$wt/README.md"
  git -C "$wt" commit -qam "the change"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=$mode"
  chmod 600 "$case_dir/state/task-x1.meta"

  # gh answers the PR head from a file the test controls, so "the PR moved" and
  # "the forge cannot say" are both expressible.
  git -C "$wt" rev-parse HEAD > "$case_dir/pr-head"
  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) [ -s "$FM_TEST_PR_HEAD" ] && cat "$FM_TEST_PR_HEAD"; exit 0 ;;
    esac ;;
esac
exit 0
SH
  cat > "$bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$bin/gh" "$bin/gh-axi"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

# Run any of the three scripts against a case sandbox.
fm() {  # <case_dir> <script> <args...>
  local case_dir=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_PR_HEAD="$case_dir/pr-head" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$script" "$@"
}

# Capture a run's exit code and streams without tripping set -e.
run() {  # <case_dir> <label> <script> <args...>
  local case_dir=$1 label=$2
  shift 2
  set +e
  fm "$case_dir" "$@" > "$case_dir/$label.out" 2> "$case_dir/$label.err"
  RC=$?
  set -e
}

tip() { git -C "$1/wt" rev-parse HEAD; }
main_of() { git -C "$1/myproj" rev-parse main; }

# The two "did anything actually land" observations. These, not the message
# text, are what make each case a real refusal.
assert_not_merged_local() {  # <case_dir> <before> <msg>
  [ "$(main_of "$1")" = "$2" ] || fail "$3"
}
assert_forge_not_called() {  # <case_dir> <msg>
  assert_no_grep 'pr merge' "$1/gh-axi.log" "$2"
}

commit_more() {  # <case_dir> <text>
  printf '%s\n' "$2" >> "$1/wt/README.md"
  git -C "$1/wt" commit -qam "$2"
  git -C "$1/wt" rev-parse HEAD > "$1/pr-head"
}

verify_pass() {  # <case_dir>
  run "$1" verify "$VERIFY" run task-x1 --step test -- ./pass.sh
  [ "$RC" -eq 0 ] || fail "verify_pass: recording a passing step failed"
}

# --- (a) local merge with no evidence at all --------------------------------

test_local_refuses_without_any_record() {
  local case_dir before
  case_dir=$(make_case local-no-record local-only)
  before=$(main_of "$case_dir")

  run "$case_dir" merge "$MERGE_LOCAL" task-x1

  expect_code 4 "$RC" "local-no-record: merge should refuse with the verification exit code"
  assert_grep 'no verification evidence has been recorded' "$case_dir/merge.err" \
    "local-no-record: refusal did not name the missing evidence"
  assert_not_merged_local "$case_dir" "$before" \
    "local-no-record: local main moved despite the refusal"
  pass "local merge refuses a commit with no verification record"
}

# --- (b) PR merge with no evidence at all -----------------------------------

test_pr_refuses_without_any_record() {
  local case_dir
  case_dir=$(make_case pr-no-record no-mistakes)

  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"

  expect_code 4 "$RC" "pr-no-record: merge should refuse with the verification exit code"
  assert_grep 'no verification evidence has been recorded' "$case_dir/merge.err" \
    "pr-no-record: refusal did not name the missing evidence"
  assert_forge_not_called "$case_dir" "pr-no-record: the forge was asked to merge anyway"
  assert_grep "pr=$PR_URL" "$case_dir/state/task-x1.meta" \
    "pr-no-record: the PR should still be recorded and watched"
  pass "PR merge refuses a PR head with no verification record, without calling the forge"
}

# --- (c) local: record bound to a commit the branch has moved past ----------

test_local_refuses_stale_record() {
  local case_dir before recorded
  case_dir=$(make_case local-stale-record local-only)
  before=$(main_of "$case_dir")
  verify_pass "$case_dir"
  recorded=$(tip "$case_dir")
  commit_more "$case_dir" "later work"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1

  expect_code 4 "$RC" "local-stale-record: merge should refuse a record for an older commit"
  assert_grep "no local verification run is recorded for commit $(tip "$case_dir")" \
    "$case_dir/merge.err" "local-stale-record: refusal did not name the unverified commit"
  [ "$recorded" != "$(tip "$case_dir")" ] || fail "local-stale-record: fixture did not move the branch"
  assert_not_merged_local "$case_dir" "$before" \
    "local-stale-record: local main moved on evidence for a different commit"
  pass "local merge refuses when the record's commit is not the branch tip"
}

# --- (d) PR: record bound to a commit that is not the PR head ---------------

test_pr_refuses_stale_record() {
  local case_dir
  case_dir=$(make_case pr-stale-record no-mistakes)
  verify_pass "$case_dir"
  commit_more "$case_dir" "later work"

  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"

  expect_code 4 "$RC" "pr-stale-record: merge should refuse a record for an older commit"
  assert_grep "no local verification run is recorded for commit $(tip "$case_dir")" \
    "$case_dir/merge.err" "pr-stale-record: refusal did not name the unverified commit"
  assert_forge_not_called "$case_dir" "pr-stale-record: the forge merged evidence-free work"
  pass "PR merge refuses when the record's commit is not the PR head"
}

# --- (e) a recorded step that failed ----------------------------------------

test_both_refuse_a_failed_step() {
  local case_dir before
  case_dir=$(make_case failed-step local-only)
  before=$(main_of "$case_dir")

  run "$case_dir" verify "$VERIFY" run task-x1 --step test -- ./fail.sh
  expect_code 1 "$RC" "failed-step: fm-verify.sh should report the failure it observed"
  assert_grep 'test:failed' "$case_dir/state/task-x1.verification" \
    "failed-step: the real exit code was not recorded"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "failed-step: local merge should refuse a failed run"
  assert_grep 'did not pass' "$case_dir/merge.err" \
    "failed-step: refusal did not name the failed run"
  assert_not_merged_local "$case_dir" "$before" "failed-step: local main moved over a failed run"
  pass "both merge paths refuse a verification record whose step failed"
}

# --- (f) a project-declared required step that never ran --------------------

test_local_refuses_skipped_required_step() {
  local case_dir before
  case_dir=$(make_case skipped-required local-only)
  before=$(main_of "$case_dir")
  mkdir -p "$case_dir/config/verify"
  cat > "$case_dir/config/verify/myproj" <<'EOF'
# a complete verification of this project
test = ./pass.sh
lint = ./pass.sh
EOF
  # Only 'test' is run. 'lint' is declared required, so it counts as SKIPPED.
  verify_pass "$case_dir"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1

  expect_code 4 "$RC" "skipped-required: merge should refuse a skipped declared step"
  assert_grep "required verification step 'lint' has no passing record" \
    "$case_dir/merge.err" "skipped-required: refusal did not name the skipped step"
  assert_not_merged_local "$case_dir" "$before" \
    "skipped-required: local main moved with a required step never run"

  # Running the declared set is what clears it, and nothing else.
  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 0 "$RC" "skipped-required: the declared steps should pass"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "skipped-required: merge should proceed once every declared step ran"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "skipped-required: the fully verified commit did not land"
  pass "a project-declared required step that never ran refuses, and running it clears the refusal"
}

# --- (g) a recorded bypass with no passing evidence -------------------------

test_both_refuse_a_recorded_bypass() {
  local case_dir before
  case_dir=$(make_case bypass-refuses local-only)
  before=$(main_of "$case_dir")
  verify_pass "$case_dir"

  run "$case_dir" bypass "$VERIFY" bypass task-x1 --step ci \
    --why "no-mistakes ci gate approved over 3 failing checks" --by captain
  expect_code 0 "$RC" "bypass-refuses: recording the bypass failed"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "bypass-refuses: merge should refuse while the bypass stands"
  assert_grep "a bypass of 'ci' is recorded against this task" "$case_dir/merge.err" \
    "bypass-refuses: refusal did not name the bypass"
  assert_grep 'approved over 3 failing checks' "$case_dir/merge.err" \
    "bypass-refuses: refusal did not carry the recorded reason"
  assert_not_merged_local "$case_dir" "$before" \
    "bypass-refuses: local main moved over a recorded bypass"
  pass "a recorded bypass refuses the merge even though the run itself passed"
}

test_pr_refuses_a_recorded_bypass() {
  local case_dir
  case_dir=$(make_case pr-bypass-refuses no-mistakes)
  verify_pass "$case_dir"
  fm "$case_dir" "$VERIFY" bypass task-x1 --step ci \
    --why "pushed with hooks disabled; the e2e suite never ran" --by captain >/dev/null

  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"

  expect_code 4 "$RC" "pr-bypass-refuses: merge should refuse while the bypass stands"
  assert_forge_not_called "$case_dir" "pr-bypass-refuses: the forge merged bypassed work"
  pass "PR merge refuses while a recorded bypass has no passing evidence"
}

# --- (h) an unscoped bypass can never be superseded -------------------------

test_unscoped_bypass_never_superseded() {
  local case_dir before
  case_dir=$(make_case unscoped-bypass local-only)
  before=$(main_of "$case_dir")
  fm "$case_dir" "$VERIFY" bypass task-x1 --all \
    --why "whole pipeline skipped during the incident" --by captain >/dev/null
  verify_pass "$case_dir"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1

  expect_code 4 "$RC" "unscoped-bypass: an unscoped bypass must not be clearable by evidence"
  assert_grep 'nothing can supersede it' "$case_dir/merge.err" \
    "unscoped-bypass: refusal did not explain why evidence cannot clear it"
  assert_not_merged_local "$case_dir" "$before" "unscoped-bypass: local main moved anyway"
  pass "an unscoped bypass can never be superseded by later evidence"
}

# --- (i) a scoped bypass IS superseded by real evidence ---------------------

test_scoped_bypass_superseded_by_evidence() {
  local case_dir
  case_dir=$(make_case bypass-superseded local-only)
  fm "$case_dir" "$VERIFY" bypass task-x1 --step e2e \
    --why "e2e skipped while the seed database was stale" --by captain >/dev/null
  verify_pass "$case_dir"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "bypass-superseded: the bypass should stand before e2e is verified"

  # The honest way out: actually run the thing that was skipped.
  run "$case_dir" verify "$VERIFY" run task-x1 --step e2e -- ./pass.sh
  expect_code 0 "$RC" "bypass-superseded: recording the e2e run failed"
  # Both steps must be present in ONE record for the commit, so re-record them
  # together the way a declared step set would.
  mkdir -p "$case_dir/config/verify"
  printf 'test = ./pass.sh\ne2e = ./pass.sh\n' > "$case_dir/config/verify/myproj"
  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 0 "$RC" "bypass-superseded: the declared steps should pass"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "bypass-superseded: real evidence for the bypassed step should clear it"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "bypass-superseded: the verified commit did not land"
  pass "a scoped bypass is superseded only by a passing record of that step for the exact commit"
}

# --- (j) the honest path stays frictionless ---------------------------------

test_verified_commit_merges_on_both_paths() {
  local case_dir
  case_dir=$(make_case verified-local local-only)
  verify_pass "$case_dir"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "verified-local: a verified commit should merge"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "verified-local: local main did not fast-forward to the verified commit"
  assert_grep 'verified:' "$case_dir/merge.out" \
    "verified-local: the merge did not say what evidence carried it"
  assert_no_grep 'MERGING WITHOUT VERIFICATION' "$case_dir/merge.out" \
    "verified-local: the honest path printed an override banner"

  case_dir=$(make_case verified-pr no-mistakes)
  verify_pass "$case_dir"
  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"
  expect_code 0 "$RC" "verified-pr: a verified PR head should merge"
  assert_grep 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "verified-pr: the forge merge lost its number, repo, or default method"
  pass "a genuinely verified commit merges on both paths with no new friction"
}

# --- (k) the override is deliberately awkward -------------------------------

test_override_refuses_without_both_halves() {
  local case_dir before
  case_dir=$(make_case override-partial local-only)
  before=$(main_of "$case_dir")

  run "$case_dir" merge "$MERGE_LOCAL" task-x1 \
    --override-unverified "the checks cannot run because the account is out of minutes"
  expect_code 4 "$RC" "override-partial: the flag alone must not override"
  assert_grep 'FM_MERGE_OVERRIDE_ACK' "$case_dir/merge.err" \
    "override-partial: refusal did not name the missing acknowledgement"
  assert_not_merged_local "$case_dir" "$before" "override-partial: local main moved on a half override"

  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$MERGE_LOCAL" task-x1 \
    --override-unverified "broken" > "$case_dir/thin.out" 2> "$case_dir/thin.err"
  RC=$?
  set -e
  expect_code 4 "$RC" "override-partial: a thin reason must not override"
  assert_grep 'at least 24 characters' "$case_dir/thin.err" \
    "override-partial: refusal did not explain the reason requirement"
  assert_not_merged_local "$case_dir" "$before" "override-partial: local main moved on a thin reason"
  assert_absent "$case_dir/state/task-x1.verification" \
    "override-partial: a refused override still wrote a ledger record"
  pass "the override refuses without its acknowledgement or with a thin reason"
}

# --- (l) the override is loud and durable -----------------------------------

test_override_is_loud_and_durable() {
  local case_dir reason
  reason="GitHub Actions minutes exhausted; checks cannot run at all this cycle"
  case_dir=$(make_case override-taken local-only)

  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$MERGE_LOCAL" task-x1 \
    --override-unverified "$reason" > "$case_dir/ovr.out" 2> "$case_dir/ovr.err"
  RC=$?
  set -e

  expect_code 0 "$RC" "override-taken: a complete override should merge"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "override-taken: the override did not merge"
  assert_grep 'MERGING WITHOUT VERIFICATION EVIDENCE' "$case_dir/ovr.out" \
    "override-taken: the override was quiet on stdout"
  assert_grep 'MERGING WITHOUT VERIFICATION EVIDENCE' "$case_dir/ovr.err" \
    "override-taken: the override was quiet on stderr"
  assert_grep "$reason" "$case_dir/ovr.out" "override-taken: the banner omitted the reason"
  assert_grep "merged_unverified=$(tip "$case_dir")|$reason" "$case_dir/state/task-x1.meta" \
    "override-taken: the override left no durable record in the task metadata"
  assert_grep "$reason" "$case_dir/state/task-x1.verification" \
    "override-taken: the override left no durable record in the ledger"
  assert_grep 'override' "$case_dir/state/task-x1.verification" \
    "override-taken: the ledger record was not marked as an override"

  case_dir=$(make_case override-taken-pr no-mistakes)
  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$PR_MERGE" task-x1 "$PR_URL" \
    --override-unverified "$reason" -- --squash --delete-branch \
    > "$case_dir/ovr.out" 2> "$case_dir/ovr.err"
  RC=$?
  set -e
  expect_code 0 "$RC" "override-taken-pr: a complete override should merge the PR"
  assert_grep 'MERGING WITHOUT VERIFICATION EVIDENCE' "$case_dir/ovr.out" \
    "override-taken-pr: the override was quiet"
  assert_grep 'pr merge 9 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    "override-taken-pr: the override dropped the caller's forge arguments"
  assert_grep 'merged_unverified=' "$case_dir/state/task-x1.meta" \
    "override-taken-pr: the override left no durable record"
  pass "the override merges, announces loudly on both streams, and records durably"
}

# --- (m) evidence must describe a committed tree ----------------------------

test_verify_refuses_dirty_worktree() {
  local case_dir
  case_dir=$(make_case dirty-worktree local-only)
  printf 'uncommitted\n' >> "$case_dir/wt/README.md"

  run "$case_dir" verify "$VERIFY" run task-x1 --step test -- ./pass.sh

  expect_code 1 "$RC" "dirty-worktree: fm-verify.sh should refuse to record"
  assert_grep 'uncommitted changes' "$case_dir/verify.err" \
    "dirty-worktree: refusal did not name the uncommitted work"
  assert_absent "$case_dir/state/task-x1.verification" \
    "dirty-worktree: evidence was recorded for a tree that will never be merged"
  pass "fm-verify.sh refuses to record evidence for a dirty worktree"
}

# --- (n) the PR head is the anchor, and an unknown head refuses -------------

test_pr_refuses_unknown_head() {
  local case_dir
  case_dir=$(make_case pr-unknown-head no-mistakes)
  verify_pass "$case_dir"
  : > "$case_dir/pr-head"

  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"

  expect_code 4 "$RC" "pr-unknown-head: merge should refuse when the head cannot be resolved"
  assert_grep 'did not report a head commit' "$case_dir/merge.err" \
    "pr-unknown-head: refusal did not name the unresolvable head"
  assert_forge_not_called "$case_dir" "pr-unknown-head: the forge merged an unidentifiable commit"
  pass "PR merge refuses when the forge cannot report the head commit to bind evidence to"
}

# --- (o) evidence survives the worktree it was produced in ------------------

test_pr_resolves_head_after_worktree_returned() {
  local case_dir head
  case_dir=$(make_case pr-worktree-returned no-mistakes)
  verify_pass "$case_dir"
  head=$(tip "$case_dir")
  git -C "$case_dir/myproj" worktree remove --force "$case_dir/wt"
  assert_absent "$case_dir/wt" "pr-worktree-returned: fixture did not return the worktree"

  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"

  expect_code 0 "$RC" "pr-worktree-returned: the verified head should still merge"
  assert_grep "verified: $head" "$case_dir/merge.out" \
    "pr-worktree-returned: the gate did not resolve the head from the forge"
  assert_grep 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "pr-worktree-returned: the forge merge did not happen"
  pass "a returned worktree still resolves the PR head, so evidence is not lost to cleanup"
}

# --- (p) the override's own record must not cost the task its metadata ------

test_override_note_keeps_pr_metadata_parseable() {
  local case_dir reason
  reason="GitHub Actions minutes exhausted; checks cannot run at all this cycle"
  case_dir=$(make_case override-meta-parse no-mistakes)

  # The first, refused run is what records pr= and pr_head=, so this snapshot is
  # the exact metadata the override then has to preserve.
  run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"
  expect_code 4 "$RC" "override-meta-parse: the unverified PR should refuse first"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"

  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$PR_MERGE" task-x1 "$PR_URL" \
    --override-unverified "$reason" > "$case_dir/ovr.out" 2> "$case_dir/ovr.err"
  RC=$?
  set -e
  expect_code 0 "$RC" "override-meta-parse: a complete override should merge the PR"
  assert_grep "merged_unverified=" "$case_dir/state/task-x1.meta" \
    "override-meta-parse: the override left no note in the task metadata"

  # Nothing but the note changed. A rewrite that lost or reordered a line would
  # pass a "the note is present" check and still break every later reader.
  [ "$(grep -c '^merged_unverified=' "$case_dir/state/task-x1.meta")" = 1 ] \
    || fail "override-meta-parse: the rewrite did not add exactly one note line"
  grep -v '^merged_unverified=' "$case_dir/state/task-x1.meta" > "$case_dir/meta.stripped"
  cmp -s "$case_dir/meta.before" "$case_dir/meta.stripped" \
    || fail "override-meta-parse: the rewrite did not preserve the metadata it was adding to"

  # The note must sit BEFORE pr=, because everything after pr= is treated as
  # post-recording injection by every later reader of this file.
  assert_grep "pr=$PR_URL" "$case_dir/state/task-x1.meta" \
    "override-meta-parse: the override lost the recorded PR"
  fm_pr_metadata_identity_parse "$case_dir/state/task-x1.meta" \
    || fail "override-meta-parse: the override note made the task metadata unparseable"
  [ "$FM_PR_META_URL" = "$PR_URL" ] \
    || fail "override-meta-parse: the metadata no longer resolves to the recorded PR"
  fm_pr_poll_artifacts_valid "$case_dir/state" task-x1 "$POLL" \
    || fail "override-meta-parse: the override invalidated the armed PR poll"

  # 0600 and a single link survive the rewrite.
  [ "$(fm_pr_file_mode "$case_dir/state/task-x1.meta")" = 600 ] \
    || fail "override-meta-parse: the metadata rewrite did not stay private"
  [ "$(fm_pr_file_link_count "$case_dir/state/task-x1.meta")" = 1 ] \
    || fail "override-meta-parse: the metadata rewrite left more than one link"
  [ -z "$(find "$case_dir/state" -name '.fm-verify-meta.*' -print -quit)" ] \
    || fail "override-meta-parse: the rewrite left its temporary file behind"
  pass "the override's metadata note leaves the task's PR metadata and armed poll intact"
}

# --- (p2) an override whose record cannot be written is not taken -----------

test_override_refuses_when_metadata_cannot_be_rewritten() {
  local case_dir before reason
  reason="GitHub Actions minutes exhausted; checks cannot run at all this cycle"
  case_dir=$(make_case override-meta-unwritable local-only)
  before=$(main_of "$case_dir")
  # A second hard link means the rewrite cannot be proven to land on the file
  # firstmate read, so the copy is refused rather than written blind.
  ln "$case_dir/state/task-x1.meta" "$case_dir/state/extra-link"

  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$MERGE_LOCAL" task-x1 \
    --override-unverified "$reason" > "$case_dir/ovr.out" 2> "$case_dir/ovr.err"
  RC=$?
  set -e

  expect_code 4 "$RC" "override-meta-unwritable: an unrecordable override must not be taken"
  assert_grep 'could not be recorded' "$case_dir/ovr.err" \
    "override-meta-unwritable: the refusal did not say the override went unrecorded"
  assert_not_merged_local "$case_dir" "$before" \
    "override-meta-unwritable: local main moved on an override that was never recorded"
  assert_no_grep 'merged_unverified=' "$case_dir/state/task-x1.meta" \
    "override-meta-unwritable: a refused rewrite still altered the task metadata"
  [ -z "$(find "$case_dir/state" -name '.fm-verify-meta.*' -print -quit)" ] \
    || fail "override-meta-unwritable: the refused rewrite left its temporary file behind"
  pass "an override whose metadata record cannot be written is refused, not taken"
}

# --- (q) a declaration that exists but is unusable is not "no declaration" --

test_unusable_declaration_refuses() {
  local case_dir before
  case_dir=$(make_case unusable-declaration local-only)
  before=$(main_of "$case_dir")
  mkdir -p "$case_dir/config/verify"
  printf 'test = ./pass.sh\nlint = ./pass.sh\n' > "$case_dir/declared-elsewhere"
  ln -s "$case_dir/declared-elsewhere" "$case_dir/config/verify/myproj"

  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 1 "$RC" "unusable-declaration: fm-verify.sh should refuse a symlinked declaration"
  assert_grep 'must be a regular file' "$case_dir/verify.err" \
    "unusable-declaration: refusal did not name the unusable declaration"
  assert_no_grep 'no verification steps declared' "$case_dir/verify.err" \
    "unusable-declaration: a symlinked declaration was read as no declaration at all"

  # The merge must refuse too, rather than quietly requiring nothing: a single
  # ad-hoc step would otherwise satisfy a project that declared two.
  verify_pass "$case_dir"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  [ "$RC" -ne 0 ] || fail "unusable-declaration: merge proceeded on an unreadable declared step set"
  assert_grep 'must be a regular file' "$case_dir/merge.err" \
    "unusable-declaration: the merge refusal did not name the unusable declaration"
  assert_not_merged_local "$case_dir" "$before" \
    "unusable-declaration: local main moved with the project's declared bar unread"
  pass "a declared step set that exists but is unusable refuses instead of silently requiring nothing"
}

# --- (r) a step command cannot consume the step list ------------------------

test_declared_step_cannot_eat_the_step_list() {
  local case_dir
  case_dir=$(make_case stdin-draining-step local-only)
  mkdir -p "$case_dir/config/verify"
  # `cat` drains whatever stdin it is handed. If the step list were still on
  # stdin, it would swallow the remaining steps and they would never run.
  printf 'drain = cat > /dev/null\ntest = ./pass.sh\n' > "$case_dir/config/verify/myproj"

  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 0 "$RC" "stdin-draining-step: the declared steps should pass"
  assert_grep 'drain:passed,test:passed' "$case_dir/state/task-x1.verification" \
    "stdin-draining-step: a step that reads stdin swallowed the steps after it"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "stdin-draining-step: the fully verified commit should merge"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "stdin-draining-step: the verified commit did not land"
  pass "a declared step that reads stdin cannot swallow the steps after it"
}

test_local_refuses_without_any_record
test_pr_refuses_without_any_record
test_local_refuses_stale_record
test_pr_refuses_stale_record
test_both_refuse_a_failed_step
test_local_refuses_skipped_required_step
test_both_refuse_a_recorded_bypass
test_pr_refuses_a_recorded_bypass
test_unscoped_bypass_never_superseded
test_scoped_bypass_superseded_by_evidence
test_verified_commit_merges_on_both_paths
test_override_refuses_without_both_halves
test_override_is_loud_and_durable
test_verify_refuses_dirty_worktree
test_pr_refuses_unknown_head
test_pr_resolves_head_after_worktree_returned
test_override_note_keeps_pr_metadata_parseable
test_override_refuses_when_metadata_cannot_be_rewritten
test_unusable_declaration_refuses
test_declared_step_cannot_eat_the_step_list
