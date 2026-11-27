#!/usr/bin/env bash
# --status-file und Exit-Code 3 (Issue #9). Die Statusdatei ist die einzige
# Quelle, aus der die TUI Phase, Fortschritt und Urteil eines Dienstes liest.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

_TmpRoot="$(mktemp -d)"
export TMPDIR="$_TmpRoot"
trap 'd_stop; rm -rf "$_TmpRoot"' EXIT

sval() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# ---- Exit 3: Einrichtungsfehler beim Parsen ---------------------------------
_Out="$(bash "$_Root/pull.sh" "kein-rsync-url" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "falsche Quell-URL: Exit 3 (Einrichtungsfehler, kein Neustart)"
_Out="$(bash "$_Root/pull.sh" --jobs abc "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "ungueltiges --jobs: Exit 3"
_Out="$(bash "$_Root/pull.sh" --verify-only --no-verify "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "abgelehnte Optionskombination: Exit 3"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi
_Src="$_TmpRoot/src"
mkdir -p "$_Src/A/B/NAME"
_I=1
while [ "$_I" -le 12 ]; do
    mkdir -p "$_Src/A/B/NAME/$_I"
    echo "datei $_I" > "$_Src/A/B/NAME/$_I/f.txt"
    _I=$((_I + 1))
done
if ! d_start "$_Src"; then
    t_skip "Daemon nicht startbar"
    t_summary
fi

# ---- PASS-Lauf ----------------------------------------------------------------
_Z="$_TmpRoot/z1"
mkdir -p "$_Z"
_St="$_TmpRoot/st1"
export W2U_STATUS_TRACE="$_TmpRoot/trace1"
_Out="$(bash "$_Root/pull.sh" --jobs 2 --status-file "$_St" "$D_Url/A/B/NAME" "$_Z" 2>&1)"; _Rc=$?
unset W2U_STATUS_TRACE
t_assert_rc 0 "$_Rc" "PASS-Lauf: rc 0"
t_assert_eq "done" "$(sval "$_St" phase)" "Endphase done"
t_assert_eq "PASS" "$(sval "$_St" result)" "result=PASS"
_Rep="$(sval "$_St" report)"
[ -f "$_Rep" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "report zeigt auf den gespeicherten Bericht"
_Tot="$(sval "$_St" chunks_total)"
_Done="$(sval "$_St" chunks_done)"
[ -n "$_Tot" ] && [ "$_Tot" -gt 0 ] 2>/dev/null && _Ok=ja || _Ok=nein
t_assert_eq "ja" "$_Ok" "chunks_total ist gesetzt"
t_assert_eq "$_Tot" "$_Done" "chunks_done = chunks_total am Ende"
t_assert_eq "2" "$(sval "$_St" parallel)" "parallel = gewaehlte Parallelitaet"
case "$(sval "$_St" updated)" in
    ''|*[!0-9]*) _Ok=nein ;;
    *) _Ok=ja ;;
esac
t_assert_eq "ja" "$_Ok" "updated ist ein Zeitstempel"
_Seq="$(tr '\n' ' ' < "$_TmpRoot/trace1")"
t_assert_eq "preflight decompose parallel sweep verify done " "$_Seq" "Phasen in der richtigen Reihenfolge"
_Tmps="$(ls -A "$_TmpRoot" | grep -c '^st1\.tmp')" || _Tmps=0
t_assert_eq "0" "$_Tmps" "keine liegengebliebenen Zwischendateien der Statusdatei"

# ---- Abbruch: Quelle nicht erreichbar -------------------------------------------
_St="$_TmpRoot/st2"
_Out="$(bash "$_Root/pull.sh" --status-file "$_St" "rsync://127.0.0.1:1/x/y" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Quelle nicht erreichbar: Exit 1 (voruebergehend, neu versuchen)"
t_assert_eq "" "$(sval "$_St" result)" "kein Urteil bei Abbruch"
t_assert_contains "$(sval "$_St" message)" "nicht erreichbar" "message nennt den Abbruchgrund"
t_assert_eq "preflight" "$(sval "$_St" phase)" "Phase bleibt, wo es abbrach"

# ---- FAIL-Urteil ----------------------------------------------------------------
# Am Ziel liegt eine Datei, die es in der Quelle nicht gibt: Dateizahl weicht ab.
_Z="$_TmpRoot/z3"
mkdir -p "$_Z/NAME"
echo fremd > "$_Z/NAME/fremd.txt"
_St="$_TmpRoot/st3"
_Out="$(bash "$_Root/pull.sh" --jobs 2 --status-file "$_St" "$D_Url/A/B/NAME" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "FAIL-Urteil: Exit 1"
t_assert_eq "FAIL" "$(sval "$_St" result)" "result=FAIL"
t_assert_eq "done" "$(sval "$_St" phase)" "Endphase done auch bei FAIL"

t_summary
