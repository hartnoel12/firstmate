#!/usr/bin/env bash
# Behavior tests for bin/fm-bash-syntax-check.sh.
#
# Firstmate ships to macOS fleets whose /bin/bash is 3.2.57. Bash 3.2 tracks
# quote state through a heredoc body while scanning for the closing `)` of a
# command substitution, so one apostrophe inside `VAR=$(cat <<EOF ...)` breaks
# parsing of the whole script. Bash 5 parses it fine, which is why the bug in
# issue #166 shipped once and then returned in #945 (bin/fm-brief.sh) - the
# existing `bash -n` regression test ran under whatever bash CI had, and CI is
# Linux. These tests pin the three things that stop the third recurrence: the
# guard detects failures, it refuses to pass vacuously under a newer bash, and
# the hazardous idiom is gone from bin/.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-bash-syntax-check.sh"
CI="$ROOT/.github/workflows/ci.yml"
TMP_ROOT=$(fm_test_tmproot fm-bash-syntax-check)

# A self-contained fixture repo: a copy of the guard plus a stub root-set owner,
# so failure paths can be exercised without editing firstmate's real scripts.
make_fixture() {  # <name>
  local fix="$TMP_ROOT/$1"
  mkdir -p "$fix/bin"
  cp "$GUARD" "$fix/bin/fm-bash-syntax-check.sh"
  chmod +x "$fix/bin/fm-bash-syntax-check.sh"
  cat > "$fix/bin/fm-lint.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--list-roots" ] || exit 2
