#!/usr/bin/env bash
#
# Task 8: Sweep, Verifikation, Abschlussbericht.
#
# Der wichtigste Test dieser Datei ist der NEGATIVTEST: eine Verifikation, die
# nicht nachweislich fehlschlagen kann, beweist nichts (Spec 9.5). Alles
# weitere haengt an derselben Frage - welche Mutation wuerde diese Assertion
# brechen? Ein falsches FAIL kostet einen Nachmittag, ein falsches PASS
# vernichtet die Daten: danach wird die Windows-Quelle verschrottet.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi

_Src="$(mktemp -d)"; _Dst="$(mktemp -d)"; _TmpDir="$(mktemp -d)"
trap 'd_stop; rm -rf "$_Src" "$_Dst" "$_TmpDir"' EXIT

mkdir -p "$_Src/Bildarchiv/1/tag" "$_Src/Bildarchiv/2/tag" "$_Src/leer_ordner"
echo a > "$_Src/Bildarchiv/1/tag/f1.jpg"
echo b > "$_Src/Bildarchiv/2/tag/f2.jpg"
echo direkt > "$_Src/Bildarchiv/direkt_datei.txt"
touch -t 202001011200 "$_Src/Bildarchiv" "$_Src/leer_ordner"

if ! d_start "$_Src"; then
    t_skip "rsync-Daemon konnte auf keinem der versuchten Ports binden - Test wird uebersprungen statt gegen den falschen Daemon zu laufen"
    t_summary
fi
w2u_find_rsync
_SrcUrl="$D_Url"
_DstRoot="$_Dst"
_LogDir="$_TmpDir/logs"; mkdir -p "$_LogDir"
_ResultFile="$_TmpDir/results"; : > "$_ResultFile"
_StartTs="$(date +%s)"

# ---------------------------------------------------------------------------
# NEGATIVTEST: absichtlich unvollstaendig uebertragen (Spec 9.5).
# Die Chunkliste laesst genau die zwei Faelle aus, die eine Zerlegung nach
# Verzeichnisebenen strukturell auslaesst: eine Datei, die DIREKT in einem
# aufgeteilten Verzeichnis liegt, und ein leeres Verzeichnis.
# ---------------------------------------------------------------------------
printf '%s\n' "Bildarchiv/1" "Bildarchiv/2" > "$_TmpDir/bad.chunk"
"$_RsyncBin" -rlt -W --numeric-ids --files-from="$_TmpDir/bad.chunk" "$_SrcUrl/" "$_DstRoot/" >/dev/null 2>&1

_Findings="$(w2u_verify || true)"
w2u_verify >/dev/null 2>&1; _Rc=$?
t_assert_rc 1 "$_Rc" "NEGATIVTEST: unvollstaendiger Transfer MUSS FAIL liefern"
t_assert_contains "$_Findings" "direkt_datei.txt" "Verify findet die fehlende direkte Datei"
t_assert_contains "$_Findings" "leer_ordner" "Verify findet das fehlende leere Verzeichnis"

# ---------------------------------------------------------------------------
# "Konnte nicht pruefen" ist NICHT "geprueft und gut". Stirbt der rsync des
# Verifikationslaufs (Daemon weg, Timeout, Verbindungsabbruch), ist die Ausgabe
# unter Umstaenden leer - ein Verify, der nur auf leere Ausgabe schaut, meldete
# dann PASS auf einem Vergleich, der nie stattgefunden hat.
# ---------------------------------------------------------------------------
_SaveUrl="$_SrcUrl"
_SrcUrl="rsync://127.0.0.1:1/test"
_Findings="$(w2u_verify 2>/dev/null || true)"
w2u_verify >/dev/null 2>&1; _Rc=$?
t_assert_rc 1 "$_Rc" "toter Quell-Port: Verify meldet FAIL statt 'sauber'"
t_assert_contains "$_Findings" "NICHT MOEGLICH" "der Grund steht im Klartext im Befund (nicht ermittelbar != in Ordnung)"
_SrcUrl="$_SaveUrl"

