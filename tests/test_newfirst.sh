#!/usr/bin/env bash
# --neu-zuerst TAGE (Issue #9): Dateien, die in den letzten TAGE Tagen
# geaendert wurden, kommen vor dem Rest. Der Vorlauf hat keine Beweiskraft -
# Vollstaendigkeit belegen weiter Chunks, Sweep und Verify.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

_TmpRoot="$(mktemp -d)"
export TMPDIR="$_TmpRoot"
trap 'd_stop; rm -rf "$_TmpRoot"' EXIT

# ---- Parser: Zeilen aus "rsync -r --list-only" ------------------------------
W2U_LIB_ONLY=1 . "$_Root/pull.sh"
cat > "$_TmpRoot/listing" <<'L'
drwxr-xr-x          4,096 2026/11/26 17:56:46 .
-rw-r--r--          1,144 2026/11/20 12:08:38 neu.rtf
-rwxrwxrwx            946 1902/01/01 12:10:20 102/1673AB.RTF
-rw-r--r--      1.234.567 2026/11/25 09:00:00 a b/Größe & Maß.DOC
-rw-r--r--            100 2025/01/01 00:00:00 alt/x.txt
lrwxrwxrwx              5 2026/11/25 09:00:00 link -> neu.rtf
drwxr-xr-x          4,096 2026/11/25 09:00:00 neuordner
L
w2u_parse_newfiles "2026/11/01" < "$_TmpRoot/listing" > "$_TmpRoot/sel"
t_assert_eq "neu.rtf|a b/Größe & Maß.DOC" "$(tr '\n' '|' < "$_TmpRoot/sel" | sed 's/|$//')" "nur regulaere Dateien ab Stichtag, Namen mit Leerzeichen und Umlauten"

_Out="$(bash "$_Root/pull.sh" --neu-zuerst abc "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "--neu-zuerst mit Unsinn: Exit 3"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi

# ---- Echter Lauf: neue Dateien liegen vor der normalen Phase am Ziel ----------
_Src="$_TmpRoot/src"
mkdir -p "$_Src/A/B/NAME"
_I=1
while [ "$_I" -le 10 ]; do
    mkdir -p "$_Src/A/B/NAME/alt$_I"
    echo "alt $_I" > "$_Src/A/B/NAME/alt$_I/f.txt"
    touch -t 201001011200 "$_Src/A/B/NAME/alt$_I/f.txt"
    _I=$((_I + 1))
done
mkdir -p "$_Src/A/B/NAME/alt3/heute"
echo "neu" > "$_Src/A/B/NAME/alt3/heute/neu.txt"
echo "neu2" > "$_Src/A/B/NAME/neu2.txt"
if ! d_start "$_Src"; then
    t_skip "Daemon nicht startbar"
    t_summary
fi

_Probe="$_TmpRoot/probe.sh"
cat > "$_Probe" <<'PROBE'
set -uo pipefail
_Pull="$1"; shift
_State="$1"; shift
W2U_LIB_ONLY=1 . "$_Pull"
eval "_orig_run_all() $(declare -f w2u_run_all | tail -n +2)"
w2u_run_all() {
    {
        _W="${_WorkRoot:-$_DstRoot}"
        printf 'VOR_NEU=%s\n' "$(cat "$_W/alt3/heute/neu.txt" 2>/dev/null)"
        printf 'VOR_NEU2=%s\n' "$(cat "$_W/neu2.txt" 2>/dev/null)"
        printf 'VOR_ALT=%s\n' "$(find "$_W" -name f.txt 2>/dev/null | wc -l | tr -d ' ')"
    } >> "$_State"
    _orig_run_all "$@"
}
main "$@"
PROBE
_Z="$_TmpRoot/z"
mkdir -p "$_Z"
_St="$_TmpRoot/state"
: > "$_St"
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_St" --jobs 2 --neu-zuerst 30 --status-file "$_TmpRoot/status" "$D_Url/A/B/NAME" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Lauf mit --neu-zuerst: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Lauf mit --neu-zuerst: PASS"
t_assert_eq "neu" "$(sed -n 's/^VOR_NEU=//p' "$_St")" "neue Datei (tief) liegt VOR der normalen Phase am Ziel"
t_assert_eq "neu2" "$(sed -n 's/^VOR_NEU2=//p' "$_St")" "neue Datei (oben) liegt VOR der normalen Phase am Ziel"
t_assert_eq "0" "$(sed -n 's/^VOR_ALT=//p' "$_St")" "alte Dateien kamen NICHT im Vorlauf"
t_assert_eq "" "$(diff -r "$_Src/A/B/NAME" "$_Z/NAME" 2>&1)" "am Ende inhaltlich identisch"
t_assert_contains "$_Out" "neue Dateien zuerst" "der Vorlauf wird angesagt"
t_assert_contains "$_Out" ", 0 fehlgeschlagen" "Chunk-Buchfuehrung unveraendert"
t_assert_eq "2" "$(sed -n 's/^new_total=//p' "$_TmpRoot/status")" "Status: new_total = Zahl neuer Dateien"

t_summary
