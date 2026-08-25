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

_I=1
while [ "$_I" -le 24 ]; do
    mkdir -p "$_Src/o$_I"
    echo "inhalt $_I" > "$_Src/o$_I/f.txt"
    _I=$((_I + 1))
done
if ! d_start "$_Src"; then
    t_skip "rsync-Daemon konnte auf keinem der versuchten Ports binden - Test wird uebersprungen statt gegen den falschen Daemon zu laufen"
    t_summary
fi
w2u_find_rsync

_SrcUrl="$D_Url"
_DstRoot="$_Dst"
# Die parallele Phase hat seit dem Modulwurzel-Fix (Task 9) eigene Pfade:
# w2u_run_chunk uebertraegt von _ParSrc (der MODULWURZEL - mit einer
# Unterpfad-URL findet der Daemon die --files-from-Eintraege nicht und
# uebertraegt nichts) nach _ParDst. Hier ist die Quelle ohnehin die Wurzel, die
# Werte sind also dieselben wie oben; gesetzt werden muessen sie trotzdem,
# sonst greift der Guard in w2u_run_chunk.
_ParSrc="$D_Url"
_ParDst="$_Dst"
_LogDir="$_TmpDir/logs"; mkdir -p "$_LogDir"
_ResultFile="$_TmpDir/results"; : > "$_ResultFile"
_MaxRetry=2; _RetryPause=1

w2u_decompose "$D_Url" 32 "$_TmpDir/work"
mkdir -p "$_TmpDir/chunks"
w2u_chunk "$_TmpDir/work" "$_TmpDir/chunks" 8 "$_TmpDir/chunks.list"

# ===========================================================================
# Teil 1 - echter Daemon: der parallele Runner uebertraegt vollstaendig
# ===========================================================================
w2u_run_list "$_TmpDir/chunks.list" 4
t_assert_eq "24" "$(find "$_Dst" -name f.txt | wc -l | tr -d ' ')" "alle 24 Dateien parallel uebertragen"
t_assert_eq "$(grep -c . "$_TmpDir/chunks.list")" "$(grep -c . "$_ResultFile")" "je Chunk genau ein Ergebnis-Eintrag"
t_assert_eq "0" "$(cut -f2 "$_ResultFile" | grep -vc '^0$' || true)" "kein Chunk mit Exit != 0"

# ---------------------------------------------------------------------------
# Auto-Messung am echten Daemon. Das Ziel ist hier bereits VOLLSTAENDIG - jede
# Probe-Runde uebertraegt null Bytes. Genau der Fall, in dem eine Messung nichts
# aussagt: sie darf dann keine Stufe "gewinnen" lassen, sondern muss als nicht
# verwertbar gemeldet werden und auf den dokumentierten Vorgabewert zurueckfallen.
# ---------------------------------------------------------------------------
_Best="$(w2u_autotune "$_TmpDir/chunks.list" 2> "$_TmpDir/tune1.log")"
case "$_Best" in
    2|4|8) _Ok=ja ;;
    *)     _Ok=nein ;;
esac
t_assert_eq "ja" "$_Ok" "Auto-Messung liefert 2, 4 oder 8 (bekam: $_Best)"
[ -f "$_TmpDir/chunks.rest" ] && _RestDa=ja || _RestDa=nein
t_assert_eq "ja" "$_RestDa" "Restliste wurde geschrieben"
t_assert_contains "$(cat "$_TmpDir/tune1.log")" "nicht verwertbar" "Runde ohne uebertragene Bytes wird als nicht verwertbar gemeldet"
t_assert_contains "$(cat "$_TmpDir/tune1.log")" "Vorgabewert" "ohne verwertbare Messung wird der Rueckfallwert als solcher benannt, nicht als Messergebnis"

# ---------------------------------------------------------------------------
# Vollstaendigkeitsbeweis: Probe-Runden und Restliste ueberdecken die
# Ausgangsliste EXAKT - kein Chunk doppelt (waere doppelte Uebertragung), keiner
# verloren (waere stiller Datenverlust, und die Quelle wird danach verschrottet).
# Sortierter Mengenvergleich statt Zeilenzahl: eine Summe kann Verlust und
# Duplikat nicht auseinanderhalten (dieselbe Blindheit wie in Task 4/5).
# ---------------------------------------------------------------------------
cat "$_TmpDir"/probe.* "$_TmpDir/chunks.rest" > "$_TmpDir/union"
t_assert_eq "$(sort "$_TmpDir/chunks.list")" "$(sort "$_TmpDir/union")" "Probe-Runden plus Restliste sind identisch mit der Ausgangsliste (kein Chunk doppelt oder verloren)"

# ===========================================================================
# Teil 2 - Stub statt rsync: alles ab hier ist deterministisch und ohne Netz
# ===========================================================================
_Tab="$(printf '\t')"
_StubBin="$_TmpDir/stubbin"
mkdir -p "$_StubBin"
cat > "$_StubBin/rsync" <<'STUB_EOF'
#!/bin/bash
# Test-Stub statt rsync. Zaehlt Versuche JE CHUNK (nicht global): bei parallelen
# Workern waere ein globaler Zaehler ein Wettlauf, und "genau ein Chunk muss
# wiederholt werden" liesse sich nicht reproduzierbar herstellen.
_D="$(dirname "$0")"
_Cf=""
for _A in "$@"; do
    case "$_A" in
        --files-from=*) _Cf="${_A#--files-from=}" ;;
    esac
done
_Base="$(basename "$_Cf")"
_N=0
[ -f "$_D/n.$_Base" ] && _N="$(cat "$_D/n.$_Base")"
_N=$((_N + 1))
printf '%s\n' "$_N" > "$_D/n.$_Base"
printf '%s\n' "$@" > "$_D/args.$_Base"
[ -f "$_D/sleep" ] && sleep "$(cat "$_D/sleep")"
# Signal-Tod statt Exit: BSD-xargs hoert danach auf, die Liste weiterzulesen.
# Kein "exit 137" - das waere ein normaler Exit-Code und traefe den Zweig nicht.
if [ -f "$_D/kill_self" ] && [ "$_Base" = "$(cat "$_D/kill_self")" ]; then
    # $PPID ist der Worker (die "bash -c", die w2u_run_chunk ausfuehrt), nicht
    # dieser Stub: sterben muss der WORKER, sonst faengt w2u_run_chunk den Tod
    # des rsync als gewoehnlichen rc ab und wiederholt ihn brav.
    kill -TERM "$PPID"
    sleep 5
fi
if [ -f "$_D/fail_once" ] && [ "$_Base" = "$(cat "$_D/fail_once")" ] && [ "$_N" -eq 1 ]; then
    echo "stub: erster Versuch fuer $_Base scheitert" >&2
    exit 23
fi
exit 0
STUB_EOF
chmod +x "$_StubBin/rsync"

_stub_reset() {
    rm -f "$_StubBin"/n.* "$_StubBin"/args.* "$_StubBin/fail_once" "$_StubBin/sleep" "$_StubBin/kill_self"
}

# 28 Chunks: 4 + 8 + 16 = genau der Bedarf der drei Probe-Runden
_ChunkDir2="$_TmpDir/chunks2"
mkdir -p "$_ChunkDir2"
: > "$_TmpDir/list2"
_I=1
while [ "$_I" -le 28 ]; do
    printf 'paket-%s\n' "$_I" > "$_ChunkDir2/$(printf 'chunk.r%04d' "$_I")"
    printf '%s\n' "$_ChunkDir2/$(printf 'chunk.r%04d' "$_I")" >> "$_TmpDir/list2"
    _I=$((_I + 1))