# ---------------------------------------------------------------------------
# Sweep repariert, danach muss der Verify sauber sein - inklusive der
# Verzeichnis-mtimes, die die chunkweise Uebertragung offen laesst.
# ---------------------------------------------------------------------------
w2u_sweep >/dev/null 2>&1
_Findings="$(w2u_verify || true)"
w2u_verify >/dev/null 2>&1; _Rc=$?
t_assert_rc 0 "$_Rc" "nach dem Sweep ist der Verify sauber"
t_assert_eq "" "$_Findings" "keine Restbefunde, auch keine Verzeichnis-mtimes"

# ---------------------------------------------------------------------------
# Der Filter darf NUR die mtime der Wurzel selbst schlucken. Wer daraus
# "^\.d" macht (die naheliegende Vereinfachung), wirft jeden echten
# Verzeichnisbefund mit weg - und bliebe ohne diesen Test gruen.
# ---------------------------------------------------------------------------
touch -t 200001010000 "$_DstRoot/Bildarchiv/1"
_Findings="$(w2u_verify || true)"
w2u_verify >/dev/null 2>&1; _Rc=$?
t_assert_rc 1 "$_Rc" "abweichende mtime eines UNTERverzeichnisses ist ein Befund"
t_assert_contains "$_Findings" "Bildarchiv/1" "der Befund nennt das betroffene Verzeichnis"
w2u_sweep >/dev/null 2>&1
w2u_verify >/dev/null 2>&1; _Rc=$?
t_assert_rc 0 "$_Rc" "der Sweep repariert auch diese mtime wieder"

# ---------------------------------------------------------------------------
# Zaehlung
# ---------------------------------------------------------------------------
t_assert_eq "3" "$(w2u_count_remote)" "drei regulaere Dateien remote"
t_assert_eq "3" "$(w2u_count_local)" "drei regulaere Dateien lokal"

# Das Logverzeichnis liegt per Vorgabe UNTER dem Ziel ($_DstRoot/.win2unix-logs,
# siehe main()). Wird es mitgezaehlt, ist die lokale Zahl in JEDEM produktiven
# Lauf groesser als die entfernte - ein falsches FAIL bei jedem Lauf.
_LogDir="$_DstRoot/.win2unix-logs"
mkdir -p "$_LogDir"
printf 'log\n' > "$_LogDir/chunk.aa.1.log"
t_assert_eq "3" "$(w2u_count_local)" "Logverzeichnis unter dem Ziel wird NICHT mitgezaehlt"
_SaveLogDir="$_LogDir"
_LogDir=""
t_assert_eq "4" "$(w2u_count_local)" "Gegenprobe: ohne Ausschluss waere die Logdatei mitgezaehlt worden (der Ausschluss tut also etwas)"
# "--log-dir /pfad/" kommt vom Nutzer: mit abschliessendem Schraegstrich passte
# "-path" nicht mehr, und die Logs waeren wieder in der Zahl - ein falsches FAIL
# in jedem Lauf, der die Option so schreibt.
_LogDir="$_SaveLogDir/"
t_assert_eq "3" "$(w2u_count_local)" "Logverzeichnis mit abschliessendem Schraegstrich wird ebenso ausgeschlossen"
_LogDir="$_SaveLogDir"

# Eine Zahl, die nicht ermittelt werden konnte, ist LEER - nicht 0. Eine 0 waere
# eine Zahl, mit der weiter verglichen wird (gleiches Muster wie w2u_dst_kb).
_SrcUrl="rsync://127.0.0.1:1/test"
t_assert_eq "" "$(w2u_count_remote)" "unerreichbare Quelle ergibt eine LEERE Zahl, keine 0"
_SrcUrl="$_SaveUrl"

