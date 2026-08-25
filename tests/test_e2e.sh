#!/usr/bin/env bash
# Ende-zu-Ende-Test: der EINZIGE Test, der das echte main() ueber die ganze
# Kette gegen einen echten Daemon fahren laesst - Zerlegung, Chunks,
# Auto-Messung, parallele Uebertragung, Sweep, Verify, Bericht.
#
# Drei Entscheidungen, die diesen Test von den elf Unit-Tests unterscheiden:
#
# 1) Geprueft werden DATEIEN UND INHALTE, nicht Exit-Codes. In diesem Projekt
#    sind mehrfach Exit-Codes aufgetreten, die Erfolg meldeten, waehrend nichts
#    uebertragen war (der schlimmste: rc 0 bei null bewegten Dateien). Das
#    tragende Kriterium ist deshalb "diff -r Quelle Ziel ist leer" - das faengt
#    zusaetzlich Inhaltsfehler, die der Standard-Verify (Groesse und Zeit)
#    strukturell nicht sehen kann.
# 2) Der PARALLELE Weg wird BEHAUPTET UND GEPRUEFT, nicht angenommen. Faellt die
#    Aufrufform still auf einen Strom zurueck, testet dieser Test genau das
#    nicht mehr, was am ehesten bricht. Also: "parallele Phase:" muss im Log
#    stehen, "EINSTROEMIG" darf nicht.
# 3) Der erste Lauf benutzt die DOKUMENTIERTE Aufrufform - ohne --jobs, also
#    mit Auto-Messung. Genau die tippt ein Anwender ab, der dem README folgt;
#    ein Test, der nur --jobs faehrt, laesst die Messung ungeprueft.
#
# ANNAHME: ein daemon-faehiges rsync (Homebrew, GNU 3.x) ist vorhanden. Apples
# openrsync kann kein --daemon; dann wird geskippt. WAS SIE BRICHT: nichts -
# aber ein Lauf mit SKIP hier ist "nicht getestet", nicht "bestanden".
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync - der komplette E2E-Nachweis entfaellt (nicht getestet, nicht bestanden)"
    t_summary
fi

_Src="$(mktemp -d)"
_Dst="$(mktemp -d)"
_Dst2="$(mktemp -d)"
trap 'd_stop; rm -rf "$_Src" "$_Dst" "$_Dst2"' EXIT

# Prueft, dass eine Zeichenkette NICHT vorkommt. Bewusst hier und nicht in
# testlib.sh: dieser Test braucht sie, die anderen zehn nicht, und eine
# Erweiterung des gemeinsamen Harness gehoert nicht in diesen Task.
e_assert_absent() {
    local _Haystack="$1" _Needle="$2" _Label="$3" _Found=nein
    case "$_Haystack" in
        *"$_Needle"*) _Found=ja ;;
    esac
    t_assert_eq "nein" "$_Found" "$_Label"
}

# ---- Baum: Fall A und Fall B in einem, plus die Fallen aus Spec 2.6 ---------
# Fall A (BRIEFE): viele Ordner auf Ebene 1 - der Grund fuer Work-Stealing.
# Fall B (SonoGDT): GENAU EIN Eintrag auf Ebene 1 - der Grund, warum eine feste
# Aufteilungstiefe nicht funktioniert.
# Dazu die drei Dinge, die eine Zerlegung nach Verzeichnissen strukturell
# auslaesst oder verfaelscht: eine Datei DIREKT im aufgeteilten Ordner, ein
# LEERES Verzeichnis, und eine verstellte Verzeichnis-mtime.
mkdir -p "$_Src/Daten/BRIEFE" "$_Src/Daten/SonoGDT/Bildarchiv" "$_Src/Daten/leer"
_I=1
while [ "$_I" -le 30 ]; do
    mkdir -p "$_Src/Daten/BRIEFE/$_I"
    echo "brief $_I" > "$_Src/Daten/BRIEFE/$_I/$_I AC.DOC"
    mkdir -p "$_Src/Daten/SonoGDT/Bildarchiv/patient$_I/20260616"
    echo "bild $_I" > "$_Src/Daten/SonoGDT/Bildarchiv/patient$_I/20260616/b_$_I.jpg"
    _I=$((_I + 1))
done
echo direkt > "$_Src/Daten/SonoGDT/Bildarchiv/direkt.txt"
printf 'umlaut\n' > "$_Src/Daten/BRIEFE/Größe & Maß.DOC"
touch -t 202001011200 "$_Src/Daten/SonoGDT/Bildarchiv" "$_Src/Daten/leer"