done

_RsyncBin="$_StubBin/rsync"
_MaxRetry=2
_RetryPause=0

# ---------------------------------------------------------------------------
# Echte Parallelitaet, an der Wanduhr gemessen. Ohne diese Assertion wuerde eine
# Mutation, die "-P $_Jobs" streicht (also seriell laeuft), gruen bleiben: das
# Ergebnis waere identisch, nur langsam. Parallelitaet ist aber der ganze Zweck
# dieses Tasks. Der Stub schlaeft 1 s je Chunk; 4 Chunks brauchen seriell >= 4 s.
# ---------------------------------------------------------------------------
_stub_reset
printf '1\n' > "$_StubBin/sleep"
head -n 4 "$_TmpDir/list2" > "$_TmpDir/list_timing"
_ResultFile="$_TmpDir/results_timing"; : > "$_ResultFile"
_T0="$(date +%s)"
w2u_run_list "$_TmpDir/list_timing" 4
_T1="$(date +%s)"
_ParDur=$((_T1 - _T0))
_stub_reset
printf '1\n' > "$_StubBin/sleep"
: > "$_ResultFile"
_T0="$(date +%s)"
w2u_run_list "$_TmpDir/list_timing" 1
_T1="$(date +%s)"
_SerDur=$((_T1 - _T0))
_stub_reset
[ "$_ParDur" -le 3 ] && _ParSchnell=ja || _ParSchnell=nein
t_assert_eq "ja" "$_ParSchnell" "4 Chunks a 1 s laufen mit -P 4 in <= 3 s (bekam ${_ParDur}s) - xargs parallelisiert wirklich"
[ "$_SerDur" -ge 4 ] && _SerLangsam=ja || _SerLangsam=nein
t_assert_eq "ja" "$_SerLangsam" "dieselben 4 Chunks brauchen mit -P 1 mindestens 4 s (bekam ${_SerDur}s) - die Messung oben ist kein Zufall"

# ---------------------------------------------------------------------------
# CONTROLLER-RULING 3: die Prozessgrenze liegt JE CHUNK. Ein global kaputtes
# _MaxRetry laesst jeden Worker per w2u_die sterben - der Lauf selbst darf davon
# NICHT mitgerissen werden, auch nicht unter dem "set -e" aus main().
#
# Die Assertion "so viele ABBRUCH-Meldungen wie Chunks" ist die eigentliche
# Pruefung: sie faellt (a) wenn xargs nach dem ersten toten Worker aufgibt und
# (b) wenn w2u_die im Kind gar nicht existiert, weil es nicht mitexportiert
# wurde - dann laeuft w2u_run_chunk am Guard vorbei ("command not found" ist
# rc 127, kein exit) und schreibt eine Ergebniszeile, die einen kaputten Chunk
# wie einen erledigten aussehen laesst. Genau nachgemessen und deshalb gepinnt.
# ---------------------------------------------------------------------------
head -n 5 "$_TmpDir/list2" > "$_TmpDir/list_r3"
_R3Result="$_TmpDir/results_r3"
: > "$_R3Result"
_R3Out="$(
    (
        set -e
        _MaxRetry="abc"
        _ResultFile="$_R3Result"
        w2u_run_list "$_TmpDir/list_r3" 4
        printf 'RUNNER_LIEF_WEITER rc=%s\n' "$?"
    ) 2>&1
)"
t_assert_contains "$_R3Out" "RUNNER_LIEF_WEITER rc=0" "ein global kaputtes _MaxRetry toetet nur die Worker, nicht den Lauf (Ruling 3, unter echtem set -e)"
t_assert_eq "5" "$(printf '%s\n' "$_R3Out" | grep -c 'ABBRUCH')" "jeder der 5 Chunks stirbt in seinem EIGENEN Prozess (xargs macht weiter; w2u_die ist im Kind wirklich vorhanden)"
[ -s "$_R3Result" ] && _R3Wrote=ja || _R3Wrote=nein
t_assert_eq "nein" "$_R3Wrote" "kein Worker hinterlaesst bei kaputter Konfiguration eine Ergebniszeile (die als Erfolg gelesen wuerde)"
_MaxRetry=2

# ---------------------------------------------------------------------------
# CONTROLLER-RULING 2 (Regression zur Messung im Report): der Append auf
# $_ResultFile haelt unter realer Parallelitaet. Gemessen wird NICHT nur die
# Zeilenzahl - oberhalb der Atomaritaetsgrenze zerreissen Zeilen, ohne dass sich
# die Zeilenzahl aendert (nachgemessen: bei 1029 Byte langen Zeilen blieben es
# 16000 Zeilen, aber nur 10643 davon waren unversehrt). Deshalb wird das FORMAT
# jeder Zeile geprueft.
# ---------------------------------------------------------------------------
_stub_reset
_ResultFile="$_TmpDir/results_append"; : > "$_ResultFile"
# Wie in test_transfer.sh: "$-" ohne Kommandosubstitution auswerten, weil bash
# errexit fuer die Dauer JEDER Substitution abschaltet und "$(set +o)" deshalb
# strukturell immer "errexit aus" meldet. w2u_run_list exportiert Variablen und
# Funktionen - die Shell-Optionen des Aufrufers darf es trotzdem nicht anfassen.
_OptsBefore="$-|$(set +o | grep -v ' errexit$')"
w2u_run_list "$_TmpDir/list2" "$_PMax"
_OptsAfter="$-|$(set +o | grep -v ' errexit$')"
t_assert_eq "$_OptsBefore" "$_OptsAfter" "Shell-Optionen der aufrufenden Shell unveraendert nach w2u_run_list"
t_assert_eq "28" "$(grep -c . "$_ResultFile")" "28 parallele Worker-Ergebnisse landen vollstaendig in der Ergebnisdatei"
t_assert_eq "0" "$(grep -cv "^chunk\.r[0-9][0-9]*${_Tab}[0-9][0-9]*${_Tab}[0-9][0-9]*$" "$_ResultFile" || true)" "keine Ergebniszeile ist durch parallelen Append zerrissen oder vermischt"
t_assert_eq "28" "$(cut -f1 "$_ResultFile" | sort -u | grep -c .)" "jeder Chunkname erscheint genau einmal (Identitaet, nicht nur Summe)"