# ---------------------------------------------------------------------------
# Bericht. Ab hier wird nur noch die Buchfuehrung geprueft; die Daten am Ziel
# sind vollstaendig und bleiben es.
# ---------------------------------------------------------------------------
# Der Massstab des Berichts wird an der Entstehungsstelle registriert. Wer die
# Zuweisung in w2u_chunk fuer ueberfluessig haelt und entfernt, bekommt einen
# Bericht ohne Vergleichsmassstab - und der meldet dann FAIL, nie PASS.
_ChunkListFile=""
printf '%s\n' "a" "b" > "$_TmpDir/work"
mkdir -p "$_TmpDir/chunks_pin"
w2u_chunk "$_TmpDir/work" "$_TmpDir/chunks_pin" 2 "$_TmpDir/chunks_pin.list" >/dev/null 2>&1
t_assert_eq "$_TmpDir/chunks_pin.list" "$_ChunkListFile" "w2u_chunk registriert die erzeugte Chunkliste als Massstab fuer den Bericht"

mkdir -p "$_TmpDir/chunks"
: > "$_TmpDir/chunks/chunk.aa"
: > "$_TmpDir/chunks/chunk.ab"
_ChunkListFile="$_TmpDir/chunks.list"
printf '%s\n' "$_TmpDir/chunks/chunk.aa" > "$_ChunkListFile"

printf 'chunk.aa\t23\t3\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Exit 23 eines Chunks fuehrt zu FAIL"
t_assert_contains "$_Out" "chunk.aa  Exit 23" "der fehlgeschlagene Chunk wird namentlich genannt"
t_assert_contains "$_Out" "ERGEBNIS: FAIL" "das Ergebnis steht im Klartext"

printf 'chunk.aa\t0\t1\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "sauberer Lauf ergibt PASS"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "das Ergebnis steht im Klartext"

# --- CONTROLLER-RULING 1: Ergebniszeilen gegen Chunkzahl abgleichen ---------
# w2u_run_chunk gibt IMMER 0 zurueck. Ein Chunk OHNE Ergebniszeile ist deshalb
# von einem nie gelaufenen Chunk nicht zu unterscheiden - abgestuerzter Worker,
# voller Datentraeger, abgebrochener xargs-Lauf. Wer nur die vorhandenen
# Exit-Codes auswertet, meldet genau dann PASS, wenn am meisten fehlt.
printf '%s\n' "$_TmpDir/chunks/chunk.aa" "$_TmpDir/chunks/chunk.ab" > "$_ChunkListFile"
printf 'chunk.aa\t0\t1\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "RULING 1: weniger Ergebniszeilen als Chunks MUSS FAIL liefern"
t_assert_contains "$_Out" "OHNE ERGEBNISZEILE" "der Bericht sagt im Klartext, dass Ergebnisse fehlen"
t_assert_contains "$_Out" "chunk.ab" "der Bericht nennt den Chunk, dessen Ergebnis fehlt"

# Der Fall, in dem am meisten fehlt: die Ergebnisdatei EXISTIERT, ist aber leer
# (xargs starb am ersten Chunk, der Worker-Pool kam nie hoch). Genau hier bricht
# das uebliche awk-Idiom "NR == FNR" - es hielte dann jede Zeile der Chunkliste
# fuer eine Ergebniszeile und meldete NICHTS als fehlend. Ohne diesen Assert
# bliebe diese Mutation gruen, weil jeder andere Abgleichstest eine nichtleere
# Ergebnisdatei benutzt.
: > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "LEERE Ergebnisdatei bei 2 Chunks -> FAIL (kein einziger Chunk wurde protokolliert)"
t_assert_contains "$_Out" "chunk.aa" "beide Chunks werden als fehlend genannt"
t_assert_contains "$_Out" "chunk.ab" "auch der zweite"

