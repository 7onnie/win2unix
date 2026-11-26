#!/usr/bin/env bash
# Issue #7: tiefe Quelle -> <ziel>/NAME, parallel ueber einen Zwischenordner.
# Echte Laeufe gegen einen echten Daemon. Geprueft werden Dateien und Inhalte,
# nicht nur Exit-Codes - dazu, dass NICHTS ausserhalb von <ziel>/NAME liegen
# bleibt (kein Zwischenordner, keine Sperre, keine doppelten Daten).
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync - Zwischenordner-Tests entfallen (nicht getestet, nicht bestanden)"
    t_summary
fi

_TmpRoot="$(mktemp -d)"
export TMPDIR="$_TmpRoot"
_Src="$_TmpRoot/src"
trap 'd_stop; rm -rf "$_TmpRoot"' EXIT

s_absent() {
    local _Hay="$1" _Needle="$2" _Label="$3" _Found=nein
    case "$_Hay" in
        *"$_Needle"*) _Found=ja ;;
    esac
    t_assert_eq "nein" "$_Found" "$_Label"
}

# Nichts ausser <z>/BRIEFE darf unter <z> liegen.
s_clean() {
    local _Z="$1" _Label="$2" _Rest
    _Rest="$(cd "$_Z" && ls -A | grep -v '^BRIEFE$' | tr '\n' ' ')"
    t_assert_eq "" "$_Rest" "$_Label: unter dem Ziel liegt nur BRIEFE (kein Zwischenordner, keine Sperre)"
}

# Quelle: der Fall aus dem Ernstfall, drei Ebenen tief.
mkdir -p "$_Src/Konv/Albis/AlbisWin/BRIEFE" "$_Src/Konv/Albis/AlbisWin/leer"
_I=1
while [ "$_I" -le 20 ]; do
    mkdir -p "$_Src/Konv/Albis/AlbisWin/BRIEFE/$_I"
    echo "brief $_I" > "$_Src/Konv/Albis/AlbisWin/BRIEFE/$_I/$_I AC.DOC"
    _I=$((_I + 1))
done
echo direkt > "$_Src/Konv/Albis/AlbisWin/BRIEFE/direkt.txt"
_SrcB="$_Src/Konv/Albis/AlbisWin/BRIEFE"
_Url=""

if ! d_start "$_Src"; then
    t_skip "Daemon nicht startbar - Zwischenordner-Tests entfallen"
    t_summary
fi
_Url="$D_Url/Konv/Albis/AlbisWin/BRIEFE"

# ---- 1: Hauptfall ----------------------------------------------------------
_Z="$_TmpRoot/z1"
mkdir -p "$_Z"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Hauptfall: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Hauptfall: PASS"
t_assert_contains "$_Out" "parallele Phase:" "Hauptfall: die parallele Phase lief"
s_absent "$_Out" "EINSTROEMIG" "Hauptfall: kein Rueckfall auf einen Strom"
t_assert_contains "$_Out" ", 0 fehlgeschlagen" "Hauptfall: kein Chunk fehlgeschlagen"
t_assert_eq "" "$(diff -r "$_SrcB" "$_Z/BRIEFE" 2>&1)" "Hauptfall: <ziel>/BRIEFE inhaltlich identisch"
t_assert_eq "21" "$(find "$_Z" -type f | wc -l | tr -d ' ')" "Hauptfall: genau 21 Dateien unter dem Ziel - nichts doppelt"
s_clean "$_Z" "Hauptfall"

# Zweiter Lauf auf dasselbe Ziel: No-op mit PASS.
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Wiederholung: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Wiederholung: PASS"
s_clean "$_Z" "Wiederholung"

# Dasselbe mit openrsync als Client - der Vorgabe auf den Ziel-Macs.
if [ -x /usr/bin/rsync ] && /usr/bin/rsync --version 2>&1 | grep -qi openrsync; then
    _Z="$_TmpRoot/z1o"
    mkdir -p "$_Z"
    _Out="$(bash "$_Root/pull.sh" --jobs 4 --rsync /usr/bin/rsync "$_Url" "$_Z" 2>&1)"; _Rc=$?
    t_assert_rc 0 "$_Rc" "openrsync: rc 0"
    t_assert_contains "$_Out" "ERGEBNIS: PASS" "openrsync: PASS"
    t_assert_contains "$_Out" "parallele Phase:" "openrsync: parallele Phase lief"
    t_assert_eq "" "$(diff -r "$_SrcB" "$_Z/BRIEFE" 2>&1)" "openrsync: inhaltlich identisch"
    s_clean "$_Z" "openrsync"
else
    t_skip "kein openrsync unter /usr/bin/rsync"
fi