cd "$(dirname "$0")/.." || exit 1
printf '%s\n' bin/*.sh
STUB
  chmod +x "$fix/bin/fm-lint.sh"
  printf '%s\n' "$fix"
}

test_owner_exists_and_executable() {
  assert_present "$GUARD" "bin/fm-bash-syntax-check.sh is missing"
  [ -x "$GUARD" ] || fail "bin/fm-bash-syntax-check.sh must be executable so CI can run it directly"
  pass "bash syntax guard exists and is executable"
}

test_clean_repo_passes() {
  local out rc
  out=$("$GUARD" 2>&1); rc=$?
  expect_code 0 "$rc" "the guard must pass on the current tree (got: $out)"
  assert_contains "$out" "roots parse cleanly" "the guard must report how many roots it checked"
  pass "guard passes on the current tree"
}

# Direction one of "a guard you have not seen fail is not a guard": a root that
# does not parse must make the guard exit nonzero and name the file.
test_guard_reports_an_unparseable_root() {
  local fix out rc
  fix=$(make_fixture broken)
  cat > "$fix/bin/fm-broken.sh" <<'BAD'
#!/usr/bin/env bash
if [ -n "$1" ]; then
  echo unterminated
BAD
  out=$("$fix/bin/fm-bash-syntax-check.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "the guard must fail when a root does not parse"
  assert_contains "$out" "fm-broken.sh" "the guard must name the failing file"
  assert_contains "$out" "failed to parse" "the guard must summarise the failure"
  pass "guard fails and names the file when a root does not parse"
}

# The exact regression: an apostrophe inside a heredoc nested in a command
# substitution. Only meaningful where /bin/bash is 3.2, so it is gated - but on
# macOS (and the macos-stock-bash CI lane) it runs for real.
test_apostrophe_in_command_substitution_is_caught_under_bash32() {
  local fix out rc version
  version=$(/bin/bash -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null || printf 'none')
  case "$version" in
    3.2.*) ;;
    *) pass "skip: /bin/bash is $version, not 3.2 (hazard is invisible to newer bash)"; return 0 ;;
  esac

  fix=$(make_fixture apostrophe)
  cat > "$fix/bin/fm-hazard.sh" <<'BAD'
#!/usr/bin/env bash
TEXT=$(cat <<EOF
it would bypass firstmate's authority check
EOF
)
printf '%s\n' "$TEXT"
BAD
  out=$("$fix/bin/fm-bash-syntax-check.sh" --require-bash32 2>&1); rc=$?
  expect_code 1 "$rc" "an apostrophe in a heredoc inside \$( ) must fail under bash 3.2"
  assert_contains "$out" "fm-hazard.sh" "the guard must name the hazardous file"

  # Same prose, heredoc moved into a function body: the sanctioned fix parses.
  cat > "$fix/bin/fm-hazard.sh" <<'GOOD'
#!/usr/bin/env bash
hazard_text() {
  cat <<EOF
it would bypass firstmate's authority check
EOF
}
TEXT=$(hazard_text)
printf '%s\n' "$TEXT"
GOOD
  out=$("$fix/bin/fm-bash-syntax-check.sh" --require-bash32 2>&1); rc=$?
  expect_code 0 "$rc" "the function-wrapped form must parse under bash 3.2 (got: $out)"
  pass "guard catches the apostrophe hazard and clears the function-wrapped fix"
}

# A sweep that silently runs under bash 5 proves nothing about the fleet. This
# is what made the pre-existing fm-brief.sh parse test miss #945.
test_require_bash32_refuses_a_newer_bash() {
  local fake out rc
  fake="$TMP_ROOT/fake-bash"
  cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then printf '5.2.21(1)-release'; exit 0; fi
exit 0
FAKE
  chmod +x "$fake"
  out=$("$GUARD" --bash "$fake" --require-bash32 2>&1); rc=$?
  expect_code 1 "$rc" "--require-bash32 must refuse a newer bash instead of passing vacuously"
  assert_contains "$out" "would prove nothing" "the refusal must explain why a newer bash is not enough"

  out=$("$GUARD" --bash "$fake" 2>&1); rc=$?
  expect_code 0 "$rc" "without --require-bash32 an arbitrary interpreter is allowed"
  pass "--require-bash32 refuses a newer bash rather than passing vacuously"
}

test_missing_interpreter_is_loud() {
  local out rc
  out=$("$GUARD" --bash "$TMP_ROOT/no-such-bash" 2>&1); rc=$?
  expect_code 127 "$rc" "a missing interpreter must be reported, not skipped"
  assert_contains "$out" "no executable Bash" "the guard must say which interpreter is missing"
  pass "missing interpreter is reported rather than skipped"
}

# Structural ban, checked on every CI lane rather than only the macOS one: the
# idiom itself must stay out of bin/, so prose there can carry apostrophes.
#
# The rule is "never open a heredoc inside a command substitution", not "never
# write `cat`". Matching only `=$(cat <<` would let `filter=$(sed -f - <<SED`,
# `out=$(jq -n -f /dev/stdin <<JQ` and `"$(cat <<EOF"` through, and each is the
# same hazard: it ships latent because an even number of apostrophes parses by
# luck, then breaks the fleet when someone edits the prose. That is how #945 got
# in. Factored into a function so the ban can be shown rejecting those forms
# (test_structural_ban_rejects_the_broadened_forms) rather than merely asserted.
heredoc_in_command_substitution_hits() {  # <file>...
  # `$(` or a backtick, then a heredoc opener before the substitution closes.
  # `[^()]*` keeps arithmetic `$(( x << y ))` out; `[^<]` on both sides keeps
  # `<<<` herestrings out; requiring no `)` before the `<<` means a heredoc
  # opened after the substitution already closed stays top level, and so does
  # the safe reverse nesting - a `$( )` sitting inside a heredoc body.
  # Comment lines are skipped: four bin/ scripts document the rule by quoting it.
  # shellcheck disable=SC2016  # deliberate: this is a literal search pattern, not an expansion.
  grep -nHE '\$\([^()]*[^<]<<[^<]|`[^`]*[^<]<<[^<]' "$@" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}

test_bin_has_no_heredoc_in_command_substitution() {
  local hits
  hits=$(heredoc_in_command_substitution_hits "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh)
  [ -z "$hits" ] || fail "bin/ must not open a heredoc inside \$( ); put it in a function body:
$hits"
  pass "bin/ opens no heredoc inside a command substitution"
}

# A ban you have not seen reject something is not a ban. Every fixture here is a
# real heredoc-in-command-substitution that the old `=$(cat <<` spelling missed.
test_structural_ban_rejects_the_broadened_forms() {
  local dir name hits
  dir="$TMP_ROOT/ban-fixtures"
  mkdir -p "$dir"

  cat > "$dir/sed.sh" <<'BAD'
filter=$(sed -f - <<SED
s/x/firstmate's y/
SED
)
BAD
  cat > "$dir/jq.sh" <<'BAD'
out=$(jq -n -f /dev/stdin <<JQ
{ note: "firstmate's authority" }
JQ
)
BAD
  cat > "$dir/nonassign.sh" <<'BAD'
printf '%s' "$(cat <<EOF
firstmate's authority check
EOF
)"
BAD
  cat > "$dir/dash.sh" <<'BAD'
TEXT=$(cat <<-EOF
	firstmate's authority check
	EOF
)
BAD
  cat > "$dir/backtick.sh" <<'BAD'
TEXT=`cat <<EOF
firstmate's authority check
EOF
`
BAD

  for name in sed jq nonassign dash backtick; do
    hits=$(heredoc_in_command_substitution_hits "$dir/$name.sh")
    [ -n "$hits" ] || fail "the structural ban must reject $name.sh: it opens a heredoc inside a command substitution"
  done

  # ...and must not fire on the forms that are genuinely safe, or bin/ could not
  # keep using them: a herestring, an arithmetic left shift, a heredoc opened
  # after the substitution closed, and a `$( )` inside a top-level heredoc body
  # (bin/fm-brief.sh does exactly this at its `read -r MODE _ <<EOF` block).
  cat > "$dir/safe.sh" <<'GOOD'
val=$(tr a b <<<"$MODE")
hb=$(( HEARTBEAT * (1 << streak) ))
label=$(printf '%s' one) ; cat <<EOF
firstmate's authority check
EOF
read -r MODE _ <<EOF
$(printf '%s %s' ship now)
EOF
GOOD
  hits=$(heredoc_in_command_substitution_hits "$dir/safe.sh")
  [ -z "$hits" ] || fail "the structural ban must not flag safe forms:
$hits"
  pass "structural ban rejects non-cat, non-assignment and backtick forms while clearing safe ones"
}

test_ci_runs_the_guard_on_stock_bash() {
  assert_grep 'bin/fm-bash-syntax-check.sh --require-bash32' "$CI" \
    "the macOS stock-bash CI lane must run the guard with --require-bash32"
  pass "CI runs the guard under stock macOS bash"
}

test_owner_exists_and_executable
test_clean_repo_passes
test_guard_reports_an_unparseable_root
test_apostrophe_in_command_substitution_is_caught_under_bash32
test_require_bash32_refuses_a_newer_bash
test_missing_interpreter_is_loud
test_bin_has_no_heredoc_in_command_substitution
test_structural_ban_rejects_the_broadened_forms
test_ci_runs_the_guard_on_stock_bash
