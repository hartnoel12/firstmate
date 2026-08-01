#!/usr/bin/env bash
# Regression tests for Bash 3.2 empty-array expansion under `set -u`.
#
# Firstmate ships to macOS fleets whose /bin/bash is 3.2.57. There, expanding an
# EMPTY array as "${a[@]}" or "${a[*]}" under `set -u` is a fatal
# `a[@]: unbound variable`, while Bash 5 expands it to nothing and carries on.
# Measured on a real 3.2.57 (docs/verification/bash32-empty-array.md):
#
#   "${a[@]}" empty          -> a[@]: unbound variable      Bash 5: fine
#   "${a[*]}" empty          -> a[*]: unbound variable      Bash 5: fine
#   "${a[@]+"${a[@]}"}"      -> fine, empty and populated
#   "${#a[@]}"               -> fine (0)
#   "${a[@]:1}"              -> fine, even on an empty array
#
# That asymmetry is why issue #173's `shared_args[@]: unbound variable` in
# fm-spawn.sh's batch dispatch shipped: every Linux CI lane runs Bash 5, and the
# macOS lane only PARSE-checks (bin/fm-bash-syntax-check.sh). The crash needs a
# real 3.2 to RUN, and nothing ran one. These tests close that.
#
# Two halves:
#   runtime  - needs a real Bash 3.2. Proves the guard can see the bug, then
#              drives fm-spawn.sh's batch dispatch through it with zero, one,
#              and several shared flags. Reports a gate skip when none is found.
#   static   - runs on every lane. Every array in bin/ that is initialised empty
#              and appended to conditionally must be expanded through the `+`
#              guard or protected by a "${#name[@]}" count test in its own file.
#              That pair is exactly the accumulator shape that reaches an
#              expansion with nothing in it.
#
# Point FM_BASH32 at a 3.2 interpreter to run the runtime half anywhere;
# otherwise /bin/bash is used when it is itself 3.2 (the macOS CI lane).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-bash32-empty-array)

# Resolve an interpreter that really is Bash 3.2; echo nothing when there is none.
resolve_bash32() {
  local candidate version
  for candidate in "${FM_BASH32:-}" /bin/bash; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016  # single quotes are deliberate: $BASH_VERSION must expand in the candidate, not here
    version=$("$candidate" -c 'printf %s "$BASH_VERSION"' 2>/dev/null) || continue
    case "$version" in
      3.2.*) printf '%s\n' "$candidate"; return 0 ;;
    esac
  done
  return 1
}

# --- the runtime half -------------------------------------------------------

# Direction one of "a guard you have not seen fail is not a guard": the
# unguarded idiom must actually die under this interpreter, and the guarded one
# must actually survive. Without this the whole runtime half could be passing
# because it is measuring nothing.
# shellcheck disable=SC2016  # every -c body below is deliberately single-quoted: it is a program for the 3.2 interpreter, not text to expand here
test_bash32_still_rejects_the_unguarded_idiom() {  # <bash32>
  local bash32=$1 out rc
  out=$("$bash32" -c 'set -u; a=(); printf "[%s]" "${a[@]}"; echo REACHED' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "bash32-control: the unguarded expansion should have failed under $bash32"
  assert_contains "$out" 'unbound variable' \
    "bash32-control: the unguarded expansion failed for some other reason"

  out=$("$bash32" -c 'set -u; a=(); printf "[%s]" "${a[@]+"${a[@]}"}"; echo REACHED' 2>&1)
  rc=$?
  expect_code 0 "$rc" "bash32-control: the guarded expansion should survive an empty array"
  assert_contains "$out" REACHED "bash32-control: the guarded expansion did not run to completion"

  out=$("$bash32" -c 'set -u; a=(one); printf "[%s]" "${a[@]+"${a[@]}"}"; echo REACHED' 2>&1)
  expect_code 0 "$?" "bash32-control: the guarded expansion should survive a single-element array"
  assert_contains "$out" '[one]' "bash32-control: the guarded expansion lost the only element"
  pass "Bash 3.2 rejects the unguarded empty-array expansion and accepts the guarded one"
}

# The reported crash itself: fm-spawn.sh batch dispatch assembles the flags
# shared across every pair into an array that is empty when no flags were
# passed. Zero, one, and several, because only the zero case ever crashed and
# only the several case proves the guard still passes them all through.
test_spawn_batch_survives_every_shared_flag_count() {  # <bash32>
  local bash32=$1 label flags out home
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  while IFS='|' read -r label flags; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # flags is an intentional word-split flag list
    out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
      "$bash32" "$SPAWN" nope-b32-a=projects/none-a nope-b32-b=projects/none-b $flags 2>&1)
    assert_not_contains "$out" 'unbound variable' \
      "batch-$label: batch dispatch hit an unbound variable under Bash 3.2"
    # The pairs must still be dispatched: a crash-free run that silently
    # dispatched nothing would pass the assertion above for the wrong reason.
    assert_contains "$out" 'batch: FAILED to spawn nope-b32-a' \
      "batch-$label: the first pair was never dispatched"
    assert_contains "$out" 'batch: FAILED to spawn nope-b32-b' \
      "batch-$label: the second pair was never dispatched"
  done <<'ROWS'
no-shared-flags|
one-shared-flag|--harness codex
several-shared-flags|--harness codex --model some-model --effort low
ROWS
  pass "fm-spawn batch dispatch runs under Bash 3.2 with zero, one, and several shared flags"
}

