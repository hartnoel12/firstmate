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
#   (m) fm-verify.sh refuses to record evidence for a dirty worktree, and
#       separately records (rather than refuses) a worktree carrying
#       gitignored untracked content, with a digest of that content alongside
#       the result
#   (n) the PR head is the anchor, and a head the forge cannot report refuses
#   (o) a returned worktree does not turn the honest path into an override
#   (p) the override's metadata note leaves the task's PR metadata parseable;
#       an override whose record cannot be written is refused rather than taken
#       on a half-written file; and a repeat override or a backslash in the
#       reason is recorded rather than spuriously refused
#   (q) a declared step set that exists but is unusable refuses, and never
#       reads as "this project declares nothing"
#   (r) a declared step that reads stdin cannot swallow the steps after it
#   (s) one commit carrying both a failed and a passing run of the same step
#       refuses in either order, while repeated passing runs still merge
#   (t) a bypass stays visible to the gate when the ledger loses it, loses its
#       trailing newline, or has one byte of its record damaged
#   (u) after a rebase, a head whose own change is unchanged verifies with the
#       declared post-rebase tier - the always steps plus the steps its diff
#       selects - is recorded as a post-rebase run naming its prior, and merges
#       on both paths
#   (v) a head that is not merely a rebase is refused, naming the files whose
#       change differs, and the merge gate re-proves that for itself rather
#       than trusting the prior a record names
#   (w) a prior with no full passing record - never verified, partly verified,
#       carrying a failure, or itself only post-rebase verified - is refused
#   (x) the merge gate holds a post-rebase record to its prior and its tier:
#       a prior later recorded failed, a record missing an always step or a
#       diff-selected step, or a bypass that only a carried step would cover,
#       refuses
#   (y) the post-rebase run keeps the full run's guards: dirty worktree, HEAD
#       moving mid-run, no declared tier, a prior that is the head, and an
#       ad-hoc command are all refused, and a malformed tier refuses loudly
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
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