# Zaehlen allein genuegt nicht: zwei Zeilen fuer chunk.aa und keine fuer
# chunk.ab ergeben dieselbe Zeilenzahl wie ein sauberer Lauf. Eine Summe kann
# Verlust und Duplikat nicht auseinanderhalten (Lehre aus Task 7).
printf 'chunk.aa\t0\t1\nchunk.aa\t0\t1\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "gleiche ZEILENZAHL, aber ein Chunk doppelt und einer gar nicht -> FAIL"
t_assert_contains "$_Out" "DOPPELT" "die doppelte Ergebniszeile wird benannt"
t_assert_contains "$_Out" "chunk.ab" "der fehlende Chunk wird trotz passender Zeilenzahl benannt"

# Ergebniszeilen zu Chunks, die gar nicht auf der Liste stehen: eine
# Ergebnisdatei aus einem frueheren Lauf im selben Arbeitsverzeichnis.
printf 'chunk.aa\t0\t1\nchunk.ab\t0\t1\nchunk.zz\t0\t1\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Ergebniszeile fuer einen Chunk ausserhalb der Chunkliste -> FAIL"
t_assert_contains "$_Out" "chunk.zz" "der fremde Chunk wird benannt"

# Bei mehr als 20 Befunden kappen alle drei Bloecke - dann MUSS die Zahl der
# nicht gezeigten dabeistehen, sonst zeigt der Bericht 20 Zeilen und nennt
# daneben eine groessere Zahl ohne Erklaerung.
_Bulk="$_TmpDir/bulk.list"
printf '%s\n' "$_TmpDir/chunks/chunk.aa" > "$_Bulk"
_ChunkListFile="$_Bulk"
: > "$_ResultFile"
_I=1
while [ "$_I" -le 25 ]; do
    printf 'fremd.%s\t0\t1\n' "$_I" >> "$_ResultFile"
    _I=$((_I + 1))
done
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "25 Fremdnamen ergeben FAIL"
t_assert_contains "$_Out" "und 5 weitere" "der Fremdnamen-Block nennt die nicht gezeigten Befunde"

: > "$_ResultFile"
_I=1
while [ "$_I" -le 21 ]; do
    printf 'chunk.d%s\t0\t1\n' "$_I" >> "$_ResultFile"
    printf 'chunk.d%s\t0\t1\n' "$_I" >> "$_ResultFile"
    printf '%s\n' "$_TmpDir/chunks/chunk.d$_I" >> "$_Bulk"
    _I=$((_I + 1))
done
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "21 doppelte Chunks ergeben FAIL"
t_assert_contains "$_Out" "und 1 weitere" "der Duplikat-Block nennt die nicht gezeigten Befunde"
_ChunkListFile="$_TmpDir/chunks.list"

# Kaputte Zeile: rc-Feld nicht numerisch. Nicht auswertbar heisst nicht sauber.
printf 'chunk.aa\t0\t1\nchunk.ab\tkaputt\n' > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "unlesbares Zeilenformat im Ergebnisprotokoll -> FAIL"
t_assert_contains "$_Out" "FORMAT" "der Formatfehler wird benannt"

# Ergebnisdatei fehlt ganz.
printf '%s\n' "$_TmpDir/chunks/chunk.aa" > "$_ChunkListFile"
rm -f "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "fehlende Ergebnisdatei -> FAIL (nicht 'nichts fehlgeschlagen')"
t_assert_contains "$_Out" "ERGEBNISDATEI" "die fehlende Ergebnisdatei wird benannt"
printf 'chunk.aa\t0\t1\n' > "$_ResultFile"

# Ergebnisdatei unlesbar - grep/awk liefern hier rc 2, und ein verschluckter
# rc 2 laese sich als "null fehlgeschlagene Chunks".
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - unlesbare Ergebnisdatei nicht darstellbar"
else
    chmod 000 "$_ResultFile"
    _Out="$(w2u_report 2>&1)"; _Rc=$?
    t_assert_rc 1 "$_Rc" "unlesbare Ergebnisdatei -> FAIL"
    t_assert_contains "$_Out" "ERGEBNISDATEI" "die unlesbare Ergebnisdatei wird benannt"
    chmod 644 "$_ResultFile"
fi

