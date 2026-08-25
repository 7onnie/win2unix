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
_Dst3="$(mktemp -d)"
_Dst4="$(mktemp -d)"
_Dst5="$(mktemp -d)"
# "chmod -R u+w" vor dem Loeschen: zwei Faelle unten setzen einen Vorfahren
# absichtlich auf nur-lesen, und ein "rm -rf" kaeme dort nicht durch.
trap 'd_stop; chmod -R u+w "$_Dst4" "$_Dst5" 2>/dev/null; rm -rf "$_Src" "$_Dst" "$_Dst2" "$_Dst3" "$_Dst4" "$_Dst5"' EXIT

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

# ---- Lauf 3b: Wiederaufnahme nach einem HARTEN Abbruch (Spec 9.4, Test 4) ---
# Der Zustand, den ein "pkill -9" auf den Empfaenger hinterlaesst, wurde an
# einem echten Daemon nachgemessen: rsyncs Temp-Datei ".<name>.XXXXXX" bleibt im
# Ziel liegen (bei einem gewoehnlichen TERM wird sie umbenannt, bei -9 nicht).
# Genau dieser Zustand wird hier hergestellt - nicht der Kill selbst: der
# braeuchte ein Zeitfenster im Transfer, und ein Test, der manchmal nicht
# zuschlaegt, ist kein Test.
#
# Der Fehler, den dieser Lauf pinnt: der naechste, VOLLSTAENDIGE Lauf zaehlte
# die Waise als lokale Datei ohne entferntes Gegenstueck und meldete dauerhaft
# "ABWEICHUNG in der Dateizahl" - bei jeder Wiederholung, mit einer nackten
# Zahl. Wiederaufnahme ist aber eine harte Zusage (Spec 1.3), und ein FAIL, das
# niemand mehr wegbekommt, ist genau das Signal, dem danach keiner mehr glaubt.
printf 'halbe datei\n' > "$_Dst/Daten/BRIEFE/1/.1 AC.DOC.jccefG"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten" "$_Dst" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "Lauf ueber eine liegengebliebene rsync-Temp-Datei endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "und meldet PASS - die Waise ist kein Grund fuer ein FAIL"
t_assert_contains "$_Out" "rsync-Temp-Datei" "der Bericht nennt die Ausnahme, statt sie stillschweigend zu nehmen"
t_assert_contains "$_Out" "BRIEFE/1/.1 AC.DOC.jccefG" "und die Waise mit Namen - eine nackte Zahl waere als Diagnose nutzlos"
rm -f "$_Dst/Daten/BRIEFE/1/.1 AC.DOC.jccefG"
t_assert_eq "" "$(diff -r "$_Src/Daten" "$_Dst/Daten" 2>&1)" "nach dem Entfernen der Waise wieder identisch"

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
#
# Die NEGATIVE Richtung genuegt als Trockenlauf: geprueft wird die Ansage.
_Out="$(bash "$_Root/pull.sh" --dry-run "$D_Url/Daten/SonoGDT" "$_Dst2" 2>&1)"
t_assert_contains "$_Out" "EINSTROEMIG" "tiefer Praefix ohne gespiegeltes Ziel: einstroemig, und angesagt"

# Die POSITIVE Richtung darf KEIN Trockenlauf sein (Review-Fund): der Trockenlauf
# steigt vor der Praefix-Umschreibung und vor w2u_chunk/w2u_run_all aus. Ein
# falsch berechnetes, aber existierendes und beschreibbares _ParDst erfuellte
# alle Ansage-Asserts - die Chunks schrieben an die falsche Wurzel, meldeten rc
# 0, und der Sweep lieferte den richtigen Baum nach. Genau die Klasse "parallele
# Phase wirkungslos, Lauf meldet Erfolg", gegen die dieser Test existiert. Also
# echt uebertragen, und zwar in ein EIGENES Ziel, damit die Buchfuehrung dieses
# Laufs fuer sich steht.
#
# Das Zielverzeichnis-Argument muss existieren - w2u_preflight bricht sonst mit
# "Zielverzeichnis existiert nicht" ab (nachgemessen). Nur die Ebenen UNTERHALB
# legt pull.sh selbst an.
mkdir -p "$_Dst3/Daten"
_Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten/SonoGDT" "$_Dst3/Daten" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "tiefer Praefix mit gespiegeltem Ziel: echter Lauf endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "tiefer Praefix: echter Lauf meldet PASS"
t_assert_contains "$_Out" "parallele Phase:" "tiefer Praefix: die parallele Phase lief wirklich"
e_assert_absent "$_Out" "EINSTROEMIG" "tiefer Praefix mit gespiegeltem Ziel: kein Rueckfall"
t_assert_contains "$_Out" ", 0 fehlgeschlagen" "tiefer Praefix: kein Chunk fehlgeschlagen"
t_assert_eq "" "$(diff -r "$_Src/Daten/SonoGDT" "$_Dst3/Daten/SonoGDT" 2>&1)" "tiefer Praefix: Unterbaum inhaltlich identisch"
# Der entscheidende Assert gegen ein falsch berechnetes _ParDst: unterhalb von
# $_Dst3 darf NICHTS ausserhalb des erwarteten Unterbaums liegen. Schrieben die
# Worker an die falsche Wurzel und der Sweep raeumte hinterher auf, waeren beide
# Zahlen verschieden - waehrend diff -r trotzdem sauber waere.
t_assert_eq "31" "$(find "$_Dst3/Daten/SonoGDT" -type f | wc -l | tr -d ' ')" "tiefer Praefix: 31 Dateien im erwarteten Unterbaum"
t_assert_eq "31" "$(find "$_Dst3" -type f | wc -l | tr -d ' ')" "tiefer Praefix: KEINE Datei ausserhalb des erwarteten Unterbaums"