# ---------------------------------------------------------------------------
# Die Liste der an die Worker exportierten Globals wird hier gepinnt, und zwar
# an dem, was im Kindprozess ANKOMMT. Ein Worker ist eine eigene Shell: was
# w2u_run_list nicht exportiert, ist dort schlicht leer - und zwar OHNE Fehler,
# weil in "bash -c" kein "set -u" gilt.
#
# Gemessen (und Grund fuer diese drei Assertions): faellt _RsyncTimeout aus der
# Exportliste, baut w2u_run_chunk "--timeout=" ohne Wert. GNU-rsync 3 schluckt
# das (rc 0, kein Timeout mehr - genau der Haenger, gegen den Task 6 gehaertet
# hat), openrsync lehnt es ab (rc 1, JEDER Chunk scheitert). Auf dieser Maschine
# waehlt w2u_find_rsync das Homebrew-rsync, der Daemon-Test oben bliebe also
# gruen - die Mutation wurde probeweise eingebaut und hat genau das getan.
# Dasselbe gilt fuer _ExcludeFrom (Ausschluesse wuerden stillschweigend
# uebertragen) und _LogDir (Logs landeten im Wurzelverzeichnis).
_TimeoutHits="$(grep -c -- "--timeout=$_RsyncTimeout" "$_StubBin/args.chunk.r0001" || true)"
t_assert_eq "1" "$_TimeoutHits" "der Worker bekommt --timeout MIT Wert ($_RsyncTimeout) - _RsyncTimeout ist wirklich exportiert"
# Kein --stats: seine Ausgabe liest niemand (gemessen wird ueber "du -sk", weil
# openrsync und GNU rsync verschiedene Stats-Formate schreiben - so steht es
# auch im Kopf von w2u_autotune). Eine Option im argv, deren Ausgabe niemand
# auswertet, verspricht dem naechsten Leser etwas, was nicht stimmt.
t_assert_eq "0" "$(grep -cx -- "--stats" "$_StubBin/args.chunk.r0001" || true)" "kein --stats im argv des Workers - die Ausgabe wuerde ohnehin niemand lesen"
t_assert_eq "0" "$(cut -f2 "$_ResultFile" | grep -vc '^0$' || true)" "kein Stub-Chunk mit Exit != 0 (belegt nebenbei, dass _LogDir im Worker gesetzt ist - sonst schlaege die Log-Umleitung fehl)"
[ -f "$_LogDir/chunk.r0001.1.log" ] && _LogDa=ja || _LogDa=nein
t_assert_eq "ja" "$_LogDa" "das Versuchs-Log liegt in \$_LogDir, nicht im Wurzelverzeichnis"

_stub_reset
_ExcludeFrom="$_TmpDir/excludes.txt"; : > "$_ExcludeFrom"
head -n 2 "$_TmpDir/list2" > "$_TmpDir/list_excl"
: > "$_ResultFile"
w2u_run_list "$_TmpDir/list_excl" 2
t_assert_eq "1" "$(grep -c -- "--exclude-from=$_ExcludeFrom" "$_StubBin/args.chunk.r0001" || true)" "der Worker bekommt --exclude-from - _ExcludeFrom ist wirklich exportiert (sonst wuerden Ausschluesse still uebertragen)"
_ExcludeFrom=""
_stub_reset

# ---------------------------------------------------------------------------
# Langer Chunkpfad. BSD-xargs begrenzt die "-I"-Ersetzung per Vorgabe auf
# 255 Byte (nachgemessen: 254 laeuft, 255 nicht) und bricht dann die GANZE
# restliche Liste ab - nicht nur den langen Eintrag. Der Chunkname selbst ist
# kurz ("chunk.aaaa"), erreichbar wird die Grenze ueber den Pfad des
# Arbeitsverzeichnisses; wo das produktiv liegt, entscheidet erst main().
# Deshalb steht hinter dem langen Chunk absichtlich noch ein kurzer: er belegt,
# dass die Liste weiterlaeuft statt an der Stelle abzureissen.
_LongDir="$_TmpDir/$(printf 'l%.0s' 1 2 3 4 5 6 7 8 9 0)$(printf 'a%.0s' 1 2 3 4 5)"
_I=0
while [ "$_I" -lt 12 ]; do
    _LongDir="$_LongDir/verzeichnisebene-mit-langem-namen-$_I"
    _I=$((_I + 1))
done
mkdir -p "$_LongDir/mit leerzeichen"
printf 'paket-lang\n' > "$_LongDir/mit leerzeichen/chunk.lang"
printf '%s\n' "$_LongDir/mit leerzeichen/chunk.lang" > "$_TmpDir/list_lang"
head -n 1 "$_TmpDir/list2" >> "$_TmpDir/list_lang"
_LongLen="$(printf '%s' "$_LongDir/mit leerzeichen/chunk.lang" | wc -c | tr -d ' ')"
[ "$_LongLen" -gt 255 ] && _LongOk=ja || _LongOk=nein
t_assert_eq "ja" "$_LongOk" "Testaufbau: der Chunkpfad ist wirklich laenger als die 255-Byte-Grenze von xargs (${_LongLen} Byte)"
_stub_reset
: > "$_ResultFile"
w2u_run_list "$_TmpDir/list_lang" 2
t_assert_eq "2" "$(grep -c . "$_ResultFile")" "ein Chunkpfad ueber 255 Byte wird uebertragen UND der Chunk dahinter ebenfalls (xargs reisst die Liste nicht ab)"
t_assert_eq "1" "$(cut -f1 "$_ResultFile" | grep -c '^chunk\.lang$')" "der lange Chunk selbst hat eine Ergebniszeile"

# ---------------------------------------------------------------------------
# GNU-userland: ein xargs OHNE "-S". Das ist die Regression zu dem Fehler, den
# die Suite auf einem Mac strukturell nicht sehen konnte - sie war gruen WEGEN
# der Plattform, nicht trotz ihr.
#
# "-S replsize" gibt es nur bei BSD/macOS-xargs. GNU-findutils kennt die Option
# gar nicht und bricht am Optionen-Parsen ab, also BEVOR ein Worker startet:
# auf jedem GNU/Linux-Ziel (README-Zusage) waere kein einziger Chunk
# uebertragen worden, der Sweep haette den Baum einstroemig nachgeholt, der
# Verify saehe sauber aus - und der Bericht meldete trotzdem FAIL, weil jedem
# Chunk die Ergebniszeile fehlt. Es faellt also sicher aus; die Parallelitaet,
# also der ganze Zweck dieses Werkzeugs, war auf Linux aber weg.
#
# Geprueft wird ueber einen xargs-ERSATZ im PATH, der "-S" genauso ablehnt wie
# GNU es tut und sonst an das echte xargs weiterleitet. Zwei Dinge machen den
# Test aussagekraeftig:
#   - der Aufbau wird selbst nachgemessen (der Ersatz muss "-S" wirklich
#     ablehnen, sonst pruefte der Test gegen nichts);
#   - die Chunkpfade sind KURZ. Der Ersatz delegiert an das echte BSD-xargs
#     ohne "-S", also gilt dessen 255-Byte-Grenze - mit dem langen Pfad von
#     oben schlaege der Test aus dem falschen Grund fehl.
# ---------------------------------------------------------------------------
_GnuXargsDir="$_TmpDir/gnu-xargs"
mkdir -p "$_GnuXargsDir"
# Das ECHTE xargs wird VOR der PATH-Aenderung gesucht und in den Ersatz
# eingebacken. Kein fester Pfad: "/usr/bin/xargs" stimmt auf macOS und den
# meisten Linuxen, aber nicht ueberall (NixOS hat unter /usr/bin nur env) - und
# ausgerechnet dieser Test soll das GNU-userland abdecken. Ein Ersatz, der den
# Weiterleitungspfad nicht findet, faellt aus einem Grund durch, der mit "-S"
# nichts zu tun hat.
_RealXargs="$(command -v xargs)"
[ -n "$_RealXargs" ] && _RealXargsOk=ja || _RealXargsOk=nein
t_assert_eq "ja" "$_RealXargsOk" "Testaufbau: das echte xargs ist im PATH gefunden ($_RealXargs)"
cat > "$_GnuXargsDir/xargs" <<GX_EOF
#!/bin/bash
# Ersatz fuer ein GNU-findutils-xargs: lehnt "-S" mit derselben Meldung und
# demselben rc ab und leitet alles andere an das echte xargs weiter. Der
# Weiterleitungspfad steht fest im Skript - ueber PATH fand dieser Ersatz sich
# selbst.
for _A in "\$@"; do
    case "\$_A" in
        -S|-S*)
            printf "xargs: invalid option -- 'S'\\n" >&2
            exit 1
            ;;
    esac