test_runtime_half() {
  local bash32
  if ! bash32=$(resolve_bash32); then
    printf 'skip: no Bash 3.2 interpreter (set FM_BASH32 to one); runtime half not run\n'
    return 0
  fi
  test_bash32_still_rejects_the_unguarded_idiom "$bash32"
  test_spawn_batch_survives_every_shared_flag_count "$bash32"
}

# --- the static half --------------------------------------------------------

# An array that is declared empty AND appended to conditionally is the shape
# that reaches an expansion with nothing in it. Every such expansion in bin/
# must carry the `+` guard, or the file must test "${#name[@]}" somewhere so the
# empty case is handled explicitly. Arrays assigned from a source that is never
# empty do not match, which is what keeps this free of an allowlist.

# unguarded_accumulators <file>: echo each array in <file> that is initialised
# empty, appended to conditionally, expanded bare, and neither `+`-guarded nor
# count-tested. The guarded form contains the bare form as its own fallback
# text, so guarded occurrences are deleted before the bare one is looked for.
unguarded_accumulators() {  # <file>
  local file=$1 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Only accumulators: declared empty somewhere in the same file.
    grep -qE "(^|[^A-Za-z0-9_])$name=\(\)" "$file" || continue
    # An explicit count test in the file means the empty case was considered.
    grep -qE "\\\$\{#$name\[@\]\}" "$file" && continue
    sed "s/\\\${$name\[[@*]\]+\"\\\${$name\[[@*]\]}\"}//g" "$file" \
      | grep -qE "\\\$\{$name\[[@*]\]\}" || continue
    printf '%s\n' "$name"
  done < <(grep -oE '(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*\+=\(' "$file" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | LC_ALL=C sort -u)
}

test_no_unguarded_accumulator_expansions_in_bin() {
  local file name findings=''
  for file in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh; do
    [ -f "$file" ] || continue
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      findings="$findings${findings:+
}$(basename "$file"): $name is expanded bare, without the '+' guard and without a count test"
    done < <(unguarded_accumulators "$file")
  done
  [ -z "$findings" ] || fail "unguarded empty-array expansions in bin/:
$findings
Guard each with the plus-default idiom, or test its element count before
expanding. An empty array expanded bare is a fatal unbound-variable error on
Bash 3.2 (docs/verification/bash32-empty-array.md)."
  pass "no bin/ accumulator array is expanded without a guard or a count test"
}

# The static half must be able to fail, so plant the hazard in a fixture and
# confirm the same rule reports it.
test_the_static_rule_reports_a_planted_hazard() {
  local bad good
  mkdir -p "$TMP_ROOT"
  bad="$TMP_ROOT/planted-bad.sh"
  good="$TMP_ROOT/planted-good.sh"
  cat > "$bad" <<'BAD'
#!/usr/bin/env bash
set -eu
flags=()
[ -z "${SOMETHING:-}" ] || flags+=(--something "$SOMETHING")
printf '%s\n' "${flags[@]}"
BAD
  cat > "$good" <<'GOOD'
#!/usr/bin/env bash
set -eu
flags=()
[ -z "${SOMETHING:-}" ] || flags+=(--something "$SOMETHING")
printf '%s\n' "${flags[@]+"${flags[@]}"}"
GOOD
  [ "$(unguarded_accumulators "$bad")" = flags ] \
    || fail "the static rule did not report a planted unguarded expansion"
  [ -z "$(unguarded_accumulators "$good")" ] \
    || fail "the static rule reports the guarded idiom it is asking for"
  pass "the static rule reports a planted unguarded expansion and accepts the guarded one"
}

# The static half runs first so its results are the script's first output. A
# leading `skip:` line would make bin/fm-test-run.sh class the whole script as
# gate-skipped on the Bash 5 lanes, hiding the static half's real results.
test_no_unguarded_accumulator_expansions_in_bin
test_the_static_rule_reports_a_planted_hazard
test_runtime_half