# ---- Lauf 7: nicht beschreibbarer VORFAHRE, beschreibbares Ziel -------------
# Die Worker schreiben nach "_ParDst/<praefix>", und das IST das
# Zielverzeichnis. Auf den VORFAHREN _ParDst brauchen sie kein Schreibrecht,
# solange die Praefix-Kette schon existiert. Der Preflight pruefte trotzdem den
# Vorfahren und lehnte damit einen Lauf ab, der funktioniert haette - mit
# --no-verify nicht als Warnung, sondern per Abbruch (w2u_einstroemig stirbt
# dort, weil ohne Zerlegung keine bindende Beweisschicht bleibt).
#
# Aufbau: Quelle 'Daten/SonoGDT' (zweisegmentiger Praefix, also _ParDst = die
# Wurzel des Zielbaums und NICHT das genannte Zielverzeichnis - nur so ist der
# Fall ueberhaupt erreichbar; bei einsegmentigem Praefix faengt ihn die
# "-w $_DstDir"-Pruefung schon vorher ab). Vorfahre nur-lesen, Ziel schreibbar.
#
# Als root wirkungslos (Rechte werden ignoriert) - dieselbe Ausnahme wie in
# tests/test_chunk.sh.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - ein nicht beschreibbarer Vorfahre ist wirkungslos"
else
    mkdir -p "$_Dst4/Daten/SonoGDT"
    chmod 555 "$_Dst4"
    _Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten/SonoGDT" "$_Dst4/Daten" 2>&1)"
    _Rc=$?
    chmod 755 "$_Dst4"
    t_assert_rc 0 "$_Rc" "nur-lesbarer Vorfahre, beschreibbares Ziel: Lauf endet mit rc 0"
    t_assert_contains "$_Out" "ERGEBNIS: PASS" "und meldet PASS"
    t_assert_contains "$_Out" "parallele Phase:" "die parallele Phase laeuft wirklich - der Vorfahre ist nicht ihr Schreibziel"
    e_assert_absent "$_Out" "EINSTROEMIG" "kein Rueckfall auf einen Strom wegen eines Vorfahren, in den niemand schreibt"
    t_assert_eq "31" "$(find "$_Dst4/Daten/SonoGDT" -type f | wc -l | tr -d ' ')" "alle 31 Dateien im Unterbaum angekommen"

    # Dieselbe Aufrufform mit --no-verify: vorher war das ein ABBRUCH im
    # Preflight, nicht bloss eine Warnung. Ein Lauf, der parallel geht, darf
    # daran nicht sterben.
    mkdir -p "$_Dst5/Daten/SonoGDT"
    chmod 555 "$_Dst5"
    _Out="$(bash "$_Root/pull.sh" --no-verify --jobs 4 "$D_Url/Daten/SonoGDT" "$_Dst5/Daten" 2>&1)"
    _Rc=$?
    chmod 755 "$_Dst5"
    t_assert_rc 0 "$_Rc" "dieselbe Form mit --no-verify laeuft durch (vorher: Abbruch im Preflight)"
    t_assert_contains "$_Out" "parallele Phase:" "--no-verify: die parallele Phase laeuft"
    t_assert_eq "31" "$(find "$_Dst5/Daten/SonoGDT" -type f | wc -l | tr -d ' ')" "--no-verify: alle 31 Dateien angekommen"

    # Gegenprobe, damit die gelockerte Pruefung nicht einfach alles durchlaesst:
    # ist das ZIEL SELBST nicht beschreibbar, muss der Rueckfall weiterhin
    # kommen - dort schreiben die Worker wirklich hinein.
    mkdir -p "$_Dst4/nurlesen/Daten/SonoGDT"
    chmod 555 "$_Dst4/nurlesen/Daten/SonoGDT"
    _Out="$(bash "$_Root/pull.sh" --jobs 4 "$D_Url/Daten/SonoGDT" "$_Dst4/nurlesen/Daten" 2>&1)"
    chmod 755 "$_Dst4/nurlesen/Daten/SonoGDT"
    t_assert_contains "$_Out" "EINSTROEMIG" "nicht beschreibbares ZIEL: der Rueckfall kommt weiterhin - und wird angesagt"
fi

t_summary