# Chunkliste gesetzt, aber nicht vorhanden: die Vollstaendigkeit ist damit
# nicht pruefbar - und nicht pruefbar ist kein PASS.
_ChunkListFile="$_TmpDir/gibt-es-nicht.list"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "fehlende Chunkliste -> FAIL"
t_assert_contains "$_Out" "CHUNKLISTE" "die fehlende Chunkliste wird benannt"

# Chunkliste vorhanden, aber leer. w2u_chunk bricht bei null Arbeitspaketen ab,
# eine leere registrierte Liste kann es also gar nicht geben - sie als "null
# erwartete Chunks" durchzuwinken hiesse, einen Lauf ganz ohne Uebertragung als
# vollstaendig zu melden.
_ChunkListFile="$_TmpDir/leer.list"
: > "$_ChunkListFile"
: > "$_ResultFile"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "gesetzte, aber LEERE Chunkliste -> FAIL"
t_assert_contains "$_Out" "CHUNKLISTE" "die leere Chunkliste wird benannt"
printf 'chunk.aa\t0\t1\n' > "$_ResultFile"

# Gar keine Chunkliste bekannt (Verify-Only-Lauf, w2u_chunk lief nie), aber es
# gibt Ergebniszeilen: dann ist unbekannt, wieviele es haetten sein muessen.
_ChunkListFile=""
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Ergebniszeilen ohne bekannte Chunkliste -> FAIL"
t_assert_contains "$_Out" "CHUNKLISTE" "der Grund wird benannt"

# Verify-Only-Form: keine Chunkliste UND keine Ergebniszeilen, und der Lauf ist
# ausdruecklich als --verify-only erklaert - nur dann ist fehlende
# Chunk-Buchfuehrung zulaessig, und auch dann nur mit aktivem Zahlenvergleich.
: > "$_ResultFile"
_VerifyOnly=1
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "erklaerter Verify-Only-Lauf (keine Chunks, keine Ergebnisse, Zahlen aktiv) ergibt PASS"

# CRITICAL (Review Task 8): "--verify-only --no-verify" laesst KEINE
# Beweisschicht uebrig - keine Chunk-Buchfuehrung, keine Dateizahlen. Ein PASS
# hiesse "Transfer vollstaendig" auf der Grundlage von nichts. Beide Optionen
# sind dokumentiert, und main() ist noch ein Stub: es gibt heute keinen Parser,
# der die Kombination ablehnt.
_DoVerify=0
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "CRITICAL: --verify-only zusammen mit --no-verify ergibt FAIL, nicht PASS"
t_assert_contains "$_Out" "KEINE Beweisschicht" "der Bericht sagt, warum hier nichts geprueft wurde"
_DoVerify=1

# Gegenprobe zur anderen Haelfte derselben Bedingung: kein erklaertes
# --verify-only, trotzdem keine Chunkliste - das ist ein Lauf, der zerlegen
# sollte und dessen Massstab verlorenging.
_VerifyOnly=0
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "fehlende Chunkliste ohne erklaertes --verify-only ergibt FAIL"
t_assert_contains "$_Out" "Massstab fehlt" "auch hier steht der Grund im Klartext"
_VerifyOnly=1

# --- CONTROLLER-RULING 2: chunks.rest wird nicht vorausgesetzt --------------
# w2u_run_all schreibt chunks.rest NUR im Auto-Messungs-Pfad; im --jobs-N-Pfad
# entsteht die Datei nie, und niemand entfernt eine alte aus einem frueheren
# Lauf. Eine veraltete chunks.rest waere eine Chunkliste eines anderen Laufs,
# im schlimmsten Fall gegen ein anderes Quellverzeichnis. Der Bericht darf sie
# deshalb weder brauchen noch beachten.
_VerifyOnly=0
printf '%s\n' "$_TmpDir/chunks/chunk.aa" > "$_TmpDir/chunks.list"
_ChunkListFile="$_TmpDir/chunks.list"
printf 'chunk.aa\t0\t1\n' > "$_ResultFile"
printf '%s\n' "/woanders/chunk.xx" "/woanders/chunk.xy" "/woanders/chunk.xz" > "$_TmpDir/chunks.rest"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "RULING 2: eine veraltete chunks.rest aendert das Ergebnis nicht"
case "$_Out" in
    *chunk.xx*) _RestGelesen=ja ;;
    *)          _RestGelesen=nein ;;