done
exec "$_RealXargs" "\$@"
GX_EOF
chmod +x "$_GnuXargsDir/xargs"

_SavePath="$PATH"
PATH="$_GnuXargsDir:$PATH"
_GnuProbeRc=0
printf 'x\n' | xargs -S 4096 -I {} true >/dev/null 2>&1 || _GnuProbeRc=$?
_GnuProbeOk=nein
[ "$_GnuProbeRc" -ne 0 ] && _GnuProbeOk=ja
t_assert_eq "ja" "$_GnuProbeOk" "Testaufbau: der xargs-Ersatz lehnt '-S' wirklich ab (rc $_GnuProbeRc) - sonst pruefte der Test gegen nichts"
_stub_reset
head -n 6 "$_TmpDir/list2" > "$_TmpDir/list_gnu"
_ResultFile="$_TmpDir/results_gnu"; : > "$_ResultFile"
_GnuOut="$(w2u_run_list "$_TmpDir/list_gnu" 3 2>&1)"
PATH="$_SavePath"
t_assert_eq "6" "$(grep -c . "$_ResultFile")" "mit einem xargs OHNE -S werden alle 6 Chunks abgearbeitet (auf GNU/Linux wuerde sonst KEIN Chunk laufen)"
t_assert_eq "0" "$(cut -f2 "$_ResultFile" | grep -vc '^0$' || true)" "und zwar fehlerfrei"
case "$_GnuOut" in
    *"xargs endete mit rc"*) _GnuWarn=ja ;;
    *)                       _GnuWarn=nein ;;
esac
t_assert_eq "nein" "$_GnuWarn" "kein xargs-Fehler-rc auf GNU-userland (die Option wird gemessen, nicht angenommen)"
_stub_reset

# ---------------------------------------------------------------------------
# Ungueltige Parallelitaet muss abgelehnt werden. "-P 0" heisst bei BSD-xargs
# UNBEGRENZT viele Prozesse - auf einer Quelle mit drehender Platte waere das
# das Gegenteil dessen, was die Messung erreichen soll.
# ---------------------------------------------------------------------------
_JobsRc=0
_JobsErr="$(w2u_run_list "$_TmpDir/list2" 0 2>&1)" || _JobsRc=$?
t_assert_eq "1" "$_JobsRc" "Parallelitaet 0 wird abgelehnt (BSD-xargs liest -P 0 als unbegrenzt)"
t_assert_contains "$_JobsErr" "ABBRUCH" "die Ablehnung ist sichtbar"
_JobsRc=0
_JobsErr="$(w2u_run_list "$_TmpDir/list2" "vier" 2>&1)" || _JobsRc=$?
t_assert_eq "1" "$_JobsRc" "nicht-numerische Parallelitaet wird abgelehnt"

# ---------------------------------------------------------------------------
# Eine FEHLENDE Chunkliste darf nicht wie eine LEERE aussehen. Leer ist legitim
# (chunks.rest nach einer Messung, die alles verbraucht hat) und bleibt still;
# fehlend oder unlesbar ist ein Defekt. Ohne die Trennung gaebe w2u_run_list
# stillschweigend 0 zurueck, w2u_run_all ebenfalls - ein Lauf, der NICHTS
# uebertragen hat, waere von einem vollstaendigen nicht zu unterscheiden.
# ---------------------------------------------------------------------------
_MissRc=0
_MissErr="$(w2u_run_list "$_TmpDir/gibt-es-nicht.list" 2 2>&1)" || _MissRc=$?
t_assert_eq "1" "$_MissRc" "eine nicht existierende Chunkliste bricht ab, statt still 0 zu liefern"

# Ein VERZEICHNIS vervollstaendigt das Trio, das dieser Guard trennen soll:
# fehlend / kaputt / leer. Es existiert (-e), ist lesbar (-r) und ist nicht leer
# (-s) - es kaeme also durch, xargs bekaeme null Chunks und der Lauf saehe wie
# "nichts mehr zu tun" aus. Genau das Bild, gegen das die zwei Zeilen darueber
# stehen.
_DirRc=0
_DirErr="$(w2u_run_list "$_TmpDir" 2 2>&1)" || _DirRc=$?
t_assert_eq "1" "$_DirRc" "ein VERZEICHNIS als Chunkliste bricht ab, statt als leere Liste durchzugehen"
t_assert_contains "$_DirErr" "keine regulaere Datei" "und nennt den Grund"
t_assert_contains "$_MissErr" "existiert nicht" "der Grund unterscheidet 'existiert nicht' von 'ist leer'"

: > "$_TmpDir/leer.list"
_EmptyRc=0
_EmptyErr="$(w2u_run_list "$_TmpDir/leer.list" 2 2>&1)" || _EmptyRc=$?
t_assert_eq "0" "$_EmptyRc" "eine LEERE Chunkliste bleibt still und liefert 0 - das ist der legitime Fall"
t_assert_eq "" "$_EmptyErr" "und sie erzeugt dabei keine Meldung"

if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - eine unlesbare Chunkliste ist wirkungslos"
else
    head -n 2 "$_TmpDir/list2" > "$_TmpDir/unlesbar.list"
    chmod 000 "$_TmpDir/unlesbar.list"
    _UnRc=0
    _UnErr="$(w2u_run_list "$_TmpDir/unlesbar.list" 2 2>&1)" || _UnRc=$?
    chmod 644 "$_TmpDir/unlesbar.list"
    t_assert_eq "1" "$_UnRc" "eine unlesbare Chunkliste bricht ab, statt still 0 zu liefern"
    t_assert_contains "$_UnErr" "nicht lesbar" "auch hier wird der Grund benannt"
fi

# ---------------------------------------------------------------------------
# Stirbt ein Worker durch ein SIGNAL (produktiv: OOM in Stunde drei), hoert
# BSD-xargs auf, die Liste weiterzulesen. w2u_run_list ist die einzige Stelle,
# die Eingabeliste UND Ergebnisdatei in der Hand hat - der Abgleich, WELCHE
# Chunks nie liefen, gehoert deshalb hierher und nicht in einen spaeteren
# Bericht, der den Bezug zu dieser Liste nicht mehr hat.
# ---------------------------------------------------------------------------
_stub_reset
printf '%s\n' "chunk.r0002" > "$_StubBin/kill_self"
_ResultFile="$_TmpDir/results_signal"; : > "$_ResultFile"
head -n 6 "$_TmpDir/list2" > "$_TmpDir/list_signal"
_SigOut="$(w2u_run_list "$_TmpDir/list_signal" 1 2>&1)"
_SigRc=$?
_stub_reset
t_assert_eq "0" "$_SigRc" "w2u_run_list liefert weiterhin 0 - der Lauf wird nicht abgerissen"
t_assert_contains "$_SigOut" "Signal-Tod" "die Warnung nennt die Ursachenklasse, statt sie einem spaeteren Task zu ueberlassen"
t_assert_contains "$_SigOut" "KEINE Ergebniszeile" "die nicht uebertragenen Chunks werden ausgewiesen"
_NichtGelaufen="$(cut -f1 "$_ResultFile" | sort > "$_TmpDir/gelaufen.txt"; sed 's|^.*/||' "$_TmpDir/list_signal" | sort | comm -23 - "$_TmpDir/gelaufen.txt")"
_FehltImText=ja
for _N in $_NichtGelaufen; do
    case "$_SigOut" in
        *"$_N"*) ;;
        *)       _FehltImText=nein ;;
    esac
done
t_assert_eq "ja" "$_FehltImText" "jeder Chunk ohne Ergebniszeile steht NAMENTLICH in der Warnung (nicht nur als Anzahl)"