# A gitignored leftover (a build cache a prior occupant of a reused pooled
# worktree could have left behind) is invisible to plain `git status`, so it
# is not "dirty" - but it is also indistinguishable from this task's own
# legitimate build output (installed dependencies, a local .env), so it must
# not refuse the run the way (m)'s dirty-worktree check does. It records a
# digest of the ignored-path state alongside the result instead.
test_verify_records_gitignored_cache() {
  local case_dir sha
  case_dir=$(make_case ignored-cache local-only)
  printf 'cache/\n' > "$case_dir/wt/.gitignore"
  git -C "$case_dir/wt" add .gitignore
  git -C "$case_dir/wt" commit -qm "ignore cache dir"
  mkdir -p "$case_dir/wt/cache"
  printf 'stale build output from a different commit\n' > "$case_dir/wt/cache/artifact"
  sha=$(tip "$case_dir")

  run "$case_dir" verify "$VERIFY" run task-x1 --step test -- ./pass.sh

  expect_code 0 "$RC" "ignored-cache: fm-verify.sh should record evidence, not refuse"
  assert_grep 'ignored=1:' "$case_dir/state/task-x1.verification" \
    "ignored-cache: ledger did not record the ignored-path count and digest"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "ignored-cache: merge should succeed on the recorded evidence"
  [ "$(main_of "$case_dir")" = "$sha" ] \
    || fail "ignored-cache: local main did not move to the verified commit"
  pass "fm-verify.sh records evidence (with an ignored-path digest) for a worktree carrying gitignored cache, rather than refusing"
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

# --- (p3) the override stays usable on a task that already took one ---------

test_repeated_identical_override_still_records() {
  local case_dir reason attempt
  reason="GitHub Actions minutes exhausted; checks cannot run at all this cycle"
  case_dir=$(make_case override-repeated no-mistakes)

  # The same commit and the same reason produce a byte-identical note line, so
  # the second override is the case where "exactly one note" and "one MORE note
  # than before" diverge. A merge that fails after the note is recorded and is
  # then retried lands here, and the escape hatch has to keep working.
  for attempt in first second; do
    set +e
    FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$PR_MERGE" task-x1 "$PR_URL" \
      --override-unverified "$reason" > "$case_dir/ovr-$attempt.out" 2> "$case_dir/ovr-$attempt.err"
    RC=$?
    set -e
    expect_code 0 "$RC" "override-repeated: the $attempt override should merge, not refuse as unrecordable"
  done

  [ "$(grep -c 'pr merge 9 --repo example/repo' "$case_dir/gh-axi.log")" = 2 ] \
    || fail "override-repeated: the forge did not merge on both overrides"
  [ "$(grep -c '^merged_unverified=' "$case_dir/state/task-x1.meta")" = 2 ] \
    || fail "override-repeated: the second identical override was not recorded in the metadata"
  [ "$(grep -c '^override' "$case_dir/state/task-x1.verification")" = 2 ] \
    || fail "override-repeated: the second identical override was not recorded in the ledger"
  fm_pr_metadata_identity_parse "$case_dir/state/task-x1.meta" \
    || fail "override-repeated: two override notes made the task metadata unparseable"
  pass "a second override with an identical commit and reason is still recorded and still merges"
}

# --- (p4) an override reason is free text, including backslashes ------------

test_override_reason_with_backslash_records() {
  local case_dir reason
  reason='the build agent is wedged on C:\builds\fm and cannot be restarted'
  case_dir=$(make_case override-backslash local-only)

  set +e
  FM_MERGE_OVERRIDE_ACK=$ACK fm "$case_dir" "$MERGE_LOCAL" task-x1 \
    --override-unverified "$reason" > "$case_dir/ovr.out" 2> "$case_dir/ovr.err"
  RC=$?
  set -e

  expect_code 0 "$RC" "override-backslash: a reason with a backslash should merge, not refuse"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "override-backslash: the override did not merge"
  assert_grep "$reason" "$case_dir/state/task-x1.meta" \
    "override-backslash: the reason was lost or mangled in the task metadata"
  assert_grep "$reason" "$case_dir/state/task-x1.verification" \
    "override-backslash: the reason was lost or mangled in the ledger"
  pass "an override reason containing a backslash is recorded verbatim and still merges"
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

# --- (s) one commit, two runs of the same step, disagreeing ------------------
#
# The ambiguous case, tested in both orders and against its own control. Same
# commit means same tree, so a step that fails once and passes once has not
# verified anything; resolving that in favour of the pass is exactly how a red
# change lands looking green. bin/fm-verify-lib.sh's PRECEDENCE note owns the
# rule. Both runs here are real: fm-verify.sh executes ./fail.sh and ./pass.sh
# and records the exit codes it observed.

test_duplicate_runs_refuse_in_either_order() {
  local case_dir before order
  for order in fail-then-pass pass-then-fail; do
    case_dir=$(make_case "dup-$order" local-only)
    before=$(main_of "$case_dir")

    if [ "$order" = fail-then-pass ]; then
      run "$case_dir" v1 "$VERIFY" run task-x1 --step flaky -- ./fail.sh
      expect_code 1 "$RC" "dup-$order: the failing run should report its failure"
      run "$case_dir" v2 "$VERIFY" run task-x1 --step flaky -- ./pass.sh
      expect_code 0 "$RC" "dup-$order: the passing re-run should record"
    else
      run "$case_dir" v1 "$VERIFY" run task-x1 --step flaky -- ./pass.sh
      expect_code 0 "$RC" "dup-$order: the passing run should record"
      run "$case_dir" v2 "$VERIFY" run task-x1 --step flaky -- ./fail.sh
      expect_code 1 "$RC" "dup-$order: the failing re-run should report its failure"
    fi

    # Both runs are genuinely bound to the same commit; without that the case
    # would prove nothing about precedence.
    [ "$(grep -c "	$(tip "$case_dir")	" "$case_dir/state/task-x1.verification")" -eq 2 ] \
      || fail "dup-$order: fixture did not record two runs for one commit"

    run "$case_dir" merge "$MERGE_LOCAL" task-x1
    expect_code 4 "$RC" "dup-$order: a commit carrying a failed run must not merge"
    assert_not_merged_local "$case_dir" "$before" \
      "dup-$order: local main moved on a commit whose step is recorded failed"
  done
  pass "a commit carrying both a failed and a passing run of one step refuses in either order"
}

# The control the rule must not break: re-running a step that passes both times
# is ordinary, and must still merge.
test_repeated_passing_runs_still_merge() {
  local case_dir
  case_dir=$(make_case dup-pass-twice local-only)

  run "$case_dir" v1 "$VERIFY" run task-x1 --step test -- ./pass.sh
  expect_code 0 "$RC" "dup-pass-twice: the first passing run should record"
  run "$case_dir" v2 "$VERIFY" run task-x1 --step test -- ./pass.sh
  expect_code 0 "$RC" "dup-pass-twice: the second passing run should record"

  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "dup-pass-twice: two passing runs of one commit should merge"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "dup-pass-twice: the verified commit did not land"
  pass "two passing runs of the same commit still merge"
}

# Steps from separate runs of one commit combine, so splitting a verification
# across two invocations satisfies a declared step set.
test_steps_from_separate_runs_combine() {
  local case_dir
  case_dir=$(make_case dup-union local-only)
  mkdir -p "$case_dir/config/verify"
  printf 'lint = ./pass.sh\ntest = ./pass.sh\n' > "$case_dir/config/verify/myproj"

  run "$case_dir" v1 "$VERIFY" run task-x1 --step lint -- ./pass.sh
  expect_code 0 "$RC" "dup-union: the lint run should record"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "dup-union: one of two declared steps is not a complete verification"

  run "$case_dir" v2 "$VERIFY" run task-x1 --step test -- ./pass.sh
  expect_code 0 "$RC" "dup-union: the test run should record"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "dup-union: both declared steps passed for this commit"
  [ "$(main_of "$case_dir")" = "$(tip "$case_dir")" ] \
    || fail "dup-union: the fully verified commit did not land"
  pass "steps passing across separate runs of one commit combine into one verification"
}

# --- (t) a bypass the ledger no longer carries ------------------------------
#
# Rule 4 is the one rule the gate cannot check against evidence of its own: it
# depends on a record something else had to write. Each case here damages that
# record in a way that used to make the bypass invisible, and asserts the merge
# still refuses and local main still did not move.

bypass_case() {  # <name> -> case dir with a passing run and a bypass of 'ci'
  local case_dir=$1
  case_dir=$(make_case "$case_dir" local-only)
  verify_pass "$case_dir"
  run "$case_dir" bypass "$VERIFY" bypass task-x1 --step ci --why 'ci board dark on budget' --by firstmate
  expect_code 0 "$RC" "$1: recording the bypass failed"
  printf '%s\n' "$case_dir"
}

test_bypass_is_recorded_in_both_homes() {
  local case_dir
  case_dir=$(bypass_case bypass-two-homes)
  assert_grep 'bypass' "$case_dir/state/task-x1.verification" \
    "bypass-two-homes: the ledger has no bypass record"
  assert_grep 'bypassed=ci|ci board dark on budget' "$case_dir/state/task-x1.meta" \
    "bypass-two-homes: the task metadata has no bypass record"
  pass "a bypass is recorded in both durable homes, not just the ledger"
}

test_bypass_survives_a_damaged_ledger() {
  local case_dir before label
  for label in ledger-lost no-trailing-newline corrupted-kind; do
    case_dir=$(bypass_case "bypass-$label")
    before=$(main_of "$case_dir")
    local ledger="$case_dir/state/task-x1.verification"

    case "$label" in
      # The bypass line is gone entirely; the passing run is left intact, so the
      # gate has every reason to think this commit is cleanly verified.
      ledger-lost) grep -v '^bypass	' "$ledger" > "$ledger.new" && mv "$ledger.new" "$ledger" ;;
      # The file's last byte is lost, which is where a just-written bypass is.
      no-trailing-newline) printf '%s' "$(cat "$ledger")" > "$ledger.new" && mv "$ledger.new" "$ledger" ;;
      # One byte of the record's kind is damaged, so it is no longer 'bypass'.
      corrupted-kind) sed 's/^bypass	/bypasx	/' "$ledger" > "$ledger.new" && mv "$ledger.new" "$ledger" ;;
    esac

    run "$case_dir" merge "$MERGE_LOCAL" task-x1
    expect_code 4 "$RC" "bypass-$label: a bypassed gate must not merge"
    assert_not_merged_local "$case_dir" "$before" \
      "bypass-$label: local main moved over a bypass the ledger no longer shows"
  done
  pass "a recorded bypass still refuses when the ledger loses, truncates, or corrupts it"
}