esac
t_assert_eq "nein" "$_RestGelesen" "RULING 2: der Bericht liest chunks.rest ueberhaupt nicht"
rm -f "$_TmpDir/chunks.rest"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "RULING 2: eine FEHLENDE chunks.rest ist ebenso unerheblich"

# --- Dateizahl-Vergleich ---------------------------------------------------
mv "$_DstRoot/Bildarchiv/direkt_datei.txt" "$_TmpDir/beiseite.txt"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "abweichende Dateizahl -> FAIL"
t_assert_contains "$_Out" "ABWEICHUNG" "die Abweichung wird benannt"

# Bei aktiven Ausschluessen sind die Zahlen nur orientierend - sonst waere
# jeder Lauf mit --exclude-from ein garantiertes falsches FAIL.
_ExcludeFrom="$_TmpDir/excludes.txt"; printf '%s\n' "nichts-davon" > "$_ExcludeFrom"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "bei aktiven Ausschluessen ist die Dateizahl nur orientierend"
t_assert_contains "$_Out" "orientierend" "der Hinweis dazu steht im Bericht"
_ExcludeFrom=""

# --no-verify: der Nutzer waehlt die Luecke bewusst, der Bericht sagt es.
_DoVerify=0
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "--no-verify ueberspringt den Zahlenvergleich"
t_assert_contains "$_Out" "uebersprungen" "der Bericht benennt die uebersprungene Pruefung"
_DoVerify=1
mv "$_TmpDir/beiseite.txt" "$_DstRoot/Bildarchiv/direkt_datei.txt"

# Eine Zahl, die nicht ermittelt werden konnte, darf nicht als "gleich" gelten.
_SrcUrl="rsync://127.0.0.1:1/test"
_Out="$(w2u_report 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "nicht ermittelbare Dateizahl -> FAIL"
t_assert_contains "$_Out" "nicht ermittelbar" "der Grund wird benannt"
_SrcUrl="$_SaveUrl"

# --- Shell-Optionen und errexit --------------------------------------------
# Gleiche Zusicherung wie fuer w2u_run_chunk (Task 6): keine Funktion darf die
# Shell-Optionen ihres Aufrufers veraendern. "$-" ohne Kommandosubstitution,
# weil bash errexit fuer die Dauer JEDER Substitution abschaltet.
_OptsBefore="$-|$(set +o | grep -v ' errexit$')"
w2u_verify >/dev/null 2>&1 || true
w2u_report >/dev/null 2>&1 || true
_OptsAfter="$-|$(set +o | grep -v ' errexit$')"
t_assert_eq "$_OptsBefore" "$_OptsAfter" "w2u_verify/w2u_report lassen die Shell-Optionen des Aufrufers unveraendert"