# Haerterer Fall derselben Sache: der ERSTE Chunk stirbt, die Ergebnisdatei ist
# damit noch leer. Das uebliche awk-Idiom "NR == FNR" bricht genau hier - bei
# leerer erster Datei haelt es jede Zeile der Chunkliste fuer eine
# Ergebniszeile und meldet NICHTS als fehlend. Also der Fall, in dem am meisten
# fehlt, waere der einzige ohne Meldung gewesen.
_stub_reset
printf '%s\n' "chunk.r0001" > "$_StubBin/kill_self"
: > "$_ResultFile"
_Sig2Out="$(w2u_run_list "$_TmpDir/list_signal" 1 2>&1)"
_stub_reset
t_assert_eq "0" "$(grep -c . "$_ResultFile")" "Testaufbau: die Ergebnisdatei ist wirklich leer geblieben"
t_assert_contains "$_Sig2Out" "6 Chunk(s)" "bei leerer Ergebnisdatei werden ALLE 6 Chunks als fehlend gemeldet"
t_assert_contains "$_Sig2Out" "chunk.r0006" "und zwar auch der letzte, der nie gestartet wurde"

# Und der Fall, in dem die Ergebnisdatei gar nicht erst entsteht: dann darf der
# Abgleich nicht am fehlenden awk-Eingang scheitern und kommentarlos schweigen.
_stub_reset
printf '%s\n' "chunk.r0001" > "$_StubBin/kill_self"
_SavedResult="$_ResultFile"
_ResultFile="$_TmpDir/nie-erzeugt/results"
_Sig3Out="$(w2u_run_list "$_TmpDir/list_signal" 1 2>&1)"
_ResultFile="$_SavedResult"
_stub_reset
t_assert_contains "$_Sig3Out" "6 Chunk(s)" "auch ohne existierende Ergebnisdatei werden alle 6 Chunks als fehlend gemeldet"

_ResultFile="$_TmpDir/results_append"

# ---------------------------------------------------------------------------
# w2u_log in der Exportliste einzeln gepinnt. Die frueher benutzte Mutation
# entfernte w2u_die und w2u_log ZUSAMMEN - w2u_die toetete sie, und dass
# w2u_log ungedeckt war, blieb dahinter verborgen (dasselbe gegenseitige
# Abdecken wie bei den beiden Brauchbarkeitsschranken). w2u_log wird im Worker
# nur an einer Stelle gerufen: wenn das Anhaengen der Ergebniszeile scheitert.
# Genau die wird hier erzwungen.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - der Schreibschutz fuer den w2u_log-Pfad ist wirkungslos"
else
    _stub_reset
    mkdir -p "$_TmpDir/gesperrt"
    chmod 000 "$_TmpDir/gesperrt"
    _SavedResult="$_ResultFile"
    _ResultFile="$_TmpDir/gesperrt/results"
    head -n 2 "$_TmpDir/list2" > "$_TmpDir/list_log"
    _LogOut="$(w2u_run_list "$_TmpDir/list_log" 2 2>&1)"
    chmod 755 "$_TmpDir/gesperrt"
    _ResultFile="$_SavedResult"
    t_assert_contains "$_LogOut" "WARNUNG: Ergebniszeile" "der verlorene Schreibversuch wird im Worker gemeldet - w2u_log ist dort wirklich vorhanden"
    t_assert_eq "0" "$(printf '%s\n' "$_LogOut" | grep -c 'w2u_log: command not found' || true)" "und zwar ohne 'command not found' - ein nicht exportiertes w2u_log liefe wirkungslos durch"
fi

# ===========================================================================
# Teil 3 - gestellte Uhr und gestelltes du: die Entscheidungslogik der Messung
# wird exakt gepinnt, statt sie an echter Wanduhr zu erraten.
#
# date(1) und du(1) werden ueber PATH durch Stubs ersetzt, die einen
# vorgegebenen Plan abspielen. Nur so laesst sich pruefen, dass die 15-Prozent-
# Schwelle wirklich bei 15 Prozent liegt - eine echte Messung mit
# Sekundenaufloesung kann das prinzipiell nicht (und genau deshalb erklaert
# w2u_autotune zu kurze Runden fuer nicht verwertbar).
# ===========================================================================
_ClockBin="$_TmpDir/clockbin"
mkdir -p "$_ClockBin"
cat > "$_ClockBin/date" <<'DATE_EOF'
#!/bin/bash
# Gestellte Uhr: "+%s" liefert die naechste Zeile aus clock.plan, alles andere
# (w2u_log nutzt "+%H:%M:%S") geht ans echte date.
_D="$(dirname "$0")"
if [ "$1" = "+%s" ] && [ -f "$_D/clock.plan" ]; then
    _N=0
    [ -f "$_D/clock.n" ] && _N="$(cat "$_D/clock.n")"
    _N=$((_N + 1))
    printf '%s\n' "$_N" > "$_D/clock.n"
    _V="$(sed -n "${_N}p" "$_D/clock.plan")"
    if [ -n "$_V" ]; then
        printf '%s\n' "$_V"
        exit 0
    fi
    printf 'STUB: clock.plan erschoepft bei Aufruf %s\n' "$_N" >&2
fi
exec /bin/date "$@"
DATE_EOF
chmod +x "$_ClockBin/date"
cat > "$_ClockBin/du" <<'DU_EOF'
#!/bin/bash
# Gestelltes du: liefert die naechste Zeile aus du.plan als KB-Wert.
# Der Planwert "FEHLER" simuliert ein du, das gar keine Zahl liefert.
_D="$(dirname "$0")"
if [ -f "$_D/du.plan" ]; then
    _N=0
    [ -f "$_D/du.n" ] && _N="$(cat "$_D/du.n")"
    _N=$((_N + 1))
    printf '%s\n' "$_N" > "$_D/du.n"
    _V="$(sed -n "${_N}p" "$_D/du.plan")"
    if [ "$_V" = "FEHLER" ]; then
        echo "du: stub-fehler" >&2
        exit 1
    fi
    if [ -n "$_V" ]; then
        printf '%s\tziel\n' "$_V"
        exit 0
    fi
    printf 'STUB: du.plan erschoepft bei Aufruf %s\n' "$_N" >&2
fi
exec /usr/bin/du "$@"
DU_EOF
chmod +x "$_ClockBin/du"
cat > "$_ClockBin/tail" <<'TAIL_EOF'
#!/bin/bash
# Laesst tail auf Kommando scheitern. Nur so sind die tail-Fehlerpfade
# ueberhaupt erreichbar. w2u_autotune ruft tail an ZWEI Stellen (Restliste
# fortschreiben, Versuchszahlen der Runde lesen) - deshalb wird nicht pauschal
# gescheitert, sondern nur, wenn ein Argument das Muster aus "tail_fail_on"
# enthaelt. Sonst traefe immer der erste Aufruf und der zweite Pfad bliebe
# ungetestet.
_D="$(dirname "$0")"
if [ -f "$_D/tail_fail_on" ]; then
    _Pat="$(cat "$_D/tail_fail_on")"
    for _A in "$@"; do
        case "$_A" in
            *"$_Pat"*)
                echo "tail: stub-fehler ($_A)" >&2
                exit 1
                ;;
        esac
    done
fi
exec /usr/bin/tail "$@"
TAIL_EOF
chmod +x "$_ClockBin/tail"
cat > "$_ClockBin/head" <<'HEAD_EOF'
#!/bin/bash
_D="$(dirname "$0")"
if [ -f "$_D/head_fail" ]; then
    echo "head: stub-fehler" >&2
    exit 1