# d_start kann fehlschlagen (alle zehn Kandidatenports belegt). Ohne diese
# Pruefung bliebe $D_Url LEER, die Quelle waere "/Daten", und pull.sh lehnte
# jeden Aufruf mit "Quelle muss mit rsync:// beginnen" ab - eine Wand aus FAILs,
# die wie ein Defekt in pull.sh aussieht und keiner ist.
if ! d_start "$_Src"; then
    t_skip "Daemon nicht startbar (kein freier Port?) - E2E entfaellt"
    t_summary
fi

# ---- Lauf 1: die DOKUMENTIERTE Aufrufform, ohne --jobs ----------------------
_Out="$(bash "$_Root/pull.sh" "$D_Url/Daten" "$_Dst" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "dokumentierte Aufrufform (ohne --jobs) endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Bericht meldet PASS"
t_assert_contains "$_Out" "parallele Phase:" "die parallele Phase lief wirklich"
e_assert_absent "$_Out" "EINSTROEMIG" "kein stiller Rueckfall auf einen Strom"
t_assert_contains "$_Out" "gewaehlte Parallelitaet" "die Auto-Messung lief (kein festes --jobs)"
t_assert_contains "$_Out" "remote 62 / lokal 62" "Dateizahl-Vergleich hat beide Seiten wirklich gezaehlt"
# Mit dem Komma davor, nicht als blosses "0 fehlgeschlagen": letzteres steckt
# als Teilkette auch in "10 fehlgeschlagen".
t_assert_contains "$_Out" ", 0 fehlgeschlagen" "kein Chunk ist fehlgeschlagen"
# Die Chunk-Buchfuehrung des Berichts wird gegen sich selbst geprueft: gleich
# viele Ergebniszeilen wie Chunks, und mehr als einer. Die absolute Zahl steht
# hier bewusst NICHT (sie haengt an _PMax und _ChunkMax und wuerde bei jeder
# Feinjustierung brechen) - geprueft wird die Aussage, nicht der Messwert.
_ChunkCnt="$(printf '%s\n' "$_Out" | sed -n 's/^ Chunks  *: \([0-9][0-9]*\) laut Liste.*/\1/p')"
_ResCnt="$(printf '%s\n' "$_Out" | sed -n 's/^ Chunks  *: [0-9][0-9]* laut Liste, \([0-9][0-9]*\) Ergebniszeile.*/\1/p')"
if [ -n "$_ChunkCnt" ] && [ "$_ChunkCnt" -ge 2 ]; then
    _L=ja
else
    _L=nein
fi
t_assert_eq "ja" "$_L" "der Bericht nennt mindestens zwei Chunks (es wurde wirklich zerlegt)"
t_assert_eq "$_ChunkCnt" "$_ResCnt" "jeder Chunk der Liste hat genau eine Ergebniszeile"

t_assert_eq "62" "$(find "$_Dst/Daten" -type f | wc -l | tr -d ' ')" "alle 62 Dateien angekommen"
# Das tragende Kriterium: gleiche Namen UND gleiche Inhalte im ganzen Baum.
# "Only in ..."-Zeilen deckten zugleich fehlende und ueberzaehlige Eintraege ab.
t_assert_eq "" "$(diff -r "$_Src/Daten" "$_Dst/Daten" 2>&1)" "Quelle und Ziel sind inhaltlich identisch (diff -r leer)"
[ -d "$_Dst/Daten/leer" ] && _L=ja || _L=nein
t_assert_eq "ja" "$_L" "leeres Verzeichnis existiert am Ziel"
t_assert_eq "direkt" "$(cat "$_Dst/Daten/SonoGDT/Bildarchiv/direkt.txt")" "direkte Datei im expandierten Ordner"
t_assert_eq "umlaut" "$(cat "$_Dst/Daten/BRIEFE/Größe & Maß.DOC")" "Umlaut-Datei lesbar"

# ---- Lauf 2: Wiederaufnahme, diesmal mit fester Parallelitaet ---------------
# Ein zweiter Lauf ueber einen vollstaendigen Zielbaum uebertraegt nichts mehr
# und muss trotzdem PASS melden - genau das tut ein Anwender nach einem Abbruch.
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten" "$_Dst" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "zweiter Lauf (Wiederaufnahme) endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Wiederaufnahme meldet PASS"
t_assert_contains "$_Out" "feste Parallelitaet: 4" "--jobs 4 wurde uebernommen"
t_assert_eq "" "$(diff -r "$_Src/Daten" "$_Dst/Daten" 2>&1)" "nach der Wiederaufnahme unveraendert identisch"