# ---- 2: Trockenlauf legt nichts an -----------------------------------------
_Z="$_TmpRoot/z2"
mkdir -p "$_Z"
_Out="$(bash "$_Root/pull.sh" --dry-run "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Trockenlauf: rc 0"
t_assert_eq "" "$(ls -A "$_Z")" "Trockenlauf: nichts angelegt, kein Zwischenordner"

# ---- 3: Aufraeumen nach Absturz --------------------------------------------
# Ein Lauf starb (kill -9) waehrend der parallelen Phase: der Bestand liegt im
# Zwischenordner, <ziel>/BRIEFE fehlt.
_Z="$_TmpRoot/z3"
_Leaf="$_Z/.w2u-stage-BRIEFE/Konv/Albis/AlbisWin/BRIEFE"
mkdir -p "$_Leaf/1" "$_Leaf/2"
cp -p "$_SrcB/1/1 AC.DOC" "$_Leaf/1/"
cp -p "$_SrcB/2/2 AC.DOC" "$_Leaf/2/"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Aufraeumen: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Aufraeumen: PASS"
t_assert_contains "$_Out" "Zwischenordner" "Aufraeumen: wird angesagt"
t_assert_eq "" "$(diff -r "$_SrcB" "$_Z/BRIEFE" 2>&1)" "Aufraeumen: inhaltlich identisch"
t_assert_eq "21" "$(find "$_Z" -type f | wc -l | tr -d ' ')" "Aufraeumen: 21 Dateien, nichts doppelt"
s_clean "$_Z" "Aufraeumen"

# Variante: <ziel>/BRIEFE existiert, ist aber LEER (z.B. von mkdir -p).
_Z="$_TmpRoot/z3b"
_Leaf="$_Z/.w2u-stage-BRIEFE/Konv/Albis/AlbisWin/BRIEFE"
mkdir -p "$_Leaf/1" "$_Z/BRIEFE"
cp -p "$_SrcB/1/1 AC.DOC" "$_Leaf/1/"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "leeres Ziel neben Zwischenordner: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "leeres Ziel neben Zwischenordner: PASS"
s_clean "$_Z" "leeres Ziel neben Zwischenordner"