# --- (u)-(y) the post-rebase tier -------------------------------------------
#
# bin/fm-verify-lib.sh's POST-REBASE note owns the contract. Every declared step
# here logs its own name when it runs, so a case can see exactly which steps the
# tier ran and which it carried from the prior. The honest-path evidence is
# real; the refusal cases that need a record fm-verify.sh would never write (a
# forged prior, a tier step missing) derive it from a genuine one, the way (t)
# damages a genuine bypass.

declare_tier() {  # <case_dir>: five declared steps and a post-rebase tier over them
  local ran="$1/ran.log"
  mkdir -p "$1/config/verify"
  cat > "$1/config/verify/myproj" <<EOF
types = echo types >> '$ran'
unit = echo unit >> '$ran'
mobile = echo mobile >> '$ran'
lint = echo lint >> '$ran'
secrets = echo secrets >> '$ran'
@post-rebase types always
@post-rebase unit always
@post-rebase mobile if-changed apps/mobile/*
@post-rebase lint if-changed *.ts
@post-rebase secrets if-own-changed *
EOF
  : > "$ran"
}

ran_steps() {  # <case_dir>: the steps that ran since the log was last cleared
  tr '\n' ' ' < "$1/ran.log" | sed 's/ $//'
}

full_verify() {  # <case_dir>: a full declared run at the task's current tip
  run "$1" full "$VERIFY" run task-x1
  [ "$RC" -eq 0 ] || fail "full_verify: the full declared run did not pass"
  : > "$1/ran.log"
}

upstream_commit() {  # <case_dir> <path> <line>: move main forward
  mkdir -p "$(dirname "$1/myproj/$2")"
  printf '%s\n' "$3" >> "$1/myproj/$2"
  git -C "$1/myproj" add -- "$2"
  git -C "$1/myproj" commit -qm "upstream $2"
}

branch_commit() {  # <case_dir> <path> <line>: more work on the task branch
  mkdir -p "$(dirname "$1/wt/$2")"
  printf '%s\n' "$3" >> "$1/wt/$2"
  git -C "$1/wt" add -- "$2"
  git -C "$1/wt" commit -qm "branch $2"
  git -C "$1/wt" rev-parse HEAD > "$1/pr-head"
}

rebase_task() {  # <case_dir>: rebase the task branch onto main
  git -C "$1/wt" rebase -q main
  git -C "$1/wt" rev-parse HEAD > "$1/pr-head"
}

post_rebase_records() {  # <case_dir>: how many post-rebase records the ledger holds
  local n
  n=$(grep -c '^post-rebase	' "$1/state/task-x1.verification" 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

# A genuine post-rebase record, rewritten by sed, for the refusal cases.
rewrite_ledger() {  # <case_dir> <sed-expression>
  local ledger="$1/state/task-x1.verification"
  sed "$2" "$ledger" > "$ledger.new" && mv "$ledger.new" "$ledger"
}

# Record a run at an older commit of the task, the way firstmate would: check
# it out in the task worktree, run, and return to the branch.
at_commit() {  # <case_dir> <commit> <label> <fm-verify args...>
  local case_dir=$1 commit=$2 label=$3
  shift 3
  git -C "$case_dir/wt" checkout -q --detach "$commit"
  run "$case_dir" "$label" "$VERIFY" "$@"
  git -C "$case_dir/wt" checkout -q fm/task-x1
}

# --- (u) a rebase-only head verifies with the tier and merges ---------------

test_post_rebase_tier_verifies_and_merges() {
  local case_dir mode prior head
  for mode in local-only no-mistakes; do
    case_dir=$(make_case "rebase-merges-$mode" "$mode")
    declare_tier "$case_dir"
    full_verify "$case_dir"
    prior=$(tip "$case_dir")
    upstream_commit "$case_dir" apps/mobile/app.ts 'export const x = 1;'
    rebase_task "$case_dir"
    head=$(tip "$case_dir")
    [ "$head" != "$prior" ] || fail "rebase-merges-$mode: fixture did not rewrite the branch"

    run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
    expect_code 0 "$RC" "rebase-merges-$mode: a rebase-only head should verify with the tier"
    [ "$(ran_steps "$case_dir")" = 'types unit mobile lint' ] \
      || fail "rebase-merges-$mode: the tier ran '$(ran_steps "$case_dir")', expected the always steps plus the two the diff selects"

    # The ledger says what happened: a post-rebase run of this head, naming its
    # prior and what it carried from it - never a plain pass.
    tail -1 "$case_dir/state/task-x1.verification" > "$case_dir/last-record"
    grep -q "^post-rebase	[0-9]*	$head	passed	types:passed,unit:passed,mobile:passed,lint:passed	prior=$prior carried=secrets " \
      "$case_dir/last-record" \
      || fail "rebase-merges-$mode: the ledger did not record a post-rebase run naming its prior: $(cat "$case_dir/last-record")"

    if [ "$mode" = local-only ]; then
      run "$case_dir" merge "$MERGE_LOCAL" task-x1
      expect_code 0 "$RC" "rebase-merges-$mode: the post-rebase-verified head should merge"
      [ "$(main_of "$case_dir")" = "$head" ] \
        || fail "rebase-merges-$mode: local main did not fast-forward to the rebased head"
    else
      run "$case_dir" merge "$PR_MERGE" task-x1 "$PR_URL"
      expect_code 0 "$RC" "rebase-merges-$mode: the post-rebase-verified PR head should merge"
      assert_grep 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
        "rebase-merges-$mode: the forge was not asked to merge"
    fi
    assert_grep "post-rebase of $prior" "$case_dir/merge.out" \
      "rebase-merges-$mode: the merge did not say the head rode on a post-rebase run"
    assert_grep 'carried: secrets' "$case_dir/merge.out" \
      "rebase-merges-$mode: the merge did not say which steps were carried from the prior"
  done
  pass "a rebase-only head verifies with the declared tier, is recorded as post-rebase, and merges on both paths"
}

test_post_rebase_selects_own_files_the_rebase_changed() {
  local case_dir prior
  case_dir=$(make_case rebase-own-file local-only)
  declare_tier "$case_dir"
  # A file both sides edit. The upstream inserts a line between the branch's
  # two edits: the rebase is clean, yet it shifts the branch's hunk offsets,
  # changes both blob ids, and puts the upstream's line inside the branch hunks'
  # context - all of which a rebase alone produces, and none of which is the
  # branch's change. diff.interHunkContext, an ordinary user setting, would pull
  # that line back into even a zero-context diff.
  git -C "$case_dir/myproj" config diff.interHunkContext 10
  printf 'l%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 > "$case_dir/myproj/shared.txt"
  git -C "$case_dir/myproj" add shared.txt
  git -C "$case_dir/myproj" commit -qm "shared file"
  rebase_task "$case_dir"
  printf 'l%s\n' 1 A 3 4 5 6 7 B 9 10 11 12 > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" commit -qam "branch edits shared"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  printf 'l%s\n' 1 2 3 4 5 U 6 7 8 9 10 11 12 > "$case_dir/myproj/shared.txt"
  git -C "$case_dir/myproj" commit -qam "upstream edits shared"
  rebase_task "$case_dir"

  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 0 "$RC" "rebase-own-file: a clean rebase over a shared file is still a rebase"
  [ "$(ran_steps "$case_dir")" = 'types unit secrets' ] \
    || fail "rebase-own-file: the tier ran '$(ran_steps "$case_dir")', expected the always steps plus the own-file step"
  pass "a step scoped to the branch's own files re-runs when the rebase changed one of them"
}

# --- (v) a head that is not merely a rebase is refused ----------------------

test_post_rebase_refuses_a_head_that_is_not_a_rebase() {
  local case_dir prior
  # New work riding along with the rebase.
  case_dir=$(make_case rebase-new-work local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  branch_commit "$case_dir" src/extra.ts 'export const extra = 1;'

  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-new-work: a head carrying new work must not verify as a rebase"
  assert_grep "is not a rebase of $prior" "$case_dir/verify.err" \
    "rebase-new-work: the refusal did not say the head is not a rebase"
  assert_grep 'src/extra.ts' "$case_dir/verify.err" \
    "rebase-new-work: the refusal did not name the file beyond the rebase signature"
  assert_no_grep 'docs/notes.md' "$case_dir/verify.err" \
    "rebase-new-work: the upstream's own change was named as a difference"
  [ -z "$(ran_steps "$case_dir")" ] || fail "rebase-new-work: steps ran on a refused run"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-new-work: a refused run still recorded a post-rebase record"

  # Different added lines in a file the branch already changed.
  case_dir=$(make_case rebase-rewritten local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  printf 'a different change\n' >> "$case_dir/wt/README.md"
  git -C "$case_dir/wt" commit -q --amend -a --no-edit

  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-rewritten: a head whose added lines changed must not verify as a rebase"
  assert_grep 'README.md' "$case_dir/verify.err" \
    "rebase-rewritten: the refusal did not name the file whose change differs"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-rewritten: a refused run still recorded a post-rebase record"

  # The full path is unchanged, and remains the way forward.
  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 0 "$RC" "rebase-rewritten: the full run should still verify the rewritten head"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 0 "$RC" "rebase-rewritten: the fully verified head should merge"

  # A binary file the branch adds, with different bytes after the rebase. A
  # plain diff renders both as one identical "Binary files differ" line.
  case_dir=$(make_case rebase-binary local-only)
  declare_tier "$case_dir"
  printf 'one\000\001\002' > "$case_dir/wt/asset.bin"
  git -C "$case_dir/wt" add asset.bin
  git -C "$case_dir/wt" commit -qm "branch asset"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  printf 'two\000\001\002' > "$case_dir/wt/asset.bin"
  git -C "$case_dir/wt" commit -q --amend -a --no-edit
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-binary: different binary content must not verify as a rebase"
  assert_grep 'asset.bin' "$case_dir/verify.err" \
    "rebase-binary: the refusal did not name the binary file whose content differs"
  pass "a head that is not merely a rebase is refused, naming the files that differ"
}

test_gate_reproves_the_rebase_itself() {
  local case_dir first second before
  case_dir=$(make_case rebase-forged-prior local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  first=$(tip "$case_dir")
  branch_commit "$case_dir" src/extra.ts 'export const extra = 1;'
  full_verify "$case_dir"
  second=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  before=$(main_of "$case_dir")
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$second"
  expect_code 0 "$RC" "rebase-forged-prior: the honest post-rebase run should record"

  # Both priors are fully verified, but only the second is this head's change.
  rewrite_ledger "$case_dir" "s/prior=$second/prior=$first/"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "rebase-forged-prior: a record naming a prior the head is not a rebase of must not merge"
  assert_grep "is not a rebase of $first" "$case_dir/merge.err" \
    "rebase-forged-prior: the gate did not re-prove the rebase"
  assert_grep 'src/extra.ts' "$case_dir/merge.err" \
    "rebase-forged-prior: the gate did not name the file beyond the rebase signature"
  assert_not_merged_local "$case_dir" "$before" \
    "rebase-forged-prior: local main moved on a record whose prior is not the head's change"
  pass "the merge gate re-proves the rebase for itself rather than trusting the prior a record names"
}

# --- (w) no full prior record, no narrowed run ------------------------------

test_post_rebase_refuses_without_a_full_prior_record() {
  local case_dir prior first middle
  # Never verified at all.
  case_dir=$(make_case rebase-never-verified local-only)
  declare_tier "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-never-verified: a task with no full run must not get the narrowed tier"
  assert_grep "no full passing record for $prior" "$case_dir/verify.err" \
    "rebase-never-verified: the refusal did not name the missing full record"
  [ -z "$(ran_steps "$case_dir")" ] || fail "rebase-never-verified: steps ran on a refused run"
  assert_absent "$case_dir/state/task-x1.verification" \
    "rebase-never-verified: a refused run still wrote the ledger"

  # Only part of the declared set ran at the prior.
  case_dir=$(make_case rebase-partial-prior local-only)
  declare_tier "$case_dir"
  run "$case_dir" v0 "$VERIFY" run task-x1 --step types -- ./pass.sh
  expect_code 0 "$RC" "rebase-partial-prior: the partial run should record"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-partial-prior: a partly verified prior must not anchor the tier"
  assert_grep "no full passing record for $prior" "$case_dir/verify.err" \
    "rebase-partial-prior: the refusal did not name the missing full record"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-partial-prior: a refused run still recorded a post-rebase record"
  # Control: once the prior genuinely holds a full record, the same rebase is accepted.
  at_commit "$case_dir" "$prior" full-at-prior run task-x1
  expect_code 0 "$RC" "rebase-partial-prior: the full run at the prior should pass"
  : > "$case_dir/ran.log"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 0 "$RC" "rebase-partial-prior: a fully verified prior should anchor the tier"

  # A prior whose record also carries a failure.
  case_dir=$(make_case rebase-failed-prior local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  run "$case_dir" v1 "$VERIFY" run task-x1 --step lint -- ./fail.sh
  expect_code 1 "$RC" "rebase-failed-prior: the failing run should record"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-failed-prior: a prior carrying a failure must not anchor the tier"
  assert_grep "no full passing record for $prior" "$case_dir/verify.err" \
    "rebase-failed-prior: the refusal did not name the missing full record"

  # A prior verified only by a post-rebase run is not a full record: no chains.
  case_dir=$(make_case rebase-chain local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  first=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/one.md 'first upstream move'
  rebase_task "$case_dir"
  run "$case_dir" v1 "$VERIFY" run task-x1 --post-rebase "$first"
  expect_code 0 "$RC" "rebase-chain: the first post-rebase run should record"
  middle=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/two.md 'second upstream move'
  rebase_task "$case_dir"
  : > "$case_dir/ran.log"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$middle"
  expect_code 1 "$RC" "rebase-chain: a post-rebase-verified prior must not anchor another tier run"
  assert_grep "no full passing record for $middle" "$case_dir/verify.err" \
    "rebase-chain: the refusal did not name the missing full record"
  # The original full record still anchors any number of rebases.
  run "$case_dir" v2 "$VERIFY" run task-x1 --post-rebase "$first"
  expect_code 0 "$RC" "rebase-chain: the original full record should anchor the second rebase"
  pass "a prior with no full passing record - absent, partial, failed, or post-rebase only - is refused"
}

# --- (x) the gate holds a post-rebase record to its prior and its tier ------

test_gate_holds_post_rebase_to_its_prior_and_tier() {
  local case_dir prior head before missing
  # The prior's full record is contradicted after the post-rebase run.
  case_dir=$(make_case rebase-prior-contradicted local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  before=$(main_of "$case_dir")
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 0 "$RC" "rebase-prior-contradicted: the post-rebase run should record"
  at_commit "$case_dir" "$prior" v-fail run task-x1 --step unit -- ./fail.sh
  expect_code 1 "$RC" "rebase-prior-contradicted: the failing run at the prior should record"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "rebase-prior-contradicted: a head whose prior is recorded failed must not merge"
  assert_grep "no full passing record for $prior" "$case_dir/merge.err" \
    "rebase-prior-contradicted: the refusal did not name the prior"
  assert_not_merged_local "$case_dir" "$before" \
    "rebase-prior-contradicted: local main moved on a contradicted prior"

  # A post-rebase record missing an always step, or a step its diff selects.
  for missing in unit mobile; do
    case_dir=$(make_case "rebase-missing-$missing" local-only)
    declare_tier "$case_dir"
    full_verify "$case_dir"
    prior=$(tip "$case_dir")
    upstream_commit "$case_dir" apps/mobile/app.ts 'export const x = 1;'
    rebase_task "$case_dir"
    before=$(main_of "$case_dir")
    head=$(tip "$case_dir")
    run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
    expect_code 0 "$RC" "rebase-missing-$missing: the post-rebase run should record"
    rewrite_ledger "$case_dir" "/^post-rebase/s/,$missing:passed//"
    run "$case_dir" merge "$MERGE_LOCAL" task-x1
    expect_code 4 "$RC" "rebase-missing-$missing: a post-rebase record without '$missing' must not merge"
    assert_grep "'$missing' has no passing record for commit $head" "$case_dir/merge.err" \
      "rebase-missing-$missing: the refusal did not name the missing tier step"
    assert_not_merged_local "$case_dir" "$before" \
      "rebase-missing-$missing: local main moved without the tier's '$missing' step"
  done

  # A carried step never supersedes a bypass: only a record for the exact
  # commit does, and the prior's pass of 'secrets' is a record for the prior.
  case_dir=$(make_case rebase-bypass-carried local-only)
  declare_tier "$case_dir"
  run "$case_dir" bypass "$VERIFY" bypass task-x1 --step secrets \
    --why "secrets scan skipped during the scanner outage" --by captain
  expect_code 0 "$RC" "rebase-bypass-carried: recording the bypass failed"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  before=$(main_of "$case_dir")
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 0 "$RC" "rebase-bypass-carried: the post-rebase run should record"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  expect_code 4 "$RC" "rebase-bypass-carried: a bypass covered only by a carried step must not merge"
  assert_grep "a bypass of 'secrets' is recorded against this task" "$case_dir/merge.err" \
    "rebase-bypass-carried: the refusal did not name the bypass"
  assert_grep 'never supersede a bypass' "$case_dir/merge.err" \
    "rebase-bypass-carried: the refusal did not say why the carried step does not count"
  assert_not_merged_local "$case_dir" "$before" \
    "rebase-bypass-carried: local main moved over a bypass only a carried step covers"
  pass "the merge gate refuses a post-rebase record whose prior is contradicted, whose tier is incomplete, or whose carried step would be all that covers a bypass"
}

# --- (y) the post-rebase run keeps the full run's guards --------------------

test_post_rebase_keeps_the_run_guards() {
  local case_dir prior
  # A dirty worktree.
  case_dir=$(make_case rebase-dirty local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  printf 'uncommitted\n' >> "$case_dir/wt/README.md"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-dirty: a dirty worktree must be refused"
  assert_grep 'uncommitted changes' "$case_dir/verify.err" \
    "rebase-dirty: the refusal did not name the uncommitted work"
  [ -z "$(ran_steps "$case_dir")" ] || fail "rebase-dirty: steps ran on a dirty worktree"
  git -C "$case_dir/wt" checkout -q -- README.md

  # A prior that is the head itself, and an ad-hoc command.
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$(tip "$case_dir")"
  expect_code 1 "$RC" "rebase-dirty: the head cannot be its own prior"
  assert_grep 'is the current head' "$case_dir/verify.err" \
    "rebase-dirty: the refusal did not say the prior is the head"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior" --step x -- ./pass.sh
  expect_code 1 "$RC" "rebase-dirty: an ad-hoc command must not ride on --post-rebase"
  assert_grep 'cannot be combined' "$case_dir/verify.err" \
    "rebase-dirty: the refusal did not say the two cannot be combined"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-dirty: a refused run still recorded a post-rebase record"

  # HEAD moving while the tier runs.
  case_dir=$(make_case rebase-head-moves local-only)
  declare_tier "$case_dir"
  full_verify "$case_dir"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  sed 's/^unit = .*/unit = git commit -q --allow-empty -m moved/' \
    "$case_dir/config/verify/myproj" > "$case_dir/tier.new"
  mv "$case_dir/tier.new" "$case_dir/config/verify/myproj"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-head-moves: a head that moved mid-run must not record"
  assert_grep 'HEAD moved' "$case_dir/verify.err" \
    "rebase-head-moves: the refusal did not name the moved HEAD"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-head-moves: a moved HEAD still recorded a post-rebase record"

  # No declared tier.
  case_dir=$(make_case rebase-no-tier local-only)
  mkdir -p "$case_dir/config/verify"
  printf 'test = ./pass.sh\n' > "$case_dir/config/verify/myproj"
  run "$case_dir" full "$VERIFY" run task-x1
  expect_code 0 "$RC" "rebase-no-tier: the full run should pass"
  prior=$(tip "$case_dir")
  upstream_commit "$case_dir" docs/notes.md 'upstream notes'
  rebase_task "$case_dir"
  run "$case_dir" verify "$VERIFY" run task-x1 --post-rebase "$prior"
  expect_code 1 "$RC" "rebase-no-tier: a project with no declared tier must not get a narrowed run"
  assert_grep 'declares no post-rebase tier' "$case_dir/verify.err" \
    "rebase-no-tier: the refusal did not name the missing tier"
  [ "$(post_rebase_records "$case_dir")" = 0 ] \
    || fail "rebase-no-tier: a refused run still recorded a post-rebase record"
  pass "the post-rebase run keeps the full run's guards and refuses without a declared tier"
}

