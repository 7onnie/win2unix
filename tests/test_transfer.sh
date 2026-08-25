#!/usr/bin/env bash
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

mkdir -p "$_Src/ordner mit leerzeichen"
printf 'inhalt\n' > "$_Src/ordner mit leerzeichen/Größe & Maß.DOC"
mkdir -p "$_Src/leer"
if ! d_start "$_Src"; then
    t_skip "rsync-Daemon konnte auf keinem der versuchten Ports binden - Test wird uebersprungen statt gegen den falschen Daemon zu laufen"
    t_summary
fi
w2u_find_rsync

_SrcUrl="$D_Url"
_DstRoot="$_Dst"
_LogDir="$_TmpDir/logs"; mkdir -p "$_LogDir"
_ResultFile="$_TmpDir/results"; : > "$_ResultFile"
_MaxRetry=2
_RetryPause=1

# CONTROLLER-RULING 1 Testpflicht: w2u_run_chunk darf die Shell-Optionen der
# aufrufenden Shell nicht veraendern.
#
# Falle (per Messung gefunden, nicht nur vermutet): "$(set +o)" allein taugt
# NICHT als Nachweis. bash deaktiviert errexit strukturell fuer die Dauer
# JEDER Kommandosubstitution ($(...)) - unabhaengig vom Zustand der
# aufrufenden Shell. Dadurch zeigt "$(set +o | grep errexit)" IMMER
# "set +o errexit" (aus), auch wenn errexit in der aufrufenden Shell laengst
# eingeschaltet ist. Ein Test, der sich allein darauf verlaesst, waere ein
# Test, den keine Mutation brechen kann (siehe Task-4/5-Standard) - probeweise
# mit einer Mutation nachgestellt: eine Funktion, die per "set -e" am Ende
# errexit dauerhaft einschaltet, blieb mit "$(set +o)" GRUEN.
#
# Deshalb zweigeteilt: "$-" wird OHNE Kommandosubstitution ausgewertet (reine
# Parameter-Expansion, kein Subshell) und erfasst einzelbuchstabige Optionen
# wie errexit (e) und nounset (u) zuverlaessig. Die restlichen, nur ueber
# "set -o <name>" benannten Optionen (v.a. pipefail) kommen weiterhin ueber
# "$(set +o)", mit der (nachweislich immer falschen) errexit-Zeile
# herausgefiltert, damit sie das Ergebnis nicht mit einem strukturell
# garantierten "unveraendert" verfaelscht.
_OptsBefore="$-|$(set +o | grep -v ' errexit$')"

printf '%s\n' "ordner mit leerzeichen" "leer" > "$_TmpDir/chunk.aa"
w2u_run_chunk "$_TmpDir/chunk.aa"
t_assert_rc 0 "$?" "Worker liefert immer 0"

_OptsAfter="$-|$(set +o | grep -v ' errexit$')"
t_assert_eq "$_OptsBefore" "$_OptsAfter" "Shell-Optionen der aufrufenden Shell unveraendert nach w2u_run_chunk (Ruling 1, Erfolgsfall)"

t_assert_eq "inhalt" "$(cat "$_Dst/ordner mit leerzeichen/Größe & Maß.DOC" 2>/dev/null)" "Datei mit Umlaut und Leerzeichen kam an"
t_assert_eq "0" "$(cut -f2 "$_ResultFile")" "Exit-Code 0 im Ergebnisprotokoll"
t_assert_eq "1" "$(cut -f3 "$_ResultFile")" "genau ein Versuch im Erfolgsfall"
[ -d "$_Dst/leer" ] && _LeerDa=ja || _LeerDa=nein
t_assert_eq "ja" "$_LeerDa" "leerer Ordner wurde angelegt"

# Bytes muessen identisch sein - beweist, dass keine Normalisierung stattfand
_A="$(printf '%s' "Größe & Maß.DOC" | xxd -p)"
_B="$(cd "$_Dst/ordner mit leerzeichen" && printf '%s' "$(ls)" | xxd -p)"
t_assert_eq "$_A" "$_B" "Dateiname byte-identisch (kein NFC/NFD-Problem)"

