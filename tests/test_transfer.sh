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
# errexit dauerhaft einschaltet, blieb mit "$(set +o)" GRUEN. Vom Reviewer auf
# dieser bash 3.2.57 nachgebaut und bestaetigt (huB -> ehuB bei eingebautem
# Leck) - dieser Test bleibt unveraendert.
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

# Bytes muessen identisch sein - beweist, dass keine Normalisierung stattfand.
# Dieser Block (echter rsync/Daemon) bleibt unveraendert - Vorgabe aus dem Review.
_A="$(printf '%s' "Größe & Maß.DOC" | xxd -p)"
_B="$(cd "$_Dst/ordner mit leerzeichen" && printf '%s' "$(ls)" | xxd -p)"
t_assert_eq "$_A" "$_B" "Dateiname byte-identisch (kein NFC/NFD-Problem)"

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

# ---------------------------------------------------------------------------
# Review-Fix (Important 1): "immer 0" muss unter ECHTEM errexit gelten, nicht
# nur unter der "set -uo pipefail" dieses Testskripts. main() setzt
# "set -euo pipefail" - das ist die Shell-Konfiguration, unter der die Funktion
# produktiv laeuft. Ein vorheriger Test dieser Zusicherung lief ohne -e und war
# damit nicht vacuous, aber pruefte etwas anderes.
#
# "( set -e; ... )" reproduziert echten errexit in einem Subshell, OHNE eine
# neue Script-Datei/einen neuen Prozess zu brauchen: Funktionen und Variablen
# der aktuellen (gesourcten) Shell werden in den Fork mitvererbt. Die dabei
# noetige Kommandosubstitution zum Einsammeln der Ausgabe neutralisiert nur die
# AEUSSERE Shell fuer die Dauer der Substitution (siehe Ruling-1-Kommentar oben)
# - das INNERE, explizite "set -e" im Subshell bleibt davon unberuehrt (empirisch
# geprueft: "( set -e; false; echo weiter )" liefert rc 1 und "weiter" wird NIE
# gedruckt, auch wenn das Ganze in "$( ... )" eingebettet ist).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Schreibschutz-Test fuer 'immer 0 trotz printf-Fehlschlag unter echtem errexit' ist wirkungslos"
else
    mkdir -p "$_TmpDir/gesperrt"
    chmod 000 "$_TmpDir/gesperrt"

    _ProbeOut="$(
        (
            set -e
            _ResultFile="$_TmpDir/gesperrt/results"
            w2u_run_chunk "$_TmpDir/chunk.aa"
            printf 'FUNKTION_RC=%s\n' "$?"
        ) 2>&1
    )"
    _ProbeRc=$?
    t_assert_eq "0" "$_ProbeRc" "unter set -e (main()-Konfiguration) beendet ein fehlgeschlagenes Anhaengen ans Ergebnisprotokoll das Skript NICHT"
    t_assert_contains "$_ProbeOut" "FUNKTION_RC=0" "w2u_run_chunk selbst liefert 0, auch wenn printf >> unter echtem errexit scheitert"
    t_assert_contains "$_ProbeOut" "WARNUNG" "der verlorene Schreibversuch wird sichtbar gemeldet statt spurlos zu verschwinden"

    chmod 755 "$_TmpDir/gesperrt"
fi

# ---------------------------------------------------------------------------
# Review-Fix (Important 2, erste Haelfte): eine while-Schleife mit null
# Durchlaeufen darf keine Erfolgszeile hinterlassen. Gemessen am alten Stand:
# _MaxRetry=0 -> null rsync-Aufrufe, Zeile "chunk.aa 0 0" (falscher Erfolg).
# ---------------------------------------------------------------------------
_ResultFile="$_TmpDir/results"; : > "$_ResultFile"
_MaxRetry=0
_RetryPause=1
w2u_run_chunk "$_TmpDir/chunk.aa"
_RcZero="$(cut -f2 "$_ResultFile")"
_TriesZero="$(cut -f3 "$_ResultFile")"
[ "$_RcZero" != "0" ] && _NichtFalschErfolg=ja || _NichtFalschErfolg=nein
t_assert_eq "ja" "$_NichtFalschErfolg" "_MaxRetry=0 (null Versuche) wird NICHT als Erfolg (rc 0) protokolliert"
t_assert_eq "0" "$_TriesZero" "_MaxRetry=0 zeigt 0 tatsaechliche Versuche, nicht 1"
_MaxRetry=2
_RetryPause=1

