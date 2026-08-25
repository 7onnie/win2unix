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
if [ -f "$_D/fail_once" ] && [ "$_Base" = "$(cat "$_D/fail_once")" ] && [ "$_N" -eq 1 ]; then
    echo "stub: erster Versuch fuer $_Base scheitert" >&2
    exit 23
fi
exit 0
STUB_EOF
chmod +x "$_StubBin/rsync"

_stub_reset() {
    rm -f "$_StubBin"/n.* "$_StubBin"/args.* "$_StubBin/fail_once" "$_StubBin/sleep"
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
[ "$_ParDur" -le 2 ] && _ParSchnell=ja || _ParSchnell=nein
t_assert_eq "ja" "$_ParSchnell" "4 Chunks a 1 s laufen mit -P 4 in <= 2 s (bekam ${_ParDur}s) - xargs parallelisiert wirklich"
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
# Laesst tail auf Kommando scheitern. Nur so ist der Fehlerpfad beim
# Fortschreiben der Restliste ueberhaupt erreichbar - er ist der teuerste im
# ganzen Task (siehe Kommentar am Aufruf).
_D="$(dirname "$0")"
if [ -f "$_D/tail_fail" ]; then
    echo "tail: stub-fehler" >&2
    exit 1
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
# _BestRate 200 -> Schwelle ist "> 200 + 200/7 = 228".
# 229 muss eskalieren, 228 nicht. Pinnt die Arithmetik selbst.
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210 300 310" "0 2000 4290 4300"
_BestC1="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneC1.log")"
t_assert_eq "4" "$_BestC1" "229 KB/s gegen 200 KB/s (+14,5 Prozent gerundet ueber der Schwelle) eskaliert auf P=4"
_stub_reset
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 2000 4280"
_BestC2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneC2.log")"
t_assert_eq "2" "$_BestC2" "228 KB/s gegen 200 KB/s liegt genau AUF der Schwelle und eskaliert nicht"

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
_SavedPMax="$_PMax"
_PMax=4
_stub_reset
printf '%s\n' "chunk.r0001" > "$_StubBin/fail_once"
: > "$_ResultFile"
_set_plan "100 110 200 210" "0 5000 10000"
_BestD2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneD2.log")"
_stub_reset
t_assert_eq "4" "$_BestD2" "Szenario D2: die einzige verwertbare Runde bestimmt den Wert"
t_assert_contains "$(cat "$_TmpDir/tuneD2.log")" "kein gemessenes Optimum" "Szenario D2: eine einzelne Runde wird NICHT als Optimum ausgegeben"
_PMax="$_SavedPMax"

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
_SavedPMax="$_PMax"
_PMax=2
_stub_reset
: > "$_ResultFile"
_set_plan "100 110" "kaputt 2000"
_BestE2="$(w2u_autotune "$_TmpDir/list2" 2> "$_TmpDir/tuneE2.log")"
t_assert_eq "2" "$_BestE2" "eine nicht-numerische du-Ausgabe fuehrt zum Vorgabewert, nicht zu einer Rechnung mit Text"
t_assert_contains "$(cat "$_TmpDir/tuneE2.log")" "keine Zahl" "die unbrauchbare du-Ausgabe wird als solche benannt"
_PMax="$_SavedPMax"

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
: > "$_ClockBin/tail_fail"
_TailRc=0
_TailErr="$(w2u_autotune "$_TmpDir/list2" 2>&1)" || _TailRc=$?
rm -f "$_ClockBin/tail_fail"
t_assert_eq "1" "$_TailRc" "ein fehlgeschlagenes Fortschreiben der Restliste bricht den Lauf ab (w2u_die), statt weiterzumachen"
t_assert_contains "$_TailErr" "Restliste" "der Abbruchgrund benennt die Restliste"
t_assert_eq "28" "$(grep -c . "$_TmpDir/chunks.rest")" "beim Abbruch ist die Restliste noch VOLLSTAENDIG - nicht durch einen halben Stand ersetzt"

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
_SavedPMax="$_PMax"
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

_PMax="$_SavedPMax"

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
