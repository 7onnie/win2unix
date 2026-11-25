#!/usr/bin/env bash
# Issue #5: die Zerlegung muss dieselben Ausschluesse anwenden wie der Pull.
# Laeuft ohne rsync-Daemon (Attrappe tests/lib/fake_rsync_list.sh), also auch
# dort, wo die Daemon-Tests skippen.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Rechte-Test (chmod 000) ist wirkungslos"
    t_summary
fi

_Src="$(mktemp -d)"
_TmpDir="$(mktemp -d)"
trap 'chmod -R u+rwx "$_Src" 2>/dev/null; rm -rf "$_Src" "$_TmpDir"' EXIT

_Fake="$_Here/lib/fake_rsync_list.sh"
_RsyncBin="$_Fake"
FAKE_RSYNC_LOG="$_TmpDir/rsync.log"
export FAKE_RSYNC_LOG

# Kleine Quellstruktur: unter der Schwelle, die Zerlegung steigt also in jeden
# Ordner ab - auch in den ausgeschlossenen, unlesbaren Altbestand.
mkdir -p "$_Src/lesbar" "$_Src/zweit" "$_Src/Altbestand/tief"
echo a > "$_Src/lesbar/a.txt"
echo b > "$_Src/lesbar/b.txt"
echo c > "$_Src/zweit/c.txt"
echo t > "$_Src/top.txt"
echo x > "$_Src/Altbestand/tief/x.txt"
chmod 000 "$_Src/Altbestand"

_Reset() { : > "$FAKE_RSYNC_LOG"; rm -f "$_TmpDir"/work*; }

# --- 1) Reproduktion: ausgeschlossener, unlesbarer Ordner -------------------
printf 'Altbestand\n' > "$_TmpDir/ex1.txt"
_Reset
_ExcludeFrom="$_TmpDir/ex1.txt"
_Rc=0
_Err="$(w2u_decompose "$_Src" 32 "$_TmpDir/work1" 2>&1)" || _Rc=$?
t_assert_eq "0" "$_Rc" "ausgeschlossener unlesbarer Ordner bricht die Zerlegung NICHT ab"
_Perm=0
case "$_Err" in *"Permission denied"*) _Perm=1 ;; esac
t_assert_eq "0" "$_Perm" "keine Rechte-Fehlermeldung aus der Zerlegung"
_Work="$(cat "$_TmpDir/work1" 2>/dev/null)"
t_assert_contains "$_Work" "lesbar/a.txt" "lesbare Dateien stehen in der Arbeitsliste"
t_assert_contains "$_Work" "zweit/c.txt" "auch der zweite lesbare Ordner"
t_assert_contains "$_Work" "top.txt" "Datei in der Wurzel"
t_assert_eq "0" "$(grep -c 'Altbestand' "$_TmpDir/work1" || true)" "ausgeschlossener Ordner wird nicht gezaehlt (nicht in der Arbeitsliste)"
t_assert_eq "0" "$(grep -c 'Altbestand' "$FAKE_RSYNC_LOG" || true)" "ausgeschlossener Ordner wird nie betreten (kein Listing dafuer)"

# --- 2) Gegenprobe: NICHT ausgeschlossener unlesbarer Ordner scheitert laut --
printf 'ganz-anderer-name\n' > "$_TmpDir/ex2.txt"
_Reset
_ExcludeFrom="$_TmpDir/ex2.txt"
_Rc=0
_Err="$(w2u_decompose "$_Src" 32 "$_TmpDir/work2" 2>&1)" || _Rc=$?
t_assert_eq "1" "$_Rc" "unlesbarer, NICHT ausgeschlossener Ordner beendet die Zerlegung hart"
t_assert_contains "$_Err" "ABBRUCH" "der Abbruch wird gemeldet"
t_assert_contains "$_Err" "Permission denied" "mit der rsync-Diagnose"
t_assert_eq "0" "$(grep -c '^Altbestand$' "$_TmpDir/work2" 2>/dev/null || true)" "der unlesbare Ordner wird nicht als vermeintlich leeres Paket verbucht"

# Ohne jede Ausschlussdatei bleibt es beim lauten Scheitern.
_Reset
_ExcludeFrom=""
_Rc=0
_Err="$(w2u_decompose "$_Src" 32 "$_TmpDir/work2b" 2>&1)" || _Rc=$?
t_assert_eq "1" "$_Rc" "ohne Ausschlussdatei: unlesbarer Ordner scheitert weiterhin laut"

# --- 3) Verankertes Muster darf auf tieferer Ebene nichts Falsches loeschen --
# "/Bild" meint die Wurzel des Transfers. In einem Listing von zweit/ waere
# das gelistete Verzeichnis selbst die Wurzel, und zweit/Bild verschwaende zu
# Unrecht aus der Arbeitsliste (Datenverlust). Dort wird deshalb nicht gefiltert.
chmod 755 "$_Src/Altbestand"
rm -rf "$_Src/Altbestand"
mkdir -p "$_Src/Bild" "$_Src/zweit/Bild"
echo y > "$_Src/Bild/y.txt"
echo f > "$_Src/zweit/Bild/f.txt"
printf '/Bild\n' > "$_TmpDir/ex3.txt"
_Reset
_ExcludeFrom="$_TmpDir/ex3.txt"
_Rc=0
_Err="$(w2u_decompose "$_Src" 32 "$_TmpDir/work3" 2>&1)" || _Rc=$?
t_assert_eq "0" "$_Rc" "verankertes Muster: Zerlegung laeuft durch"
t_assert_eq "0" "$(grep -c '^Bild' "$_TmpDir/work3" || true)" "verankert ausgeschlossenes Bild in der Wurzel ist nicht in der Liste"
t_assert_contains "$(cat "$_TmpDir/work3")" "zweit/Bild/f.txt" "zweit/Bild bleibt erhalten (kein stiller Verlust durch falsch bezogenen Anker)"

t_summary
