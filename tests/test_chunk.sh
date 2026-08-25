#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

_T="$(mktemp -d)"
trap 'rm -rf "$_T"' EXIT

_mk() { _I=1; : > "$1"; while [ "$_I" -le "$2" ]; do printf 'eintrag %d\n' "$_I" >> "$1"; _I=$((_I + 1)); done; }

# Identitaetsprobe (Review nach Task 5, ersetzt eine reine Summenprobe): eine
# Zeile doppelt in zwei Chunks und eine an anderer Stelle verlorene Zeile
# wuerden sich in der reinen Zeilenzahl gegenseitig aufheben - eine Summe
# allein kann das nicht sehen (dieselbe Blindheit hat in Task 4 die
# Ueberdeckungspruefung ausgehebelt, dort dokumentiert). Konkatenation aller
# gelisteten Chunks, sortiert, gegen die sortierte Arbeitsliste verglichen
# deckt Verlust, Duplikat UND Inhaltsabweichung ab - auch fuer Zeilen mit
# Leerzeichen, TAB oder Umlaut, weil "sort" sie byte-weise vergleicht statt
# sie zu interpretieren.
_assert_identity() {
    local _Work="$1" _List="$2" _Label="$3" _Cat _C
    _Cat="$(mktemp)"
    while IFS= read -r _C; do
        cat "$_C"
    done < "$_List" > "$_Cat"
    t_assert_eq "$(sort "$_Work")" "$(sort "$_Cat")" "$_Label"
    rm -f "$_Cat"
}

# Fall A: 308 Pakete, P_max 8 -> 4*8=32 Divisor -> ceil(308/32)=10 je Chunk -> 31 Chunks
_mk "$_T/a.work" 308
mkdir -p "$_T/ca"
w2u_chunk "$_T/a.work" "$_T/ca" 8 "$_T/a.list"
t_assert_eq "31" "$(grep -c . "$_T/a.list")" "Fall A: 31 Chunks"
t_assert_eq "10" "$(wc -l < "$(head -1 "$_T/a.list")" | tr -d ' ')" "Fall A: 10 Eintraege im ersten Chunk"

# Fall B: 13193 Pakete -> ceil(13193/32)=413 > _ChunkMax -> auf 100 gedeckelt -> 132 Chunks
_mk "$_T/b.work" 13193
mkdir -p "$_T/cb"
w2u_chunk "$_T/b.work" "$_T/cb" 8 "$_T/b.list"
t_assert_eq "132" "$(grep -c . "$_T/b.list")" "Fall B: 132 Chunks, Obergrenze greift"
_assert_identity "$_T/b.work" "$_T/b.list" "Fall B: Chunks sind identisch mit der Arbeitsliste (Inhalt, keine Duplikate/Verluste)"

# Randfall: ein einziges Paket
_mk "$_T/c.work" 1
mkdir -p "$_T/cc"
w2u_chunk "$_T/c.work" "$_T/cc" 8 "$_T/c.list"
t_assert_eq "1" "$(grep -c . "$_T/c.list")" "ein Paket ergibt einen Chunk"

# Fall D: reproduziert den split-Suffix-Bug (Review nach Task 5). BSD split
# vergibt ohne "-a" nur 2 Buchstaben Suffix (aa..zz, 676 Dateien) und bricht
# danach mit "too many files" (rc 65) ab - dabei bleiben die bereits
# geschriebenen 676 Chunks stehen, ls sammelt sie trotzdem ein, und der Rest
# der Arbeitsliste ginge STILL verloren. Nachgemessen: bei 700 Arbeitspaketen
# und Chunkgroesse 1 fehlten vor dem Fix 24 Pakete. _ChunkMax wird hier auf 1
# gezwungen, um dieselbe Grenze mit 700 statt real moeglichen 67600+ Paketen
# in Sekunden statt Minuten zu treffen.
_SavedChunkMax="$_ChunkMax"
_ChunkMax=1
_mk "$_T/d.work" 700
mkdir -p "$_T/cd"
w2u_chunk "$_T/d.work" "$_T/cd" 8 "$_T/d.list"
_ChunkMax="$_SavedChunkMax"
t_assert_eq "700" "$(grep -c . "$_T/d.list")" "Fall D: alle 700 Chunks entstehen trotz BSD-split-Suffixgrenze (vorher: nur 676)"
_assert_identity "$_T/d.work" "$_T/d.list" "Fall D: kein Arbeitspaket verloren trotz Suffixgrenze"

