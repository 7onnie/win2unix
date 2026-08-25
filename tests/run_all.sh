#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Fail=0
for _T in "$_Here"/test_*.sh; do
    printf '\n=== %s ===\n' "${_T##*/}"
    bash "$_T" || _Fail=1
done
if [ "$_Fail" -eq 0 ]; then
    printf '\nALLE TESTS GRUEN\n'
else
    printf '\nTESTS FEHLGESCHLAGEN\n'
fi
exit "$_Fail"
