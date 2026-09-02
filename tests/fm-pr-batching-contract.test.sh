#!/usr/bin/env bash
# Regression for the PR-batching default in AGENTS.md section 7 (Intake and
# authority): a ship defaults to one pull request per coherent area of work,
# not one per finding, with the captain's named exceptions preserved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"

test_agents_md_states_pr_batching_default() {
  assert_grep "Default a ship to one pull request per coherent area of work, not one per finding" "$AGENTS" \
    "AGENTS.md is missing the one-PR-per-coherent-area default"
  pass "AGENTS.md: states the one-PR-per-coherent-area-of-work default"
}

test_agents_md_preserves_pr_batching_exceptions() {
  assert_grep "a sign-in or auth render path where a mistake is a total outage" "$AGENTS" \
    "AGENTS.md dropped the auth-render-path exception"
  assert_grep "a migration paired with a behavior change where revert granularity genuinely matters" "$AGENTS" \
    "AGENTS.md dropped the migration-plus-behavior-change exception"
  assert_grep "a security fix that needs its own tests" "$AGENTS" \
    "AGENTS.md dropped the security-fix exception"
  assert_grep "a captain decision outstanding on one half that would otherwise hold shipped value hostage" "$AGENTS" \
    "AGENTS.md dropped the outstanding-captain-decision exception"
  assert_grep "batching still means fewer, larger, coherent pull requests, never a grab-bag" "$AGENTS" \
    "AGENTS.md dropped the scope-discipline reminder that batching is not a grab-bag"
  pass "AGENTS.md: preserves the captain's named PR-batching exceptions"
}

test_agents_md_did_not_grow() {
  local lines
  lines=$(wc -l < "$AGENTS")
  [ "$lines" -le 510 ] || fail "AGENTS.md grew to $lines lines; this task must not grow it (route detail to a skill instead)"
  pass "AGENTS.md: line count stayed within a tight margin of its starting size"
}

test_agents_md_states_pr_batching_default
test_agents_md_preserves_pr_batching_exceptions
test_agents_md_did_not_grow