# ---------------------------------------------------------------------------
# Review-Fix (Important 2, zweite Haelfte): ein nicht-numerisches _RetryPause
# darf nicht als roher Arithmetikfehler unter errexit den GESAMTEN Lauf
# abreissen. Erwartet: kontrollierter Abbruch per w2u_die (Konfigurationsfehler,
# kein Transferfehler), sichtbar als ABBRUCH, KEINE (erst recht keine
# falsch-positive) Ergebniszeile.
# ---------------------------------------------------------------------------
_BadResultFile="$_TmpDir/results_badconfig"
_ProbeErr2="$(
    (
        set -e
        _ResultFile="$_BadResultFile"
        _RetryPause="abc"
        w2u_run_chunk "$_TmpDir/chunk.aa"
    ) 2>&1 >/dev/null
)"
_ProbeRc2=$?
t_assert_eq "1" "$_ProbeRc2" "nicht-numerisches _RetryPause bricht kontrolliert ab (w2u_die), statt eine Erfolgszeile zu erzeugen oder mit einem rohen Arithmetikfehler zu crashen"
t_assert_contains "$_ProbeErr2" "ABBRUCH" "der Abbruch ist als solcher sichtbar"
[ -s "$_BadResultFile" ] && _WroteResult=ja || _WroteResult=nein
t_assert_eq "nein" "$_WroteResult" "bei ungueltiger Konfiguration wird KEINE Ergebniszeile geschrieben"
rm -f "$_BadResultFile"

# ---------------------------------------------------------------------------
# Review-Fix (Important 3, Minor 4, Minor 5, Minor 6): argv-Stub statt echtem
# rsync. Prueft (a) dass --exclude-from genau dann im argv steht, wenn
# _ExcludeFrom gesetzt ist, und nie sonst - der einzige Zweig in der
# Argumentkonstruktion, den Ruling 2 eigentlich schuetzen sollte, war bislang
# von keiner Assertion gepinnt; (b) dass --timeout immer im argv steht;
# (c) Retry-Zaehlung deterministisch, ohne Wanduhr-Abhaengigkeit (ersetzt den
# vorherigen 0,3s-Wettlauf gegen einen Hintergrundjob); (d) dass jeder Versuch
# sein eigenes Logfile bekommt statt eines gemeinsamen, das jeder neue Versuch
# ueberschreibt.
# ---------------------------------------------------------------------------
_FakeBinDir="$_TmpDir/fakebin"
mkdir -p "$_FakeBinDir"
_FakeRsync="$_FakeBinDir/rsync"
cat > "$_FakeRsync" <<'FAKE_EOF'
#!/usr/bin/env bash
# Test-Stub: schreibt sein eigenes argv weg und liefert einen vorbestimmten rc
# (aus "plan", eine Zeile je Aufruf), damit Argumentkonstruktion und
# Retry-Zaehlung ohne echten Netzwerk-Transfer und ohne Wanduhr-Abhaengigkeit
# geprueft werden koennen.
_Dir="$(dirname "$0")"
_N=0
[ -f "$_Dir/calls.count" ] && _N="$(cat "$_Dir/calls.count")"
_N=$((_N + 1))
printf '%s\n' "$_N" > "$_Dir/calls.count"
printf '%s\n' "$@" > "$_Dir/call.$_N.args"
echo "fake-rsync attempt $_N" >&2
_Rc=0
if [ -f "$_Dir/plan" ]; then
    _Rc="$(sed -n "${_N}p" "$_Dir/plan")"
fi
[ -n "$_Rc" ] || _Rc=0
exit "$_Rc"
FAKE_EOF
chmod +x "$_FakeRsync"

_RsyncBin="$_FakeRsync"
_LogDir="$_TmpDir/fakelogs"; mkdir -p "$_LogDir"
_MaxRetry=3
_RetryPause=0
printf '%s\n' "irgendwas" > "$_TmpDir/chunk.stub"

# (a) --exclude-from im argv, wenn _ExcludeFrom gesetzt ist
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args "$_FakeBinDir"/plan
_ResultFile="$_TmpDir/results"; : > "$_ResultFile"
_ExcludeFrom="$_TmpDir/excludes.txt"; : > "$_ExcludeFrom"
w2u_run_chunk "$_TmpDir/chunk.stub"
t_assert_eq "1" "$(grep -c -- "--exclude-from=$_ExcludeFrom" "$_FakeBinDir/call.1.args")" "--exclude-from steht im argv, wenn _ExcludeFrom gesetzt ist"