# Der Bericht laeuft produktiv unter "set -euo pipefail" (main()). Ein
# fehlgeschlagener Test mitten im Bericht (etwa "[ $_Bad -gt 0 ]" als
# Einzelkommando) risse dort die Shell ab, BEVOR das Ergebnis gedruckt ist -
# und ein Lauf ohne gedrucktes Ergebnis ist genau das, was niemand bemerkt.
# w2u_verify unter echtem errexit, beide Ausgaenge: der saubere Lauf darf die
# Shell nicht abreissen, und der Befund-Lauf muss seine Begruendung VOLLSTAENDIG
# ausgeben, bevor er mit rc 1 endet.
# Vorher aufraeumen: der Dateizahl-Test oben hat eine Datei aus Bildarchiv
# heraus- und wieder hineingeschoben, und das aendert die mtime des
# VERZEICHNISSES. Der Verify meldet das (".d..t...... Bildarchiv/") - zu Recht,
# und nebenbei ein weiterer Beleg, dass der Wurzel-Filter wirklich nur die
# Wurzel schluckt. Fuer die errexit-Probe wird ein sauberer Baum gebraucht.
w2u_sweep >/dev/null 2>&1
_ProbeOut="$( ( set -e; w2u_verify; printf 'VERIFY_DURCH\n' ) 2>&1 )"; _ProbeRc=$?
t_assert_rc 0 "$_ProbeRc" "sauberer Verify laeuft unter echtem errexit durch"
t_assert_contains "$_ProbeOut" "VERIFY_DURCH" "und kommt bis hinter den Aufruf"
_SaveUrl2="$_SrcUrl"
_SrcUrl="rsync://127.0.0.1:1/test"
_ProbeOut="$( ( set -e; w2u_verify; printf 'VERIFY_DURCH\n' ) 2>&1 )"; _ProbeRc=$?
t_assert_rc 1 "$_ProbeRc" "Verify mit Befund liefert unter echtem errexit rc 1"
t_assert_contains "$_ProbeOut" "NICHT MOEGLICH" "und hat seine Begruendung vorher gedruckt"
_SrcUrl="$_SaveUrl2"

_ProbeOut="$( ( set -e; w2u_sweep; printf 'SWEEP_DURCH\n' ) 2>&1 )"; _ProbeRc=$?
t_assert_rc 0 "$_ProbeRc" "der Sweep laeuft unter echtem errexit durch (ohne Ausschluesse, also mit falschem '[ -n ] &&')"
t_assert_contains "$_ProbeOut" "SWEEP_DURCH" "und kommt bis hinter den Aufruf"

printf 'chunk.aa\t0\t1\n' > "$_ResultFile"
_ProbeOut="$( ( set -e; w2u_report ) 2>&1 )"; _ProbeRc=$?
t_assert_rc 0 "$_ProbeRc" "PASS-Bericht laeuft unter echtem errexit durch"
t_assert_contains "$_ProbeOut" "ERGEBNIS: PASS" "und druckt sein Ergebnis auch dort"
printf 'chunk.aa\t23\t3\n' > "$_ResultFile"
_ProbeOut="$( ( set -e; w2u_report ) 2>&1 )"; _ProbeRc=$?
t_assert_rc 1 "$_ProbeRc" "FAIL-Bericht liefert unter echtem errexit rc 1"
t_assert_contains "$_ProbeOut" "ERGEBNIS: FAIL" "und druckt den vollstaendigen Bericht, statt vorher abzubrechen"

# ---------------------------------------------------------------------------
# argv-Pruefungen mit Stub statt echtem rsync: Optionen, die der Daemontest
# nicht sichtbar macht. Ab hier ist $_RsyncBin gefaelscht.
# ---------------------------------------------------------------------------
_FakeBinDir="$_TmpDir/fakebin"; mkdir -p "$_FakeBinDir"
cat > "$_FakeBinDir/rsync" <<'FAKE_EOF'
#!/usr/bin/env bash
_Dir="$(dirname "$0")"
_N=0
[ -f "$_Dir/calls.count" ] && _N="$(cat "$_Dir/calls.count")"
_N=$((_N + 1))
printf '%s\n' "$_N" > "$_Dir/calls.count"
printf '%s\n' "$@" > "$_Dir/call.$_N.args"
exit 0
FAKE_EOF
chmod +x "$_FakeBinDir/rsync"
_RsyncBin="$_FakeBinDir/rsync"

# Sweep: ohne die Ausschluesse holte ausgerechnet der Sweep alles wieder her,
# was die Chunks bewusst ausgelassen haben.
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
_ExcludeFrom="$_TmpDir/excludes.txt"
w2u_sweep >/dev/null 2>&1
t_assert_eq "1" "$(grep -c -- "--exclude-from=$_ExcludeFrom" "$_FakeBinDir/call.1.args")" "der Sweep uebernimmt --exclude-from"
t_assert_eq "1" "$(grep -c -- "--timeout=$_RsyncTimeout" "$_FakeBinDir/call.1.args")" "der Sweep laeuft mit --timeout (Haenger statt Abbruch waere hier fatal)"