fi
exec /usr/bin/head "$@"
HEAD_EOF
chmod +x "$_ClockBin/head"
cat > "$_ClockBin/mv" <<'MV_EOF'
#!/bin/bash
_D="$(dirname "$0")"
if [ -f "$_D/mv_fail" ]; then
    echo "mv: stub-fehler" >&2
    exit 1
fi
exec /bin/mv "$@"
MV_EOF
chmod +x "$_ClockBin/mv"

_set_plan() {
    rm -f "$_ClockBin/clock.n" "$_ClockBin/du.n"
    printf '%s\n' $1 > "$_ClockBin/clock.plan"
    printf '%s\n' $2 > "$_ClockBin/du.plan"
}

# _PMax wird in mehreren Szenarien veraendert. EINE Quelle fuer den
# Ausgangswert statt geschachtelter Sicherungen: ein "_SavedPMax", das in
# einem Szenario einen bereits veraenderten Wert einfaengt, verschleppt ihn
# still in alle folgenden.
_PMaxOrig="$_PMax"
_OrigPath="$PATH"
PATH="$_ClockBin:$PATH"
export PATH

_ResultFile="$_TmpDir/results_tune"

# --- Szenario A: Durchsatz steigt deutlich -> Eskalation bis P=8 -------------
# Runden je 10 s; Zuwachs 200 -> 600 -> 1800 KB/s
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210 300 310" "0 2000 8000 26000"
_BestA="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneA.log")"
t_assert_eq "8" "$_BestA" "steigender Durchsatz eskaliert bis P=8"
t_assert_contains "$(cat "$_TmpDir/tuneA.log")" "gemessenes Optimum" "das Ergebnis wird als Messung ausgewiesen"
t_assert_eq "0" "$(grep -c . "$_TmpDir/chunks.rest")" "alle 28 Chunks wurden von den drei Probe-Runden als echte Arbeit verbraucht"
cat "$_TmpDir"/probe.* "$_TmpDir/chunks.rest" > "$_TmpDir/unionA"
t_assert_eq "$(sort "$_TmpDir/list2")" "$(sort "$_TmpDir/unionA")" "Szenario A: Probe-Runden plus Rest ueberdecken die Liste exakt"
t_assert_eq "28" "$(grep -c . "$_ResultFile")" "Szenario A: jeder Probe-Chunk wurde genau einmal uebertragen"

# --- Szenario B: Zuwachs unter 15 Prozent -> Abbruch, vorherige Stufe --------
# P=2: 2000 KB / 10 s = 200 ; P=4: 2100 KB / 10 s = 210 (nur +5 Prozent)
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 2000 4100"
_BestB="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneB.log")"
t_assert_eq "2" "$_BestB" "Zuwachs unter 15 Prozent beendet die Eskalation, gewaehlt wird die vorherige Stufe"
t_assert_contains "$(cat "$_TmpDir/tuneB.log")" "Eskalation endet" "der Abbruchgrund steht im Log"
t_assert_eq "16" "$(grep -c . "$_TmpDir/chunks.rest")" "nach dem Abbruch stehen die restlichen 16 Chunks in der Restliste"
# Dieses Szenario bricht VOR der dritten Runde ab, laeuft aber im selben
# Arbeitsverzeichnis wie Szenario A. Ohne das "rm -f probe.*" am Anfang von
# w2u_autotune stuende hier noch probe.8 aus Szenario A - der
# Vollstaendigkeitsbeweis wuerde 16 fremde Chunks mitzaehlen.
cat "$_TmpDir"/probe.* "$_TmpDir/chunks.rest" > "$_TmpDir/unionB"
t_assert_eq "$(sort "$_TmpDir/list2")" "$(sort "$_TmpDir/unionB")" "Szenario B: Probe-Runden plus Rest ueberdecken die Liste exakt, ohne Altlasten aus dem vorherigen Lauf"

# --- Szenario C: exakt an der Schwelle ---------------------------------------
# _BestRate 200 -> Schwelle ist "> 200 * 115 / 100 = 230", also echte 15
# Prozent. 231 muss eskalieren, 230 nicht. Pinnt die Arithmetik selbst - und
# damit auch, dass hier nicht mehr "+ _BestRate / 7" (14,3 Prozent) gerechnet
# wird, waehrend die Logzeile 15 Prozent behauptet.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210 300 310" "0 2000 4310 4320"
_BestC1="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneC1.log")"
t_assert_eq "4" "$_BestC1" "231 KB/s gegen 200 KB/s (knapp ueber 15 Prozent) eskaliert auf P=4"
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 2000 4300"
_BestC2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneC2.log")"
t_assert_eq "2" "$_BestC2" "230 KB/s gegen 200 KB/s liegt genau AUF der 15-Prozent-Schwelle und eskaliert nicht"
t_assert_contains "$(cat "$_TmpDir/tuneC2.log")" "mehr als 230 KB/s" "die Logzeile nennt die Schwelle, mit der wirklich gerechnet wurde"

# --- Szenario D: eine Runde mit Retry ist nicht verwertbar -------------------
# Die Retry-Pause von w2u_run_chunk steckt in der Wanduhr dieser Runde. Wer sie
# mitmisst, haelt eine langsame Windows-Datei fuer ein Parallelitaetslimit.
# Erwartung: Runde P=2 faellt raus (Arbeit bleibt erledigt), P=4 wird zur
# Referenz, P=8 bringt nichts -> Ergebnis 4.
_stub_reset
printf '%s\n' "chunk.r0001" > "$_StubBin/fail_once"
: > "$_ResultFile"
_set_plan "100 110 200 210 300 310" "0 5000 10000 12000"
_BestD="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneD.log")"
t_assert_eq "4" "$_BestD" "eine Runde mit Wiederholung zaehlt nicht als Messwert, die Eskalation laeuft trotzdem weiter"
t_assert_contains "$(cat "$_TmpDir/tuneD.log")" "wiederholt" "der Grund (Wiederholung) steht im Log"
t_assert_eq "1" "$(cut -f3 "$_ResultFile" | grep -cv '^1$' || true)" "Szenario D: genau eine Ergebniszeile weist mehr als einen Versuch aus - das ist das Signal, an dem die Runde verworfen wird"
_stub_reset

# --- Szenario D2: nur EINE verwertbare Runde ist kein Optimum ---------------
# _BestRate startet bei 0, die erste verwertbare Runde gewinnt den Vergleich
# also immer - auch wenn sie die einzige war. Der zurueckgegebene Wert ist dann
# in Ordnung (mehr Information gibt es nicht), die Beschriftung "gemessenes
# Optimum" waere es nicht: verglichen wurde nichts.
_PMax=4
_stub_reset
printf '%s\n' "chunk.r0001" > "$_StubBin/fail_once"
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 5000 10000"
_BestD2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneD2.log")"
_stub_reset
t_assert_eq "4" "$_BestD2" "Szenario D2: die einzige verwertbare Runde bestimmt den Wert"
t_assert_contains "$(cat "$_TmpDir/tuneD2.log")" "kein gemessenes Optimum" "Szenario D2: eine einzelne Runde wird NICHT als Optimum ausgegeben"
_PMax="$_PMaxOrig"

# --- Szenario E: du liefert keine Zahl --------------------------------------
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210 300 310" "FEHLER 2000 8000 26000"
_BestE="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneE.log")"
case "$_BestE" in
    2|4|8) _OkE=ja ;;
    *)     _OkE=nein ;;