# Erfolg erst im zweiten Versuch: der Chunk verweist zunaechst auf eine Datei,
# die noch nicht existiert (erster Versuch scheitert daher mit rc != 0), waehrend
# ein Hintergrundjob sie kurz vor Ablauf von _RetryPause anlegt. Damit ist
# geprueft, dass der Versuchszaehler im ERFOLGSFALL nach Retry wirklich die
# tatsaechliche Anzahl Versuche zeigt (2), nicht pauschal 1 - eine Implementierung,
# die den Zaehler nur bei komplettem Fehlschlag hochzaehlt, faellt hier durch.
mkdir -p "$_Src/kommt-spaeter"
printf '%s\n' "kommt-spaeter/datei.txt" > "$_TmpDir/chunk.ar"
( sleep 0.3; printf 'jetzt-da\n' > "$_Src/kommt-spaeter/datei.txt" ) &
: > "$_ResultFile"
w2u_run_chunk "$_TmpDir/chunk.ar"
t_assert_rc 0 "$?" "Worker liefert immer 0 (Erfolg im zweiten Versuch)"
wait
_RcRetrySuccess="$(cut -f2 "$_ResultFile")"
_TriesRetrySuccess="$(cut -f3 "$_ResultFile")"
t_assert_eq "0" "$_RcRetrySuccess" "Erfolg im zweiten Versuch wird als rc 0 protokolliert"
t_assert_eq "2" "$_TriesRetrySuccess" "Versuchszaehler zeigt 2, nicht 1, wenn erst der zweite Versuch gelang"

# Fehlerfall: Chunk zeigt auf etwas, das es nicht gibt -> rc != 0, Retry-Zaehler hoch
printf '%s\n' "gibt-es-nicht" > "$_TmpDir/chunk.ab"
: > "$_ResultFile"
_OptsBeforeFail="$-|$(set +o | grep -v ' errexit$')"
w2u_run_chunk "$_TmpDir/chunk.ab"
t_assert_rc 0 "$?" "Worker liefert immer 0 (Fehlerfall)"
_OptsAfterFail="$-|$(set +o | grep -v ' errexit$')"
t_assert_eq "$_OptsBeforeFail" "$_OptsAfterFail" "Shell-Optionen unveraendert auch nach vollstaendig fehlgeschlagenem Chunk (Ruling 1, Fehlerpfad)"

_Rc="$(cut -f2 "$_ResultFile")"
_Tries="$(cut -f3 "$_ResultFile")"
[ "$_Rc" != "0" ] && _RcNonZero=ja || _RcNonZero=nein
t_assert_eq "ja" "$_RcNonZero" "fehlender Pfad ergibt Exit != 0"
t_assert_eq "2" "$_Tries" "es wurde bis _MaxRetry wiederholt"
t_assert_eq "1" "$(grep -c . "$_ResultFile")" "genau eine Ergebniszeile je Chunk-Aufruf, kein Ueberschreiben oder Duplizieren"

# Messungs-Luecke geschlossen: alle bisherigen Bloecke leeren $_ResultFile VOR
# dem jeweiligen Aufruf. Ein Wechsel von ">>" (anhaengen) auf ">"
# (ueberschreiben) beim Schreiben der Ergebniszeile faellt dabei nicht auf -
# beide Varianten hinterlassen in einem frisch geleerten File genau eine
# Zeile. Erst zwei Aufrufe HINTEREINANDER ohne Leeren dazwischen trennen die
# Faelle: bei ">" bliebe nur die zweite Zeile uebrig, bei korrektem ">>"
# stehen beide. Genau diese Mutation wurde probeweise eingebaut und blieb mit
# der alten Testabdeckung gruen - deshalb hier gezielt gepinnt.
: > "$_ResultFile"
w2u_run_chunk "$_TmpDir/chunk.aa"
w2u_run_chunk "$_TmpDir/chunk.aa"
t_assert_eq "2" "$(grep -c . "$_ResultFile")" "zwei aufeinanderfolgende Aufrufe haengen an $_ResultFile an, statt sich gegenseitig zu ueberschreiben"

# Zweite Messungs-Luecke: "return 0" nach dem printf war bislang durch nichts
# gepinnt - der Guard ist wirkungslos, SOLANGE printf selbst gelingt (dann ist
# printfs eigener rc schon 0 und traegt die Garantie mit). Er greift genau
# dann, wenn der printf-Schreibvorgang scheitert (z.B. Ergebnisdatei nicht
# beschreibbar) - ohne explizites "return 0" wuerde die Funktion in diesem
# Fall printfs Fehlschlag-rc zurueckgeben und die Kern-Zusicherung ("liefert
# IMMER 0") gerade in dem Moment brechen, in dem ein Chunk zusaetzlich zum
# rsync-Fehler auch noch das Protokollieren nicht schafft.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Schreibschutz-Test fuer 'immer 0 trotz printf-Fehlschlag' ist wirkungslos"
else
    mkdir -p "$_TmpDir/gesperrt"
    chmod 000 "$_TmpDir/gesperrt"
    _ResultFile="$_TmpDir/gesperrt/results"
    w2u_run_chunk "$_TmpDir/chunk.aa"
    t_assert_rc 0 "$?" "Worker liefert 0 zurueck, selbst wenn das Anhaengen ans Ergebnisprotokoll scheitert"
    chmod 755 "$_TmpDir/gesperrt"
fi

t_summary