# ---- Lauf 3: Abbruch-Simulation --------------------------------------------
# Eine Datei und ein leeres Verzeichnis fehlen - genau das Bild nach einem harten
# Abbruch. Derselbe Aufruf muss beides zurueckholen.
rm "$_Dst/Daten/BRIEFE/1/1 AC.DOC"
rmdir "$_Dst/Daten/leer"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten" "$_Dst" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "Lauf nach simuliertem Abbruch endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Lauf nach simuliertem Abbruch meldet PASS"
t_assert_eq "brief 1" "$(cat "$_Dst/Daten/BRIEFE/1/1 AC.DOC")" "geloeschte Datei wurde wiederhergestellt"
[ -d "$_Dst/Daten/leer" ] && _L=ja || _L=nein
t_assert_eq "ja" "$_L" "geloeschtes leeres Verzeichnis wurde wiederhergestellt"
t_assert_eq "" "$(diff -r "$_Src/Daten" "$_Dst/Daten" 2>&1)" "nach der Reparatur wieder identisch"

# ---- Lauf 4: Trockenlauf uebertraegt nichts --------------------------------
# Pinnt die README-Zusage "--dry-run zeigt die Arbeitspakete, uebertraegt
# nichts" an einem LEEREN Ziel: waere sie falsch, laege hier ein Baum.
_Out="$(bash "$_Root/pull.sh" --dry-run "$D_Url/Daten" "$_Dst2" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "Trockenlauf endet mit rc 0"
t_assert_contains "$_Out" "Arbeitspakete" "Trockenlauf nennt die Arbeitspakete"
[ -e "$_Dst2/Daten" ] && _L=ja || _L=nein
t_assert_eq "nein" "$_L" "Trockenlauf hat nichts ans Ziel geschrieben"

# ---- Lauf 5: die einstroemige Aufrufform sagt sich an ----------------------
# Quelle MIT Schraegstrich am Ende: das Ziel endet dann nicht auf dem
# modul-relativen Praefix, die parallele Phase kann nicht laufen. Das ist die
# Form, mit der ein Anwender die Parallelitaet unbemerkt verliert - deshalb
# steht im README die Form ohne Schraegstrich, und deshalb wird hier geprueft,
# dass der Rueckfall wirklich ANGESAGT wird. Als Trockenlauf, weil nur die
# Ansage geprueft wird und nicht noch einmal ein voller Transfer.
_Out="$(bash "$_Root/pull.sh" --dry-run "$D_Url/Daten/" "$_Dst2" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "einstroemige Aufrufform (Trockenlauf) endet mit rc 0"
t_assert_contains "$_Out" "EINSTROEMIG" "der Rueckfall auf einen Strom wird angesagt"
t_assert_contains "$_Out" "einstroemige Aufrufform" "der Trockenlauf nennt die einstroemige Form"

# ---- Lauf 6: die Regel fuer TIEFERE Quellpfade, in beide Richtungen --------
# Die parallele Phase laeuft nur, wenn das Ziel auf dem GANZEN modul-relativen
# Pfad endet - nicht bloss auf dem letzten Pfadteil. Bei 'Daten/SonoGDT' heisst
# das: Ziel '<x>' scheitert (es entstuende '<x>/SonoGDT'), Ziel '<x>/Daten'
# geht. Das ist die Zusage im README, und sie ist genau die Stelle, an der ein
# Anwender die Parallelitaet unbemerkt verliert - deshalb hier beide Richtungen.
_Out="$(bash "$_Root/pull.sh" --dry-run "$D_Url/Daten/SonoGDT" "$_Dst2" 2>&1)"
t_assert_contains "$_Out" "EINSTROEMIG" "tiefer Praefix ohne gespiegeltes Ziel: einstroemig, und angesagt"
mkdir -p "$_Dst2/Daten"
_Out="$(bash "$_Root/pull.sh" --dry-run "$D_Url/Daten/SonoGDT" "$_Dst2/Daten" 2>&1)"
t_assert_contains "$_Out" "Arbeitspakete" "tiefer Praefix mit gespiegeltem Ziel: es wird zerlegt"
e_assert_absent "$_Out" "EINSTROEMIG" "tiefer Praefix mit gespiegeltem Ziel: kein Rueckfall"

t_summary
