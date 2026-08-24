#!/usr/bin/env bash
# Minimales Assert-Harness. Keine Abhaengigkeiten - laeuft auf nacktem macOS mit bash 3.2.

_TestsRun=0
_TestsFailed=0

t_assert_eq() {
    local _Expected="$1" _Actual="$2" _Label="$3"
    _TestsRun=$((_TestsRun + 1))
    if [ "$_Expected" = "$_Actual" ]; then
        printf '  ok   %s\n' "$_Label"
    else
        _TestsFailed=$((_TestsFailed + 1))
        printf '  FAIL %s\n' "$_Label"
        printf '       erwartet: [%s]\n' "$_Expected"
        printf '       bekommen: [%s]\n' "$_Actual"
    fi
}

t_assert_contains() {
    local _Haystack="$1" _Needle="$2" _Label="$3"
    _TestsRun=$((_TestsRun + 1))
    case "$_Haystack" in
        *"$_Needle"*)
            printf '  ok   %s\n' "$_Label"
            ;;
        *)
            _TestsFailed=$((_TestsFailed + 1))
            printf '  FAIL %s\n' "$_Label"
            printf '       suchte:   [%s]\n' "$_Needle"
            printf '       in:       [%s]\n' "$_Haystack"
            ;;
    esac
}

t_assert_rc() {
    local _Expected="$1" _Actual="$2" _Label="$3"
    t_assert_eq "$_Expected" "$_Actual" "$_Label"
}

t_skip() {
    printf '  SKIP %s\n' "$1"
}

t_summary() {
    printf '\n%s: %d Tests, %d Fehler\n' "${0##*/}" "$_TestsRun" "$_TestsFailed"
    [ "$_TestsFailed" -eq 0 ] || exit 1
    exit 0
}