# Fall E: leere Arbeitsliste bricht hart ab statt eine leere Chunkliste zu
# liefern. w2u_die beendet mit exit - das Kommando steht deshalb in einer
# Command-Substitution (eigene Subshell), sonst wuerde es den Testlauf selbst
# beenden.
: > "$_T/e.work"
mkdir -p "$_T/ce"
_Rc=0
_Err="$(w2u_chunk "$_T/e.work" "$_T/ce" 8 "$_T/e.list" 2>&1)" || _Rc=$?
t_assert_rc "1" "$_Rc" "Fall E: leere Arbeitsliste bricht mit rc 1 ab"
t_assert_contains "$_Err" "keine Arbeitspakete" "Fall E: Fehlermeldung nennt die Ursache"

# Fall F: "rm -f" vor dem Splitten raeumt Chunks aus einem VORHERIGEN Lauf im
# selben Verzeichnis weg. main() kann w2u_chunk kuenftig nach einem
# abgebrochenen vorherigen Lauf erneut mit demselben Chunk-Verzeichnis
# aufrufen - bleiben Altlasten liegen, bekommen Worker zusaetzlich
# Arbeitspakete aus dem alten, groesseren Lauf.
_mk "$_T/f1.work" 20
mkdir -p "$_T/cf"
w2u_chunk "$_T/f1.work" "$_T/cf" 8 "$_T/f1.list"

_mk "$_T/f2.work" 3
w2u_chunk "$_T/f2.work" "$_T/cf" 8 "$_T/f2.list"
t_assert_eq "3" "$(grep -c . "$_T/f2.list")" "Fall F: zweiter Lauf im selben Verzeichnis zaehlt nur seine eigenen 3 Chunks"
_assert_identity "$_T/f2.work" "$_T/f2.list" "Fall F: zweiter Lauf enthaelt nur seine eigenen Pakete, keine Altlasten aus dem ersten"

# Fall G: Leerzeichen, TAB und Umlaut im Pfad ueberleben den Chunk-Schnitt
# unveraendert. split ist zeilenorientiert und byte-transparent, aber ohne
# eine committete Fixture dafuer merkt kein Test eine Regression hier.
_Tab="$(printf '\t')"
{
    printf 'ordner mit leerzeichen/datei eins.txt\n'
    printf 'ordner%smit%stab/datei zwei.txt\n' "$_Tab" "$_Tab"
    printf 'ünter ordner ä/tief ö.txt\n'
} > "$_T/g.work"
mkdir -p "$_T/cg"
w2u_chunk "$_T/g.work" "$_T/cg" 8 "$_T/g.list"
t_assert_eq "3" "$(grep -c . "$_T/g.list")" "Fall G: 3 Pakete mit Sonderzeichen -> 3 Chunks"
_assert_identity "$_T/g.work" "$_T/g.list" "Fall G: Leerzeichen, TAB und Umlaut ueberleben den Chunk-Schnitt unveraendert"

# Fall H: unlesbare Arbeitsdatei muss laut abbrechen statt eine unerwartete
# Zaehlung still zu verarbeiten (Re-Review nach Task 5). Deckt den rc>1-Zweig
# von "grep -c . || [ $? -eq 1 ] || w2u_die" ab - Praezedenz und Rechte-Messung
# fuer das chmod-000-Muster in tests/test_decompose.sh:284-299 (dort
# nachgemessen: unlesbare Datei -> rc 2 bei BSD-grep UND ugrep, kein Treffer
# -> rc 1; beide stimmen fuer diesen Fall ueberein). Als root wirkungslos
# (Rechte werden ignoriert), deshalb dort skippen.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - unlesbare Arbeitsdatei ist wirkungslos"
else
    _mk "$_T/h.work" 5
    chmod 000 "$_T/h.work"
    mkdir -p "$_T/ch"
    _Rc=0
    _Err="$(w2u_chunk "$_T/h.work" "$_T/ch" 8 "$_T/h.list" 2>&1)" || _Rc=$?
    t_assert_eq "1" "$_Rc" "Fall H: unlesbare Arbeitsdatei bricht hart ab (rc 1 von w2u_die)"
    t_assert_contains "$_Err" "nicht lesbar" "Fall H: Fehlermeldung nennt die Ursache"
    chmod 644 "$_T/h.work"
fi

t_summary
