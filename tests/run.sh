#!/usr/bin/env bash
# Acceptance test runner (CONTRACT §7).
#   tests/run.sh          all tests
#   tests/run.sh --fast   skip tests whose file has a "# slow" line
#   LAB_INSIDE_AC21=1 tests/run.sh
#                         set only by AC-21, which runs `make test` itself:
#                         skips the file declaring AC-21 so it does not recurse.
#                         Nothing else can be skipped this way.
#
# Each test file declares the ACs it covers in a "# AC: AC-xx[, AC-yy]" line
# and prints one line per check. An AC fails when:
#   - any of its checks fails,
#   - its test file aborts, or stops before its last line (exit, return),
#   - it is listed in tests/expected-acs but no check reported on it.
# Exits 1 if any AC fails.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
export TESTS_DIR=tests
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
RESULTS="${work}/results"
: >"$RESULTS"
export RESULTS

fast=0
[[ ${1:-} == --fast ]] && fast=1

# shellcheck source=tests/lib.sh
source tests/lib.sh

if ! $COMPOSE ps --status running --services 2>/dev/null | grep -qx client; then
  echo "lab is not running; run 'make up' first" >&2
  exit 2
fi

declared_acs() { sed -n 's/^# AC:[[:space:]]*//p' "$1" | tr ',' ' ' | tr -s ' '; }

skipped=()
for t in tests/ac/*.sh; do
  name=$(basename "$t")
  acs=$(declared_acs "$t")
  if [[ -z $acs ]]; then
    fail TEST "${name}: no '# AC:' line"
    continue
  fi
  if (( fast )) && grep -q '^# slow' "$t"; then
    echo "SKIP ${name} (slow): ${acs}"
    skipped+=($acs)
    continue
  fi
  if [[ ${LAB_INSIDE_AC21:-} == 1 && " ${acs} " == *" AC-21 "* ]]; then
    echo "SKIP ${name} (inside AC-21): ${acs}"
    skipped+=($acs)
    continue
  fi
  # Each test runs in a subshell so its variables cannot leak into the next.
  # The marker command is appended to the file's own text, so it runs only if
  # the file runs to its end: an `exit` or a `return` anywhere skips it.
  marker="${work}/${name}.complete"
  ( source <(cat "$t"; printf '\ntouch %q\n' "$marker") )
  rc=$?
  for ac in $acs; do
    if (( rc != 0 )); then
      fail "$ac" "${name} aborted (exit ${rc}); its remaining checks did not run"
    elif [[ ! -e $marker ]]; then
      fail "$ac" "${name} ended before its last line; its remaining checks did not run"
    elif ! grep -q "^${ac} " "$RESULTS"; then
      fail "$ac" "${name} declares ${ac} but reported no check for it"
    fi
  done
done

if [[ ! -r tests/expected-acs ]]; then
  fail TEST "tests/expected-acs is missing; cannot tell which ACs must be checked"
fi
while read -r ac; do
  [[ -z $ac || $ac == \#* ]] && continue
  if [[ " ${skipped[*]} " == *" ${ac} "* ]]; then
    continue
  fi
  if ! grep -q "^${ac} " "$RESULTS"; then
    fail "$ac" "listed in tests/expected-acs but no test reported on it"
  fi
done < <(cat tests/expected-acs 2>/dev/null)

echo "---"
failed=0
while read -r ac; do
  if grep -q "^${ac} FAIL$" "$RESULTS"; then
    echo "${ac}: FAIL"
    failed=1
  else
    echo "${ac}: PASS"
  fi
done < <(cut -d' ' -f1 "$RESULTS" | sort -u)
for ac in "${skipped[@]}"; do
  echo "${ac}: SKIP"
done

if [[ ! -s $RESULTS ]]; then
  echo "no checks ran"
  exit 1
fi
exit "$failed"