# Verify mit denselben Ausschluessen - sonst meldete er jede ausgeschlossene
# Datei als fehlend und JEDER Lauf mit --exclude-from endete im FAIL.
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
w2u_verify >/dev/null 2>&1
t_assert_eq "1" "$(grep -c -- "--exclude-from=$_ExcludeFrom" "$_FakeBinDir/call.1.args")" "der Verify uebernimmt --exclude-from"
t_assert_eq "0" "$(grep -cx -- "-c" "$_FakeBinDir/call.1.args" || true)" "ohne --checksum kein -c im argv"

# --checksum ist eine ausdrueckliche Nutzerentscheidung. Liest sie niemand,
# verspricht die Option eine Pruefung, die gar nicht stattfindet.
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
_DoChecksum=1
w2u_verify >/dev/null 2>&1
t_assert_eq "1" "$(grep -cx -- "-c" "$_FakeBinDir/call.1.args")" "--checksum setzt -c im argv des Verify"
_DoChecksum=0
_ExcludeFrom=""

# rc 0 UND trotzdem keine verstandene Listing-Zeile: der Stub endet mit 0 und
# schreibt nichts auf stdout. Eine 0 waere hier eine Zahl aus dem Nichts -
# "remote 0 / lokal 0" laese sich als Uebereinstimmung.
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
t_assert_eq "" "$(w2u_count_remote)" "rc 0 mit LEERER Ausgabe ergibt keine Zahl, sondern 'nicht ermittelbar'"

# Dasselbe mit Ausgabe, die kein rsync-Listing ist (fremdes Format, Bannerzeile,
# abgeschnittene Uebertragung): auch das ist keine Messung.
cat > "$_FakeBinDir/rsync" <<'FAKE2_EOF'
#!/usr/bin/env bash
printf 'irgendein Text, der kein Listing ist
'
printf 'noch eine Zeile
'
exit 0
FAKE2_EOF
chmod +x "$_FakeBinDir/rsync"
t_assert_eq "" "$(w2u_count_remote)" "rc 0 mit unverstandener Ausgabe ergibt ebenfalls 'nicht ermittelbar'"

# Gegenprobe, damit die Pruefung nicht einfach immer leer liefert: ein echtes
# Listing mit einer Verzeichniszeile und ohne Datei IST eine Messung (0).
cat > "$_FakeBinDir/rsync" <<'FAKE3_EOF'
#!/usr/bin/env bash
printf 'drwxr-xr-x            128 2026/08/25 04:34:32 .
'
exit 0
FAKE3_EOF
chmod +x "$_FakeBinDir/rsync"
t_assert_eq "0" "$(w2u_count_remote)" "ein verstandenes Listing ohne regulaere Datei ergibt die Messung 0, nicht 'unbekannt'"

# argv-Stub wiederherstellen
cat > "$_FakeBinDir/rsync" <<'FAKE_EOF'
#!/usr/bin/env bash
_Dir="$(dirname "$0")"
_N=0
[ -f "$_Dir/calls.count" ] && _N="$(cat "$_Dir/calls.count")"
_N=$((_N + 1))
printf '%s
' "$_N" > "$_Dir/calls.count"
printf '%s
' "$@" > "$_Dir/call.$_N.args"
exit 0
FAKE_EOF
chmod +x "$_FakeBinDir/rsync"

rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
_ExcludeFrom=""
w2u_sweep >/dev/null 2>&1
t_assert_eq "0" "$(grep -c -- "--exclude-from" "$_FakeBinDir/call.1.args" || true)" "ohne Ausschluesse steht kein --exclude-from im argv"

t_summary
