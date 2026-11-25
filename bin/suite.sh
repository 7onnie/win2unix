#!/usr/bin/env bash
# Testsuite-Einstieg: fuehrt jede tests/test_*.sh aus und schliesst mit der
# Summenzeile "N bestanden, M gefallen". rc 0 = gruen, rc != 0 = rot.
# Nur bash und coreutils - kein bats, kein rsync, kein Netz noetig. Tests, die
# ein daemon-faehiges rsync brauchen, skippen sich selbst (und werden unten
# namentlich aufgelistet).
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Tests="$(cd "$_Here/../tests" && pwd)"

_Pass=0
_Fail=0
_Skip=0
_Bad=""
_SkipLines=""
_Re='^([^ ]+): ([0-9]+) Tests, ([0-9]+) Fehler, ([0-9]+) uebersprungen$'

for _T in "$_Tests"/test_*.sh; do
    _Name="${_T##*/}"
    printf '\n=== %s ===\n' "$_Name"
    _Out="$(bash "$_T" 2>&1)"; _Rc=$?
    printf '%s\n' "$_Out"
    _Got=0
    while IFS= read -r _Line; do
        if [[ "$_Line" =~ $_Re ]]; then
            _Got=1
            _Pass=$((_Pass + BASH_REMATCH[2] - BASH_REMATCH[3]))
            _Fail=$((_Fail + BASH_REMATCH[3]))
            _Skip=$((_Skip + BASH_REMATCH[4]))
        elif [[ "$_Line" == "  SKIP "* ]]; then
            _SkipLines="$_SkipLines
  $_Name:${_Line#  SKIP }"
        fi
    done <<EOF
$_Out
EOF
    # Datei ohne Summenzeile (Absturz) oder mit rc != 0 ist ein Fehler, auch
    # wenn keine einzelne Assertion gefallen ist.
    if [ "$_Rc" -ne 0 ] || [ "$_Got" -eq 0 ]; then
        _Bad="$_Bad $_Name"
        [ "$_Got" -eq 1 ] || _Fail=$((_Fail + 1))
    fi
done

if [ "$_Skip" -gt 0 ]; then
    printf '\nUebersprungen (%d):%s\n' "$_Skip" "$_SkipLines"
fi
[ -z "$_Bad" ] || printf '\nRot in:%s\n' "$_Bad"
printf '\n%d bestanden, %d gefallen\n' "$_Pass" "$_Fail"
[ -z "$_Bad" ] && [ "$_Fail" -eq 0 ]