# (a, Gegenprobe) --exclude-from fehlt, wenn _ExcludeFrom leer ist
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args "$_FakeBinDir"/plan
_ExcludeFrom=""
w2u_run_chunk "$_TmpDir/chunk.stub"
t_assert_eq "0" "$(grep -c -- "--exclude-from" "$_FakeBinDir/call.1.args" || true)" "--exclude-from fehlt im argv, wenn _ExcludeFrom leer ist"

# (b) --timeout steht immer im argv
t_assert_eq "1" "$(grep -c -- "--timeout=$_RsyncTimeout" "$_FakeBinDir/call.1.args")" "--timeout steht immer im argv (openrsync-erlaubt, verhindert Haenger statt Retry)"

# (c) Retry deterministisch: erster Versuch rc 23, zweiter Versuch rc 0
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args
printf '23\n0\n' > "$_FakeBinDir/plan"
: > "$_ResultFile"
rm -f "$_LogDir"/chunk.stub.*.log
w2u_run_chunk "$_TmpDir/chunk.stub"
_RcStub="$(cut -f2 "$_ResultFile")"
_TriesStub="$(cut -f3 "$_ResultFile")"
t_assert_eq "0" "$_RcStub" "Stub: Erfolg im zweiten Versuch wird als rc 0 protokolliert (deterministisch, ohne Wanduhr)"
t_assert_eq "2" "$_TriesStub" "Stub: Versuchszaehler zeigt exakt 2 Versuche"
t_assert_eq "2" "$(cat "$_FakeBinDir/calls.count")" "Stub: rsync wurde exakt zweimal aufgerufen, nicht dreimal (kein Weiterzaehlen nach Erfolg)"

# (d) jeder Versuch bekommt sein eigenes Logfile - Versuch 1 (rc 23) darf vom
# erfolgreichen Versuch 2 nicht ueberschrieben werden, sonst ist die Diagnose
# (welche Dateien waren gesperrt) weg, und die Windows-Quelle wird danach
# verschrottet - kein zweites Hinsehen moeglich.
t_assert_contains "$(cat "$_LogDir/chunk.stub.1.log" 2>/dev/null)" "attempt 1" "Log des ersten (fehlgeschlagenen) Versuchs bleibt erhalten"
t_assert_contains "$(cat "$_LogDir/chunk.stub.2.log" 2>/dev/null)" "attempt 2" "Log des zweiten (erfolgreichen) Versuchs steht in einer EIGENEN Datei, ueberschreibt Versuch 1 nicht"

# Sentinel-Test (Important 2) nochmal mit dem Stub, zusaetzlich zum
# Daemon-basierten oben: _MaxRetry=0 -> rsync wird ueberhaupt nicht aufgerufen.
rm -f "$_FakeBinDir"/calls.count "$_FakeBinDir"/call.*.args "$_FakeBinDir"/plan
: > "$_ResultFile"
_MaxRetry=0
w2u_run_chunk "$_TmpDir/chunk.stub"
[ -f "$_FakeBinDir/calls.count" ] && _CallsMade="$(cat "$_FakeBinDir/calls.count")" || _CallsMade=0
t_assert_eq "0" "$_CallsMade" "_MaxRetry=0: rsync wird ueberhaupt nicht aufgerufen (Stub-Beleg zum Daemon-Test oben)"
_MaxRetry=3

# ---------------------------------------------------------------------------
# Review-Fix (Minor 7): ein Chunkname mit TAB wuerde die einzige Stelle
# zerstoeren, an der ein Fehlschlag je sichtbar wird ($_ResultFile). Aktuell
# von "split" nicht erzeugbar, aber billig gegen kuenftige Aufrufer abgesichert.
# ---------------------------------------------------------------------------
_TabName="chunk$(printf '\t')mit-tab"
_TabChunkFile="$_TmpDir/$_TabName"
printf '%s\n' "irgendwas" > "$_TabChunkFile"
_ResultFile="$_TmpDir/results_tabguard"; : > "$_ResultFile"
_TabErr="$(w2u_run_chunk "$_TabChunkFile" 2>&1)"
_TabRc=$?
t_assert_eq "1" "$_TabRc" "Chunkname mit TAB wird abgelehnt (w2u_die), nicht stillschweigend verarbeitet"
t_assert_contains "$_TabErr" "ABBRUCH" "die Ablehnung ist sichtbar"
[ -s "$_ResultFile" ] && _TabWroteResult=ja || _TabWroteResult=nein
t_assert_eq "nein" "$_TabWroteResult" "bei TAB im Chunknamen wird KEINE (potenziell korrupte) Ergebniszeile geschrieben"

t_summary