check_bad_tier() {  # <case_dir> <tier line> <expected refusal>
  local case_dir=$1 bad=$2 expect=$3
  printf 'types = ./pass.sh\n%s\n' "$bad" > "$case_dir/config/verify/myproj"
  run "$case_dir" verify "$VERIFY" run task-x1
  expect_code 1 "$RC" "rebase-bad-tier: '$bad' should refuse the run"
  assert_grep "$expect" "$case_dir/verify.err" \
    "rebase-bad-tier: '$bad' was not refused as '$expect'"
  run "$case_dir" merge "$MERGE_LOCAL" task-x1
  [ "$RC" -ne 0 ] || fail "rebase-bad-tier: '$bad' let the merge proceed"
  assert_grep "$expect" "$case_dir/merge.err" \
    "rebase-bad-tier: the merge did not refuse '$bad' as '$expect'"
}

test_malformed_tier_refuses_loudly() {
  local case_dir
  case_dir=$(make_case rebase-bad-tier local-only)
  mkdir -p "$case_dir/config/verify"
  check_bad_tier "$case_dir" '@post-rebase ghost always' "post-rebase tier names undeclared step 'ghost'"
  check_bad_tier "$case_dir" '@post-rebase types sometimes' "unknown post-rebase selector 'sometimes'"
  check_bad_tier "$case_dir" '@post-rebase types if-changed' 'needs at least one path pattern'
  check_bad_tier "$case_dir" '@post-rebase types always apps/*' 'takes no path patterns'
  check_bad_tier "$case_dir" '@post-rebase types if-changed apps/*' "declares no '@post-rebase <step> always' step"
  check_bad_tier "$case_dir" '@rebase types always' "unknown directive '@rebase'"
  pass "a malformed post-rebase tier is refused by both the run and the merge, never read as no tier"
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
test_verify_records_gitignored_cache
test_pr_refuses_unknown_head
test_pr_resolves_head_after_worktree_returned
test_override_note_keeps_pr_metadata_parseable
test_override_refuses_when_metadata_cannot_be_rewritten
test_repeated_identical_override_still_records
test_override_reason_with_backslash_records
test_unusable_declaration_refuses
test_declared_step_cannot_eat_the_step_list
test_duplicate_runs_refuse_in_either_order
test_repeated_passing_runs_still_merge
test_steps_from_separate_runs_combine
test_bypass_is_recorded_in_both_homes
test_bypass_survives_a_damaged_ledger
test_post_rebase_tier_verifies_and_merges
test_post_rebase_selects_own_files_the_rebase_changed
test_post_rebase_refuses_a_head_that_is_not_a_rebase
test_gate_reproves_the_rebase_itself
test_post_rebase_refuses_without_a_full_prior_record
test_gate_holds_post_rebase_to_its_prior_and_tier
test_post_rebase_keeps_the_run_guards
test_malformed_tier_refuses_loudly