# ---- 4: beide haben Inhalt -> Abbruch, nichts angefasst ---------------------
_Z="$_TmpRoot/z4"
_Leaf="$_Z/.w2u-stage-BRIEFE/Konv/Albis/AlbisWin/BRIEFE"
mkdir -p "$_Leaf" "$_Z/BRIEFE"
echo stage > "$_Leaf/a.txt"
echo ziel > "$_Z/BRIEFE/b.txt"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "beide mit Inhalt: Abbruch"
t_assert_contains "$_Out" ".w2u-stage-BRIEFE" "beide mit Inhalt: die Meldung nennt den Zwischenordner"
t_assert_eq "stage" "$(cat "$_Leaf/a.txt" 2>/dev/null)" "beide mit Inhalt: Zwischenordner unangetastet"
t_assert_eq "ziel" "$(cat "$_Z/BRIEFE/b.txt" 2>/dev/null)" "beide mit Inhalt: Ziel unangetastet"
t_assert_eq "1" "$(find "$_Z/BRIEFE" -type f | wc -l | tr -d ' ')" "beide mit Inhalt: nichts uebertragen"
[ -e "$_Z/.w2u-stage-BRIEFE.lock" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "beide mit Inhalt: die eigene Sperre ist wieder frei"

# ---- 5: Sperre -------------------------------------------------------------
_Z="$_TmpRoot/z5"
mkdir -p "$_Z/.w2u-stage-BRIEFE.lock"
echo "$$" > "$_Z/.w2u-stage-BRIEFE.lock/pid"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "lebende Sperre: Abbruch"
t_assert_contains "$_Out" "$$" "lebende Sperre: die Meldung nennt den haltenden Prozess"
t_assert_eq "$$" "$(cat "$_Z/.w2u-stage-BRIEFE.lock/pid" 2>/dev/null)" "lebende Sperre: fremde Sperre bleibt unangetastet"
[ -e "$_Z/BRIEFE" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "lebende Sperre: nichts uebertragen"

_Z="$_TmpRoot/z6"
sh -c 'exit 0' &
_DeadPid=$!
wait "$_DeadPid"
mkdir -p "$_Z/.w2u-stage-BRIEFE.lock"
echo "$_DeadPid" > "$_Z/.w2u-stage-BRIEFE.lock/pid"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "tote Sperre (kill -9): wird uebernommen, rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "tote Sperre: PASS"
s_clean "$_Z" "tote Sperre"

# ---- 5b: tote Sperre, aber Worker des toten Laufs leben noch (Review I1) ----
# kill -9 trifft nur den Hauptprozess; xargs und rsync laufen als Waisen weiter
# und schreiben in den Zwischenordner. Die Sperre darf dann NICHT uebernommen
# werden - sonst schiebt der neue Lauf den Bestand weg, waehrend die Waisen
# hineinschreiben, und am Ende liegen zwei halbe Bestaende da.
# Nachgestellt: die Sperre nennt eine tote PID und das TMP-Verzeichnis des
# toten Laufs; ein Prozess traegt dieses Verzeichnis im argv, wie es jeder
# Worker tut (--files-from=<tmp>/chunks/...).
_Z="$_TmpRoot/z8"
_Leaf="$_Z/.w2u-stage-BRIEFE/Konv/Albis/AlbisWin/BRIEFE"
mkdir -p "$_Leaf/1" "$_Z/.w2u-stage-BRIEFE.lock"
cp -p "$_SrcB/1/1 AC.DOC" "$_Leaf/1/"
sh -c 'exit 0' &
_DeadPid=$!
wait "$_DeadPid"
_OrphTmp="$_TmpRoot/win2unix.TOTERLAUF"
echo "$_DeadPid" > "$_Z/.w2u-stage-BRIEFE.lock/pid"
echo "$_OrphTmp" > "$_Z/.w2u-stage-BRIEFE.lock/tmp"
bash -c 'sleep 60; :' _ "--files-from=$_OrphTmp/chunks/c0001" &
_OrphPid=$!
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Waisen am Werk: Abbruch statt Uebernahme"
t_assert_contains "$_Out" "$_OrphPid" "Waisen am Werk: die Meldung nennt die PID des Waisen"
[ -f "$_Leaf/1/1 AC.DOC" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "Waisen am Werk: Zwischenordner unangetastet"
[ -e "$_Z/BRIEFE" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "Waisen am Werk: kein Ziel angelegt"
kill "$_OrphPid" 2>/dev/null
wait "$_OrphPid" 2>/dev/null
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "nach Ende der Waisen: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "nach Ende der Waisen: PASS"
t_assert_eq "" "$(diff -r "$_SrcB" "$_Z/BRIEFE" 2>&1)" "nach Ende der Waisen: inhaltlich identisch"
s_clean "$_Z" "nach Ende der Waisen"

# ---- 5c: <ziel>/NAME ist ein Symlink (Review I2) ---------------------------
# Umbenennen wuerde den LINK verschieben, rsync legte an seiner Stelle ein
# echtes Verzeichnis an - Daten auf der falschen Platte, Link zerstoert.
# Erwartet: kein Zwischenordner, einstroemig durch den Link, Link bleibt.
_Z="$_TmpRoot/z9"
mkdir -p "$_Z" "$_TmpRoot/woanders/BRIEFE_echt"
ln -s "$_TmpRoot/woanders/BRIEFE_echt" "$_Z/BRIEFE"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Symlink-Ziel: rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Symlink-Ziel: PASS"
t_assert_contains "$_Out" "EINSTROEMIG" "Symlink-Ziel: einstroemig, angesagt"
[ -L "$_Z/BRIEFE" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "Symlink-Ziel: der Link bleibt ein Link"
t_assert_eq "" "$(diff -r "$_SrcB" "$_TmpRoot/woanders/BRIEFE_echt" 2>&1)" "Symlink-Ziel: Daten liegen im Link-Ziel"
[ -e "$_Z/.w2u-stage-BRIEFE" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "Symlink-Ziel: kein Zwischenordner"

# ---- 5d: <ziel> selbst ist ein Symlink auf eine andere Platte (Review M1) ---
# Haeufig auf Linux: /opt/data/files -> /mnt/gross. Das Geraet muss DURCH den
# Link verglichen werden, sonst faellt jeder Lauf grundlos auf einstroemig.
_Z="$_TmpRoot/z10"
mkdir -p "$_TmpRoot/gross"
ln -s "$_TmpRoot/gross" "$_Z"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$_Url" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Ziel ist Symlink: rc 0"
t_assert_contains "$_Out" "parallele Phase:" "Ziel ist Symlink: trotzdem parallel"
s_absent "$_Out" "EINSTROEMIG" "Ziel ist Symlink: kein Rueckfall"
t_assert_eq "" "$(diff -r "$_SrcB" "$_TmpRoot/gross/BRIEFE" 2>&1)" "Ziel ist Symlink: inhaltlich identisch"

# ---- 6: Schraegstrich-Form bleibt einstroemig, ohne Zwischenordner ----------
_Z="$_TmpRoot/z7"
mkdir -p "$_Z"
_Out="$(bash "$_Root/pull.sh" "$_Url/" "$_Z" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Schraegstrich-Form: rc 0"
t_assert_contains "$_Out" "EINSTROEMIG" "Schraegstrich-Form: einstroemig, angesagt"
t_assert_eq "" "$(diff -r "$_SrcB" "$_Z" 2>&1)" "Schraegstrich-Form: Inhalt direkt im Ziel"

t_summary
