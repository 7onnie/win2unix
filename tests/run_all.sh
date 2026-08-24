#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Fail=0
for _T in "$_Here"/test_*.sh; do
    printf '\n=== %s ===\n' "${_T##*/}"
    bash "$_T" || _Fail=1
done
[ "$_Fail" -eq 0 ] && printf '\nALLE TESTS GRUEN\n' || printf '\nTESTS FEHLGESCHLAGEN\n'
exit "$_Fail"