esac
t_assert_eq "ja" "$_OkE" "ein du ohne Zahl fuehrt zu einer gueltigen Parallelitaet, nicht zu einem Arithmetikfehler (bekam: $_BestE)"
t_assert_contains "$(cat "$_TmpDir/tuneE.log")" "keine Zahl" "das fehlgeschlagene du wird benannt"
cat "$_TmpDir"/probe.* "$_TmpDir/chunks.rest" > "$_TmpDir/unionE"
t_assert_eq "$(sort "$_TmpDir/list2")" "$(sort "$_TmpDir/unionE")" "Szenario E: auch mit kaputter Messung geht kein Chunk verloren"

# --- Szenario E2: du liefert etwas, das keine Zahl ist ----------------------
# Nicht dasselbe wie ein du, das scheitert: hier kommt eine Ausgabe zurueck, sie
# ist nur unbrauchbar. Ohne die Zahlenpruefung in w2u_dst_kb liefe das in eine
# Arithmetik mit Text.
_PMax=2
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "kaputt 2000"
_BestE2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneE2.log")"
t_assert_eq "2" "$_BestE2" "eine nicht-numerische du-Ausgabe fuehrt zum Vorgabewert, nicht zu einer Rechnung mit Text"
t_assert_contains "$(cat "$_TmpDir/tuneE2.log")" "keine Zahl" "die unbrauchbare du-Ausgabe wird als solche benannt"
_PMax="$_PMaxOrig"

# --- Szenario I: das Fortschreiben der Restliste scheitert -------------------
# Der teuerste Fehlerpfad des ganzen Tasks. Die Chunks einer Probe-Runde
# verlassen die Restliste per "tail > .next" plus "mv". Wuerde der tail-Fehler
# verschluckt (im Plantext stand "|| true"), ersetzte das mv die Restliste durch
# eine LEERE Datei - der gesamte verbleibende Transfer waere still verschwunden,
# mit rc 0, und die Windows-Quelle wird danach verschrottet. Ohne einen tail, der
# auf Kommando scheitert, ist dieser Pfad nicht erreichbar; deshalb der Stub.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 5000"
printf '%s\n' "chunks.rest" > "$_ClockBin/tail_fail_on"
_TailRc=0
_TailErr="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _TailRc=$?
rm -f "$_ClockBin/tail_fail_on"
t_assert_eq "1" "$_TailRc" "ein fehlgeschlagenes Fortschreiben der Restliste bricht den Lauf ab (w2u_die), statt weiterzumachen"
t_assert_contains "$_TailErr" "Restliste" "der Abbruchgrund benennt die Restliste"
t_assert_eq "28" "$(grep -c . "$_TmpDir/chunks.rest")" "beim Abbruch ist die Restliste noch VOLLSTAENDIG - nicht durch einen halben Stand ersetzt"

# Zweite tail-Stelle: das Lesen der Versuchszahlen einer Runde. Als Pipeline
# (frueherer Stand) waere ein gescheitertes tail vom rc "kein Treffer" des grep
# nicht zu unterscheiden gewesen - die Runde haette als wiederholungsfrei
# gegolten und eine Runde voller Retry-Pausen als Messwert.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 5000"
printf '%s\n' "results_tune" > "$_ClockBin/tail_fail_on"
_Tail2Rc=0
_Tail2Err="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _Tail2Rc=$?
rm -f "$_ClockBin/tail_fail_on"
t_assert_eq "1" "$_Tail2Rc" "ein gescheitertes tail auf den Ergebniszeilen bricht ab, statt die Runde als wiederholungsfrei zu werten"
t_assert_contains "$_Tail2Err" "Ergebniszeilen der Probe-Runde" "der Abbruchgrund benennt die Ergebniszeilen"

# Dieselbe Stelle, andere Haelfte: scheitert das mv, bleibt die ALTE Restliste
# stehen. Ohne Abbruch liefe die Probe-Runde trotzdem, und die naechste Runde
# holte dieselben Chunks noch einmal - jeder davon wuerde zweimal uebertragen.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 5000"
: > "$_ClockBin/mv_fail"
_MvRc=0
_MvErr="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _MvRc=$?
rm -f "$_ClockBin/mv_fail"
t_assert_eq "1" "$_MvRc" "ein fehlgeschlagenes Ersetzen der Restliste bricht ab, statt Chunks doppelt uebertragen zu lassen"
t_assert_contains "$_MvErr" "Restliste" "auch hier benennt der Abbruchgrund die Restliste"

# Dritte Haelfte derselben Stelle: ein gescheitertes head hinterlaesst eine
# LEERE Probe-Datei - genau wie eine abgearbeitete Restliste. Ohne rc-Pruefung
# saehe der Defekt aus wie "fertig", und die Messung endete stillschweigend.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 5000"
: > "$_ClockBin/head_fail"
_HeadRc=0
_HeadErr="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _HeadRc=$?
rm -f "$_ClockBin/head_fail"
t_assert_eq "1" "$_HeadRc" "ein gescheitertes head auf der Restliste bricht ab, statt als 'Restliste abgearbeitet' gelesen zu werden"
t_assert_contains "$_HeadErr" "nicht lesbar" "der Abbruchgrund unterscheidet 'nicht lesbar' von 'fertig'"

# Konfigurationsschranken: _ProbeMinSecs ist zugleich die Zusicherung, dass die
# Durchsatzrechnung nie durch 0 teilt.
_SavedMinSecs="$_ProbeMinSecs"
_ProbeMinSecs=0
_CfgRc=0
_CfgErr="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _CfgRc=$?
_ProbeMinSecs="$_SavedMinSecs"
t_assert_eq "1" "$_CfgRc" "_ProbeMinSecs=0 bricht kontrolliert ab, statt spaeter durch 0 zu teilen"
t_assert_contains "$_CfgErr" "Division durch 0" "der Grund wird benannt"

# --- Szenario F und G: die beiden Brauchbarkeitsschranken einzeln -----------
# Beide Schranken haben sich in einer Mutationsprobe gegenseitig gedeckt: am
# echten Daemon ist eine Runde GLEICHZEITIG zu kurz und ohne uebertragene Bytes,
# eine entfernte Schranke faellt dort also nicht auf. Deshalb hier je ein Fall,
# in dem GENAU EINE Schranke greift, gepinnt an ihrer Begruendung im Log.
# _PMax=2 laesst nur eine einzige Runde laufen (pinnt nebenbei, dass _PMax die
# Eskalation ueberhaupt begrenzt).
_PMax=2

_stub_reset
: > "$_ResultFile"
_set_plan "100 102" "0 5000"
_BestF="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneF.log")"
t_assert_eq "2" "$_BestF" "Szenario F: eine 2-Sekunden-Runde liefert keinen Messwert, es bleibt beim Vorgabewert"
t_assert_contains "$(cat "$_TmpDir/tuneF.log")" "Mindestdauer" "Szenario F: als Grund steht die Mindestdauer im Log (die Uhr kann darunter keine 15 Prozent aufloesen)"
t_assert_contains "$(cat "$_TmpDir/tuneF.log")" "Vorgabewert" "Szenario F: das Ergebnis wird als Vorgabe und nicht als Messung ausgewiesen"

_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 500"
_BestG="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneG.log")"
t_assert_eq "2" "$_BestG" "Szenario G: 500 KB in 10 s sind zu wenig fuer eine Aussage, es bleibt beim Vorgabewert"
t_assert_contains "$(cat "$_TmpDir/tuneG.log")" "Mindestmenge" "Szenario G: als Grund steht die Mindestmenge im Log"
t_assert_eq "24" "$(grep -c . "$_TmpDir/chunks.rest")" "Szenario G: mit _PMax=2 laeuft genau eine Probe-Runde, 4 von 28 Chunks sind verbraucht"

# --- Szenario H: das Ziel schrumpft waehrend einer Runde --------------------
# Ein negatives du-Delta ist keine "0 KB"-Runde: es heisst, dass jemand anderes
# ans Ziel schreibt. Frueher stand hier ein stilles Klemmen auf 0 - das haette
# die Runde mit der falschen Begruendung verworfen, und keine Mutation haette es
# gemerkt (probeweise entfernt, Suite blieb gruen). Jetzt eigener Grund, eigener
# Test.
_PMax=4
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 5000 3000"
_BestH="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneH.log")"
t_assert_eq "2" "$_BestH" "Szenario H: die geschrumpfte Runde liefert keinen Messwert, es bleibt bei der vorherigen Stufe"
t_assert_contains "$(cat "$_TmpDir/tuneH.log")" "geschrumpft" "Szenario H: der Grund wird beim Namen genannt, statt als '0 KB' verkleidet zu werden"

# --- Szenario J: _PMax=1 laesst gar keine Runde zu --------------------------
# Der Vorgabewert 2 waere hier eine Parallelitaet, die die Konfiguration
# ausdruecklich ausschliesst.
_PMax=1
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "0 5000"
_BestJ="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneJ.log")"
t_assert_eq "1" "$_BestJ" "bei _PMax=1 kommt 1 zurueck, nicht der Vorgabewert 2"
t_assert_eq "28" "$(grep -c . "$_TmpDir/chunks.rest")" "bei _PMax=1 wird keine Probe-Runde gefahren, die Restliste ist die ganze Liste"
_PMax="$_PMaxOrig"

_CfgRc=0
_CfgErr="$(_PMax=0; w2u_autotune "$_TmpDir/list2" 2>&1)" || _CfgRc=$?
t_assert_eq "1" "$_CfgRc" "_PMax=0 bricht kontrolliert ab statt eine Parallelitaet zu liefern, die niemand wollte"
t_assert_contains "$_CfgErr" "_PMax" "der Grund benennt _PMax"

# --- Szenario K: keine Ergebnisdatei nach der Runde --------------------------
# Ohne Ergebnisdatei ist NICHT FESTSTELLBAR, ob wiederholt wurde - das ist etwas
# anderes als "es wurde nicht wiederholt". Hier zeigt $_ResultFile in ein
# Verzeichnis, das es nicht gibt: die Worker koennen nicht anhaengen (und melden
# das per w2u_log), die Datei entsteht nie.
_stub_reset
_SavedResult="$_ResultFile"
_ResultFile="$_TmpDir/gibtesnicht/results"
_set_plan "100 110 200 210 300 310" "0 5000 10000 26000"
_BestK="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneK.log")"
_ResultFile="$_SavedResult"
t_assert_contains "$(cat "$_TmpDir/tuneK.log")" "nicht feststellbar" "eine Runde ohne Ergebnisdatei liefert keinen Messwert, statt als wiederholungsfrei zu gelten"
case "$_BestK" in
    2|4|8) _OkK=ja ;;
    *)     _OkK=nein ;;
esac
t_assert_eq "ja" "$_OkK" "auch dabei kommt eine gueltige Parallelitaet zurueck (bekam: $_BestK)"

_PMax="$_PMaxOrig"

PATH="$_OrigPath"
export PATH

# ---------------------------------------------------------------------------
# Die Restliste ist die einzige Spur des noch nicht Uebertragenen. Laesst sie
# sich gar nicht erst anlegen, muss der Lauf abbrechen: eine fehlende oder leere
# Restliste sieht fuer alles Folgende aus wie "nichts mehr zu tun".
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - ein schreibgeschuetztes Arbeitsverzeichnis ist wirkungslos"
else
    _List2="$_TmpDir/list2"
    mkdir -p "$_TmpDir/nurlesen"
    chmod 500 "$_TmpDir/nurlesen"
    _RoRc=0
    _RoErr="$( ( _TmpDir="$_TmpDir/nurlesen"; w2u_autotune "$_List2" ) 2>&1 )" || _RoRc=$?
    chmod 700 "$_TmpDir/nurlesen"
    t_assert_eq "1" "$_RoRc" "eine nicht anlegbare Restliste bricht den Lauf ab, statt mit leerer Restliste weiterzumachen"
    t_assert_contains "$_RoErr" "Restliste" "der Abbruchgrund benennt die Restliste"
fi

# ===========================================================================
# Teil 4 - w2u_run_all
# ===========================================================================
_stub_reset
_ResultFile="$_TmpDir/results_all"; : > "$_ResultFile"
_JobCnt=3
w2u_run_all "$_TmpDir/list2" 2> "$_TmpDir/all1.log"
t_assert_contains "$(cat "$_TmpDir/all1.log")" "Auto-Messung uebersprungen" "--jobs N ueberspringt die Messung vollstaendig"
t_assert_eq "28" "$(grep -c . "$_ResultFile")" "bei fester Parallelitaet wird die GANZE Liste abgearbeitet, nicht die Restliste"
t_assert_eq "3" "$_JobCnt" "_JobCnt bleibt bei fester Parallelitaet unveraendert"

_stub_reset
: > "$_ResultFile"
_JobCnt=0
PATH="$_ClockBin:$PATH"
export PATH
_set_plan "100 110 200 210 300 310" "0 2000 8000 26000"
w2u_run_all "$_TmpDir/list2" 2> "$_TmpDir/all2.log"
PATH="$_OrigPath"
export PATH
t_assert_eq "8" "$_JobCnt" "_JobCnt traegt nach der Messung das Ergebnis, damit der Abschlussbericht es nennen kann"
t_assert_eq "28" "$(grep -c . "$_ResultFile")" "Messung plus Rest ergeben zusammen genau 28 Uebertragungen - kein Chunk doppelt, keiner ausgelassen"

# ---------------------------------------------------------------------------
# Alles bisher lief unter "set -uo pipefail" (Konfiguration dieses Testskripts).
# main() setzt zusaetzlich errexit. Unter -e reisst jedes unbehandelte
# Nicht-Null-Ergebnis den Lauf ab - etwa ein "grep -c", das bei leerer Datei 1
# liefert. Deshalb hier einmal der ganze Weg unter der ECHTEN Konfiguration.
# ---------------------------------------------------------------------------
_stub_reset
: > "$_ResultFile"
PATH="$_ClockBin:$PATH"
export PATH
_set_plan "100 110 200 210 300 310" "0 2000 8000 26000"
_EeOut="$(
    (
        set -euo pipefail
        _JobCnt=0
        w2u_run_all "$_TmpDir/list2"
        printf 'RUN_ALL_FERTIG jobs=%s\n' "$_JobCnt"
    ) 2>&1
)"
PATH="$_OrigPath"
export PATH
t_assert_contains "$_EeOut" "RUN_ALL_FERTIG jobs=8" "Messung plus Rest laufen vollstaendig unter der Shell-Konfiguration von main() (set -euo pipefail) durch"

_JobCnt=0
_RcAll=0
_ErrAll="$(_JobCnt="drei"; w2u_run_all "$_TmpDir/list2" 2>&1)" || _RcAll=$?
t_assert_eq "1" "$_RcAll" "nicht-numerisches _JobCnt bricht kontrolliert ab statt mit einem rohen Vergleichsfehler"

t_summary
