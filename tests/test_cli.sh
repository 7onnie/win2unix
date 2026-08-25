#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

# Laden im Library-Modus darf NICHTS ausfuehren, muss rc 0 liefern und die
# Funktionen tatsaechlich definieren (nicht nur eine leere/fehlende Datei durchwinken)
_Out="$(W2U_LIB_ONLY=1 bash -c '. "$1" && type -t w2u_usage >/dev/null && echo GELADEN' _ "$_Root/pull.sh" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "pull.sh laesst sich im Library-Modus laden"
t_assert_contains "$_Out" "GELADEN" "Library-Modus fuehrt main nicht aus und definiert Funktionen"

# Ohne Argumente: Usage und Exit 2
_Out="$(bash "$_Root/pull.sh" 2>&1)"; _Rc=$?
t_assert_rc 2 "$_Rc" "Aufruf ohne Argumente liefert rc 2"
t_assert_contains "$_Out" "Aufruf:" "Usage wird ausgegeben"

# ---------------------------------------------------------------------------
# Werkzeug fuer die folgenden Tests: ein rsync-ERSATZ. Die CLI-Tests brauchen
# keinen Daemon, sondern nur ein Programm, das sich wie rsync verhaelt:
#   --version    -> eine Versionszeile
#   --list-only  -> ein Listing mit GENAU EINER regulaeren Datei
#   -n           -> der Vergleichslauf des Verify; Ausgabe und rc kommen aus
#                   der Umgebung, damit ein Test "Befunde" erzeugen kann
# Die eine Datei im Listing ist Absicht: der Abschlussbericht vergleicht die
# entfernte Dateizahl gegen die lokale, und die Tests legen am Ziel genau eine
# Datei an. So ist der Dateizahl-Vergleich bindend UND deckungsgleich - ein
# FAIL in diesen Tests kommt dann nachweislich aus dem geprueften Grund und
# nicht aus einer nebenbei abweichenden Zahl.
# ---------------------------------------------------------------------------
_Tmp="$(mktemp -d "${TMPDIR:-/tmp}/w2u.cli.XXXXXXXX")"
trap 'd_stop; chmod -R u+w "$_Tmp" 2>/dev/null; rm -rf "$_Tmp"' EXIT
# Alles, was die Laeufe SELBST anlegen (Arbeits- und Logverzeichnisse), landet
# unter $_Tmp und wird damit vom Trap mitgeraeumt. Nicht Ordnungsliebe: seit dem
# Abschluss-Review bleiben Logverzeichnisse auch nach einem PASS liegen (sie sind
# der Nachweis), und diese Datei faehrt viele vollstaendige Laeufe - ohne die
# Umleitung blieben sie im echten TMPDIR des Entwicklers zurueck. Die
# feingranularen TMPDIR-Umleitungen einzelner Faelle weiter unten bleiben
# bestehen: die zaehlen, was in IHREM Verzeichnis liegt, und brauchen es
# deshalb leer.
export TMPDIR="$_Tmp/tmpdir"
mkdir -p "$TMPDIR"

_Fake="$_Tmp/fake-rsync"
cat > "$_Fake" <<'FAKE'
#!/usr/bin/env bash
_Mode=normal
for _A in "$@"; do
    case "$_A" in
        --version)
            printf 'openrsync: protocol version 29 (fake)\n'
            # Absichtlich VIEL mehr als ein Pipe-Puffer (~64 KB): wer die
            # Versionszeile wieder als "$(rsync --version | head -1)" liest,
            # bekommt hier zuverlaessig SIGPIPE, und unter dem pipefail aus
            # main() endet damit JEDER Lauf stumm mit rc 141 - genau der
            # Fehler, der gegen echtes rsync 3.5.0 auftrat. Ein Ersatz, der
            # nur eine kurze Zeile druckt, kann diese Mutation nicht fangen.
            # "exec": der Ersatz-Prozess MUSS selbst am SIGPIPE sterben, so wie
            # rsync es tut. Ein nachfolgendes "exit 0" wuerde den Signal-Tod des
            # Schreibers wieder zudecken (nachgemessen: damit lief die Mutation
            # gruen durch).
            exec seq 1 20000
            ;;
        --list-only) _Mode=list ;;
        -n)          _Mode=verify ;;
    esac
done
case "$_Mode" in
    list)
        printf 'drwxr-xr-x          4096 2026/01/01 12:00:00 .\n'
        printf -- '-rw-r--r--             5 2026/01/01 12:00:00 datei.txt\n'
        exit "${W2U_FAKE_LIST_RC:-0}"
        ;;
    verify)
        if [ -n "${W2U_FAKE_VERIFY_OUT:-}" ]; then
            printf '%s\n' "$W2U_FAKE_VERIFY_OUT"
        fi
        exit "${W2U_FAKE_VERIFY_RC:-0}"
        ;;
esac
exit 0
FAKE
chmod +x "$_Fake"

# Testsonde: laedt pull.sh als Bibliothek, ersetzt die schweren Funktionen
# durch Attrappen und faehrt dann main(). Damit sind Reihenfolge, Pfadwahl und
# Aufraeumen von main() ohne Daemon pruefbar. Mit W2U_PROBE_REPORT=real bleibt
# der ECHTE Abschlussbericht stehen - dann urteilt der Lauf wirklich.
_Probe="$_Tmp/probe.sh"
cat > "$_Probe" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
_Pull="$1"; shift
_State="$1"; shift
W2U_LIB_ONLY=1 . "$_Pull"

w2u_decompose() {
    if [ "${W2U_PROBE_DECOMPOSE_FAIL:-0}" = "1" ]; then
        w2u_die "Attrappe: Zerlegung scheitert"
    fi
    printf 'paket1\npaket2\n' > "$3"
}
w2u_chunk() {
    : > "$2/chunk.aaaa"
    printf '%s\n' "$2/chunk.aaaa" > "$4"
    _ChunkListFile="$4"
}
w2u_run_all() {
    if [ -e "$_ResultFile" ]; then
        printf 'RESULT_EXISTS=ja\n' >> "$_State"
    else
        printf 'RESULT_EXISTS=nein\n' >> "$_State"
    fi
    printf 'RESULT_LINES_BEFORE=%s\n' "$(grep -c . "$_ResultFile" 2>/dev/null || true)" >> "$_State"
    printf 'chunk.aaaa\t0\t1\n' >> "$_ResultFile"
}
w2u_sweep() {
    {
        printf 'TMPDIR=%s\n' "$_TmpDir"
        printf 'RESULTFILE=%s\n' "$_ResultFile"
        printf 'LOGDIR=%s\n' "$_LogDir"
        printf 'DSTROOT=%s\n' "$_DstRoot"
        printf 'SRCURL=%s\n' "$_SrcUrl"
    } >> "$_State"
    # Die Trapliste MUSS per Umleitung geschrieben werden. In einer
    # Kommandosubstitution oder einer Pipe laeuft "trap -p" in einer Subshell,
    # und bash setzt SIGINT dort auf die Vorgabe zurueck - die Liste saehe dann
    # so aus, als waere der INT-Trap nie gesetzt worden (nachgemessen).
    trap -p > "$_State.traps"
    return 0
}
w2u_verify() {
    if [ "${W2U_PROBE_VERIFY_FINDINGS:-0}" = "1" ]; then
        printf '>f.st...... datei.txt\n'
        return 1
    fi
    return 0
}
if [ "${W2U_PROBE_REPORT:-stub}" != "real" ]; then
    w2u_report() {
        printf 'VERIFYSTATE=%s\n' "$_VerifyState" >> "$_State"
        printf 'CHUNKLIST=%s\n' "$_ChunkListFile" >> "$_State"
        return 0
    }
fi
main "$@"
PROBE

# Liest einen Wert aus der Zustandsdatei einer Sonde.
_pval() {
    sed -n "s/^$2=//p" "$1" | tail -1
}
# "liegt <pfad> unterhalb von <basis> (oder ist sie selbst)?" -> ja/nein
_under() {
    case "$1/" in
        "$2"/*) printf 'ja\n' ;;
        *)      printf 'nein\n' ;;
    esac
}
# Setzt die Optionen auf die Vorgaben zurueck, damit ein w2u_parse_args-Aufruf
# im laufenden Testprozess nicht die Einstellung des vorherigen erbt.
_reset_opts() {
    _JobCnt=0
    # MUSS mit zurueckgesetzt werden: --jobs hebt _PMax an (Spec 5.3), und ein
    # angehobenes _PMax aus einem vorherigen Aufruf im selben Testprozess
    # verstellte die Zerlegung aller folgenden Faelle.
    _PMax=8
    _ExcludeFrom=""
    _LogDir=""
    _RsyncBin=""
    _DoVerify=1
    _VerifyOnly=0
    _DryRun=0
    _DoChecksum=0
    _SrcUrl=""
    _DstDir=""
    _DstRoot=""
}

# --- Zielpfad-Semantik (wie rsync) ---
W2U_LIB_ONLY=1 . "$_Root/pull.sh"
_DstBase="$(mktemp -d)"

w2u_parse_args "rsync://10.0.0.1/e/Archiv" "$_DstBase"
t_assert_eq "$_DstBase/Archiv" "$_DstRoot" "Quelle ohne Slash legt Unterordner an"

w2u_parse_args "rsync://10.0.0.1/e/Archiv/" "$_DstBase"
t_assert_eq "$_DstBase" "$_DstRoot" "Quelle mit Slash schreibt direkt ins Ziel"

w2u_parse_args --jobs 6 "rsync://10.0.0.1/e/Archiv" "$_DstBase"
t_assert_eq "6" "$_JobCnt" "--jobs wird uebernommen"

# --- --jobs hebt _PMax (Spec 5.3) --------------------------------------------
# P_max ist laut Spec 5.3 "Vorgabe 8 ODER der Wert aus --jobs", und an P_max
# haengen BEIDE Zahlen der Zerlegung: die Schwelle (4 * P_max) und der
# Chunk-Divisor. Fehlt die zweite Haelfte, setzt --jobs nur die Zahl der Worker,
# waehrend weiter fuer 8 zerlegt wird - bei der gemessenen Datenlage (Fall A,
# 308 Arbeitspakete) sind das 31 Chunks fuer 32 Worker. Weniger Chunks als
# Worker heisst: mindestens einer bekommt nichts, und Work-Stealing gibt es
# nicht mehr. Deshalb wird hier nicht nur _PMax geprueft, sondern die Folge
# daraus - die Chunkzahl gegen die Worker-Zahl.
_reset_opts
w2u_parse_args --jobs 32 "rsync://10.0.0.1/e/Archiv" "$_DstBase"
t_assert_eq "32" "$_PMax" "--jobs 32 hebt _PMax auf 32 (Spec 5.3)"
_JobsWork="$_Tmp/jobs.work"
: > "$_JobsWork"
_I=1
while [ "$_I" -le 308 ]; do
    printf 'paket %d\n' "$_I" >> "$_JobsWork"
    _I=$((_I + 1))
done
mkdir -p "$_Tmp/jobs.chunks"
w2u_chunk "$_JobsWork" "$_Tmp/jobs.chunks" "$_PMax" "$_Tmp/jobs.list" >/dev/null 2>&1
_JobsChunks="$(grep -c . "$_Tmp/jobs.list")"
t_assert_eq "103" "$_JobsChunks" "Fall A mit --jobs 32: 103 Chunks (mit ungehobenem _PMax waeren es 31)"
[ "$_JobsChunks" -gt "$_JobCnt" ] && _MehrAlsWorker=ja || _MehrAlsWorker=nein
t_assert_eq "ja" "$_MehrAlsWorker" "es gibt mehr Chunks ($_JobsChunks) als Worker ($_JobCnt) - sonst laeuft mindestens einer leer"

# Nur ANHEBEN: ein kleines --jobs darf die Zerlegung nicht groeber machen als
# die Vorgabe, sonst waere man wieder bei "4 Chunks fuer 8 Worker".
_reset_opts
w2u_parse_args --jobs 2 "rsync://10.0.0.1/e/Archiv" "$_DstBase"
t_assert_eq "8" "$_PMax" "--jobs 2 senkt _PMax NICHT unter die Vorgabe"

# Obergrenze: ohne sie waere "--jobs 10000" gueltig und startete 10000
# rsync-Prozesse gegen eine alte Windows-Kiste.
_reset_opts
# Gegen den rsync-Ersatz und ein vorhandenes Ziel, nicht gegen eine
# unerreichbare Quelle: sonst liefert der naechste Preflight-Check denselben
# rc 1 und eine entfernte Ablehnung faellt nicht auf. Als Trockenlauf, damit
# ohne die Ablehnung nicht wirklich 10000 Prozesse entstehen - der Trockenlauf
# endet ohne die Ablehnung mit rc 0.
_Out="$(bash "$_Root/pull.sh" --jobs 10000 --dry-run --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--jobs 10000 wird abgelehnt (ohne die Ablehnung liefe derselbe Aufruf auf rc 0)"
t_assert_contains "$_Out" "Obergrenze" "die Ablehnung nennt die Obergrenze"
_Out="$(bash "$_Root/pull.sh" --jobs 64 --dry-run --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "--jobs 64 (die Grenze selbst) bleibt erlaubt - die Ablehnung greift nicht zu weit"
_reset_opts

_Out="$(bash "$_Root/pull.sh" --jobs abc rsync://10.0.0.1/e/x /tmp 2>&1 || true)"
t_assert_contains "$_Out" "ABBRUCH" "nicht-numerisches --jobs bricht ab"

# --- Bootstrap: so, wie es im README steht, mit belegtem stdin ---
_Out="$(echo "STDIN-MUELL" | bash -c "$(cat "$_Root/pull.sh")" -- --version 2>&1)"
t_assert_contains "$_Out" "win2unix" "Bootstrap ueber bash -c \"\$(...)\" funktioniert bei belegtem stdin"

rm -rf "$_DstBase"

# --- Fehlendes Optionsargument ------------------------------------------------
# Zwei Formen, und beide muessen einzeln geprueft werden: die Option am ENDE
# der Befehlszeile (unter set -u sonst "unbound variable" mitten im Parser) und
# die Option, der eine weitere OPTION folgt (die wuerde sonst stillschweigend
# als Wert verschluckt). Wer nur eine Form prueft, laesst die andere offen.
_Out="$(bash "$_Root/pull.sh" rsync://10.0.0.1/e/x /tmp --jobs 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--jobs am Zeilenende bricht kontrolliert ab"
t_assert_contains "$_Out" "ABBRUCH" "--jobs am Zeilenende meldet ABBRUCH"
t_assert_contains "$_Out" "braucht ein Argument" "--jobs am Zeilenende nennt den Grund"

_Out="$(bash "$_Root/pull.sh" --jobs --dry-run rsync://10.0.0.1/e/x /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--jobs gefolgt von einer Option bricht ab, statt sie zu verschlucken"
t_assert_contains "$_Out" "--dry-run" "die verschluckte Option wird beim Namen genannt"
# Wichtig ist der GRUND: ohne die Pruefung auf ein fuehrendes "-" landete
# "--dry-run" als WERT in _JobCnt und stuerbe erst an der Zahlenpruefung - mit
# einer Meldung, die "--dry-run" ebenfalls enthaelt. Nur dieser Text
# unterscheidet die beiden Faelle.
t_assert_contains "$_Out" "braucht ein Argument" "und zwar als fehlendes Argument, nicht als kaputte Zahl"

_Out="$(bash "$_Root/pull.sh" rsync://10.0.0.1/e/x /tmp --log-dir 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "auch --log-dir am Zeilenende bricht ab"

# --- Ungueltige Argumente -----------------------------------------------------
_Out="$(bash "$_Root/pull.sh" --gibtsnicht rsync://10.0.0.1/e/x /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "unbekannte Option bricht ab"
t_assert_contains "$_Out" "unbekannte Option" "unbekannte Option wird benannt"

_Out="$(bash "$_Root/pull.sh" rsync://10.0.0.1/e/x /tmp /noch/eins 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "drittes Positionsargument bricht ab"

_Out="$(bash "$_Root/pull.sh" rsync://10.0.0.1/e/x 2>&1)"; _Rc=$?
t_assert_rc 2 "$_Rc" "fehlendes Zielverzeichnis-Argument liefert Usage und rc 2"
t_assert_contains "$_Out" "Aufruf:" "und zwar mit Usage"

_Out="$(bash "$_Root/pull.sh" /lokal/pfad /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Quelle ohne rsync:// bricht ab"

_Out="$(bash "$_Root/pull.sh" rsync://10.0.0.1/ /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Quelle ohne Modul bricht ab"
t_assert_contains "$_Out" "Modul" "Quelle ohne Modul nennt den Grund"

# --- Flag-Kombinationen: abgelehnt --------------------------------------------
# Alle vier werden beim ARGUMENT-PARSING abgelehnt, nicht nach Stunden Arbeit.
#
# WICHTIG fuer die Aussagekraft (Review-Fund): der rc allein pinnt eine
# Ablehnung nur dann, wenn der Lauf OHNE sie durchliefe. Zeigt der Test auf eine
# unerreichbare Quelle, liefert der naechste Preflight-Check denselben rc 1, und
# eine entfernte Ablehnung faellt nicht auf. Deshalb laufen die Kombinationen
# hier gegen den rsync-Ersatz und einen fertigen Zielbaum: ohne die Ablehnung
# erreichten sie rc 0 (Dateizahl remote 1 / lokal 1). Der Textassert bleibt als
# Guertel daneben.
printf 'Thumbs.db\n' > "$_Tmp/ex.txt"
mkdir -p "$_Tmp/dst-comb/Archiv"
printf 'inhalt\n' > "$_Tmp/dst-comb/Archiv/datei.txt"
_Out="$(bash "$_Root/pull.sh" --verify-only --no-verify rsync://10.0.0.1/e/x /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--verify-only + --no-verify wird abgelehnt (Ruling 4.1)"
t_assert_contains "$_Out" "--no-verify" "Ablehnung nennt beide Optionen"

_Out="$(bash "$_Root/pull.sh" --verify-only --exclude-from "$_Tmp/ex.txt" rsync://10.0.0.1/e/x /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--verify-only + --exclude-from wird sofort abgelehnt (Ruling 5)"
t_assert_contains "$_Out" "bindend" "Ablehnung erklaert die fehlende bindende Beweisschicht"

_Out="$(bash "$_Root/pull.sh" --verify-only --dry-run --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-comb" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--verify-only + --dry-run wird abgelehnt (zwei Betriebsarten)"
t_assert_contains "$_Out" "Betriebsarten" "und nennt den Grund - ohne die Ablehnung liefe derselbe Aufruf auf PASS"

_Out="$(bash "$_Root/pull.sh" --no-verify --checksum --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-comb" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--no-verify + --checksum wird abgelehnt (Wirkung widerspricht der Absicht)"
t_assert_contains "$_Out" "bewirkt --checksum NICHTS" "und sagt, warum - ohne die Ablehnung liefe derselbe Aufruf auf PASS"

# --- Flag-Kombinationen: erlaubt ----------------------------------------------
# Diese Kombinationen sind sinnvoll oder wenigstens harmlos und duerfen NICHT
# abgelehnt werden - eine Ablehnungsliste, die zu weit greift, macht das
# Werkzeug unbenutzbar.
_reset_opts
w2u_parse_args --verify-only --checksum "rsync://10.0.0.1/e/Archiv" /tmp
t_assert_eq "1 1" "$_VerifyOnly $_DoChecksum" "--verify-only + --checksum ist erlaubt"

_reset_opts
w2u_parse_args --no-verify --exclude-from "$_Tmp/ex.txt" "rsync://10.0.0.1/e/Archiv" /tmp 2>/dev/null
t_assert_eq "0" "$_DoVerify" "--no-verify + --exclude-from im vollen Lauf ist erlaubt"

_reset_opts
_Out="$(w2u_parse_args --dry-run --checksum "rsync://10.0.0.1/e/Archiv" /tmp 2>&1)"
t_assert_contains "$_Out" "WARNUNG" "im Trockenlauf wirkungslose Optionen warnen nur, statt abzulehnen"
_reset_opts

# --- Preflight ----------------------------------------------------------------
_Out="$(bash "$_Root/pull.sh" --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/gibtsnicht" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "fehlendes Zielverzeichnis bricht ab"
t_assert_contains "$_Out" "Zielverzeichnis" "fehlendes Zielverzeichnis wird benannt"

mkdir -p "$_Tmp/dst-unreach"
_Out="$(W2U_FAKE_LIST_RC=10 bash "$_Root/pull.sh" --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-unreach" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "nicht erreichbare Quelle bricht ab"
t_assert_contains "$_Out" "nicht erreichbar" "nicht erreichbare Quelle wird benannt"

mkdir -p "$_Tmp/dst-logs/Archiv"
_Out="$(bash "$_Root/pull.sh" --rsync "$_Fake" --log-dir "$_Tmp/dst-logs/Archiv/logs" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-logs" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--log-dir unterhalb des Zielverzeichnisses wird abgelehnt (Ruling 3)"

# --- main(): Ergebnisdatei, Logverzeichnis, Aufraeumen ------------------------
# TMPDIR umgebogen: dieser Lauf endet mit PASS, und seit dem Abschluss-Review
# BLEIBEN die Logs auch nach einem PASS liegen (sie sind der Nachweis, und auf
# ein PASS folgt das Verschrotten der Quelle). Ohne die Umleitung liesse jeder
# Suite-Lauf ein Logverzeichnis im echten TMPDIR zurueck.
mkdir -p "$_Tmp/dst-a" "$_Tmp/tmp-a"
_StateA="$_Tmp/state-a"
: > "$_StateA"
_Out="$(TMPDIR="$_Tmp/tmp-a" bash "$_Probe" "$_Root/pull.sh" "$_StateA" --jobs 2 --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-a" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "voller Lauf mit Attrappen endet mit rc 0"
_PTmp="$(_pval "$_StateA" TMPDIR)"
_PRes="$(_pval "$_StateA" RESULTFILE)"
_PLog="$(_pval "$_StateA" LOGDIR)"
_PDst="$(_pval "$_StateA" DSTROOT)"
t_assert_eq "$_Tmp/dst-a/Archiv" "$_PDst" "Zielwurzel wird aus Quelle ohne Slash gebildet"
t_assert_eq "ja" "$(_under "$_PRes" "$_PTmp")" "Ergebnisdatei liegt im lokalen Arbeitsverzeichnis (Ruling 1)"
t_assert_eq "nein" "$(_under "$_PRes" "$_PDst")" "Ergebnisdatei liegt NICHT unter dem Ziel (Ruling 1)"
t_assert_eq "nein" "$(_under "$_PLog" "$_PDst")" "Logverzeichnis liegt NICHT unter dem Ziel (Ruling 3)"
t_assert_eq "ja" "$(_pval "$_StateA" RESULT_EXISTS)" "Ergebnisdatei ist vor dem Lauf angelegt (Ruling 4.2)"
t_assert_eq "0" "$(_pval "$_StateA" RESULT_LINES_BEFORE)" "Ergebnisdatei ist vor dem Lauf leer (Ruling 4.3)"
t_assert_eq "sauber" "$(_pval "$_StateA" VERIFYSTATE)" "main haelt den Ausgang des Verify fest"
_PTraps="$(cat "$_StateA.traps")"
t_assert_contains "$_PTraps" "w2u_cleanup" "EXIT-Trap raeumt auf"
t_assert_contains "$_PTraps" "w2u_on_signal" "Signal-Trap ist gesetzt"
t_assert_contains "$_PTraps" "SIGINT" "INT wird abgefangen"
t_assert_contains "$_PTraps" "SIGTERM" "TERM wird abgefangen"
[ -d "$_PTmp" ] && _Left=ja || _Left=nein
t_assert_eq "nein" "$_Left" "Arbeitsverzeichnis ist nach dem Lauf entfernt"
# Umgekehrte Zusage seit dem Abschluss-Review: das Logverzeichnis BLEIBT auch
# nach einem erfolgreichen Lauf liegen. Vorher wurde es geloescht - samt
# verify.log, sweep.log und allen Chunk-Logs -, und der Bericht ging ohnehin nur
# aufs Terminal. Damit vernichtete das Werkzeug den Nachweis genau in dem Lauf,
# in dem er zaehlt: PASS ist die Freigabe, die Quellmaschine zu verschrotten.
[ -d "$_PLog" ] && _Left=ja || _Left=nein
t_assert_eq "ja" "$_Left" "selbst angelegtes Logverzeichnis BLEIBT nach einem erfolgreichen Lauf liegen (es ist der Nachweis)"
[ -f "$_PLog/report.txt" ] && _Left=ja || _Left=nein
t_assert_eq "ja" "$_Left" "der Abschlussbericht liegt als Datei im Logverzeichnis"
t_assert_contains "$_Out" "Logs und Bericht bleiben liegen" "und der Lauf sagt, wo"
t_assert_eq "0" "$(find "$_Tmp/dst-a" -type f | wc -l | tr -d ' ')" "der Lauf legt KEINE Dateien (Logs) im Ziel ab"

# --- Ruling 2: Befunde im Verify duerfen NIE zu PASS fuehren -------------------
# Zwei Laeufe, die sich in GENAU EINER Sache unterscheiden: ob der
# Vergleichslauf Befunde meldet. Alles andere (Chunk-Buchfuehrung, Dateizahl)
# ist in beiden Laeufen deckungsgleich - wer den Verify-Ausgang aus dem Bericht
# entfernt, bekommt zweimal PASS.
mkdir -p "$_Tmp/dst-b/Archiv" "$_Tmp/tmp-b"
printf 'inhalt\n' > "$_Tmp/dst-b/Archiv/datei.txt"
_Out="$(TMPDIR="$_Tmp/tmp-b" W2U_PROBE_REPORT=real bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-b" --jobs 2 --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-b" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "voller Lauf ohne Befunde meldet PASS"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Bericht meldet PASS, wenn wirklich nichts zu beanstanden ist"
# Der ECHTE Bericht (nicht die Attrappe) muss auch als Datei im Logverzeichnis
# stehen, mit demselben Ergebnis wie auf dem Terminal. Ein Nachweis, der nur im
# Scrollback existiert, ist nach dem Verschrotten der Quelle keiner.
_PLogB="$(_pval "$_Tmp/state-b" LOGDIR)"
t_assert_contains "$(cat "$_PLogB/report.txt" 2>&1)" "ERGEBNIS: PASS" "report.txt enthaelt denselben Bericht, den das Terminal zeigt"

# TMPDIR umgebogen: dieser Lauf endet absichtlich mit FAIL, und nach einem FAIL
# bleiben die Logs liegen (so soll es sein). Ohne die Umleitung liesse jeder
# Suite-Lauf ein Logverzeichnis im echten TMPDIR zurueck.
mkdir -p "$_Tmp/tmp-c"
_Out="$(TMPDIR="$_Tmp/tmp-c" W2U_PROBE_REPORT=real W2U_PROBE_VERIFY_FINDINGS=1 bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-c" --jobs 2 --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-b" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Befunde im Verify fuehren zu rc 1 (Ruling 2)"
case "$_Out" in
    *"ERGEBNIS: PASS"*) _Has=ja ;;
    *)                  _Has=nein ;;
esac
t_assert_eq "nein" "$_Has" "der BERICHT darf bei Verify-Befunden kein PASS drucken (Ruling 2)"
t_assert_contains "$_Out" "ERGEBNIS: FAIL" "Bericht meldet FAIL"

# --- --verify-only: echter Lauf gegen den rsync-Ersatz ------------------------
mkdir -p "$_Tmp/dst-v/Archiv" "$_Tmp/logs-v"
printf 'inhalt\n' > "$_Tmp/dst-v/Archiv/datei.txt"
_Out="$(bash "$_Root/pull.sh" --verify-only --rsync "$_Fake" --log-dir "$_Tmp/logs-v" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-v" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "sauberer --verify-only-Lauf meldet PASS (Ergebnisdatei wurde angelegt, Ruling 4.2)"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "--verify-only ohne Befunde druckt PASS"
# Der Bericht ueberlebt den Scrollback: er darf keine Parallelitaet nennen, die
# es in diesem Modus gar nicht gibt.
t_assert_contains "$_Out" "Parallelitaet   : entfaellt" "der Bericht behauptet im Verify-Only-Lauf keine Parallelitaet"

_Out="$(W2U_FAKE_VERIFY_OUT='>f.st...... datei.txt' bash "$_Root/pull.sh" --verify-only --rsync "$_Fake" --log-dir "$_Tmp/logs-v" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-v" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--verify-only mit Befunden meldet FAIL (Ruling 2)"
case "$_Out" in
    *"ERGEBNIS: PASS"*) _Has=ja ;;
    *)                  _Has=nein ;;
esac
t_assert_eq "nein" "$_Has" "--verify-only mit Befunden druckt KEIN PASS (Ruling 2)"
[ -s "$_Tmp/logs-v/verify.log" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "Befunde stehen im Logverzeichnis"
[ -d "$_Tmp/logs-v" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "ein selbst angegebenes --log-dir wird NIE geloescht"

# --- Bootstrap mit VOLLSTAENDIGEM Lauf und belegtem stdin ---------------------
# Der --version-Test oben zeigt nur, dass die Datei geladen wird - er kehrt im
# Parser um, bevor irgendetwas eine Datei liest. Hier laeuft die ganze
# Ablaufsteuerung (Preflight, Verify, Bericht) in der Form, die im README
# steht, mit einer Marke auf stdin: liest irgendwer im Lauf das geerbte stdin
# (unter dem Bootstrap ist das der Skript-Stream selbst), fehlt die Marke
# danach.
printf 'STDIN-MARKE\n' > "$_Tmp/stdin.txt"
_Out="$( { bash -c "$(cat "$_Root/pull.sh")" -- --verify-only --rsync "$_Fake" \
                   --log-dir "$_Tmp/logs-boot" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-v"
           printf 'RC=%s\n' "$?"
           printf 'REST=%s\n' "$(head -1)"; } < "$_Tmp/stdin.txt" 2>&1 )"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "vollstaendiger Lauf ueber den Bootstrap-Aufruf"
t_assert_contains "$_Out" "RC=0" "und mit rc 0"
t_assert_contains "$_Out" "REST=STDIN-MARKE" "niemand hat das geerbte stdin gelesen"

# --- Logverzeichnis nach einem Fehlschlag -------------------------------------
# Zwei Faelle, und sie muessen sich unterscheiden: nach einem Fehlschlag MIT
# Logs bleibt das Verzeichnis liegen (der Bericht verweist darauf), nach einem
# Fehlschlag OHNE Logs nicht (sonst bleibt bei jedem Fehlversuch ein leeres
# Verzeichnis stehen und die Meldung verspricht Logs, die es nicht gibt).
# TMPDIR wird umgebogen, damit gezaehlt werden kann, ohne fremde Laeufe zu
# treffen.
mkdir -p "$_Tmp/tmp-leer" "$_Tmp/dst-e"
_Out="$(TMPDIR="$_Tmp/tmp-leer" W2U_PROBE_DECOMPOSE_FAIL=1 bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-e" --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-e" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "gescheiterte Zerlegung bricht den Lauf ab"
t_assert_eq "0" "$(ls -A "$_Tmp/tmp-leer" | wc -l | tr -d ' ')" "nach einem Fehlschlag ohne Logs bleibt kein leeres Arbeits-/Logverzeichnis zurueck"

mkdir -p "$_Tmp/tmp-voll" "$_Tmp/dst-f/Archiv"
printf 'inhalt\n' > "$_Tmp/dst-f/Archiv/datei.txt"
_Out="$(TMPDIR="$_Tmp/tmp-voll" W2U_PROBE_REPORT=real W2U_PROBE_VERIFY_FINDINGS=1 bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-f" --jobs 2 --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-f" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "Lauf mit Verify-Befunden endet mit rc 1"
t_assert_eq "1" "$(ls -d "$_Tmp/tmp-voll"/win2unix-logs.* 2>/dev/null | wc -l | tr -d ' ')" "nach einem FAIL bleiben die Logs liegen - der Bericht verweist darauf"
[ -s "$_Tmp/tmp-voll"/win2unix-logs.*/verify.log ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "und sie enthalten den Befund"

# --- --dry-run ----------------------------------------------------------------
mkdir -p "$_Tmp/dst-d"
_StateD="$_Tmp/state-d"
: > "$_StateD"
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_StateD" --dry-run --rsync "$_Fake" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-d" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "--dry-run endet mit rc 0"
t_assert_contains "$_Out" "paket1" "--dry-run zeigt die Arbeitspakete"
[ -d "$_Tmp/dst-d/Archiv" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "--dry-run legt das Zielverzeichnis nicht an"

# ---------------------------------------------------------------------------
# Modulwurzel, Praefix und Ziel der parallelen Phase
#
# Gemessener Grund (Controller-Nachmessung zum Task-9-Befund): "--files-from"
# funktioniert gegen einen rsync-Daemon AUSSCHLIESSLICH mit der Modulwurzel als
# Quelle. Mit einem Unterpfad - dem dokumentierten Hauptfall - uebertraegt kein
# einziger Chunk etwas, und openrsync meldet dabei rc 0. Deshalb:
#   Quelle des Workers = Modulwurzel, Eintraege mit modul-relativem Praefix,
#   Ziel = _ParDst mit "_ParDst/<praefix> == _DstRoot".
# Geht diese Kuerzung nicht exakt auf, faellt die parallele Phase aus - LAUT,
# nicht still.
# ---------------------------------------------------------------------------
_reset_opts
w2u_parse_args "rsync://10.0.0.1/e/Archiv" "$_Tmp/ziel"
t_assert_eq "rsync://10.0.0.1/e" "$_ParSrc" "Worker-Quelle ist die Modulwurzel, nicht der Unterpfad"
t_assert_eq "Archiv" "$_SrcPrefix" "modul-relativer Praefix erkannt"
t_assert_eq "$_Tmp/ziel" "$_ParDst" "_ParDst/<praefix> ergibt _DstRoot"
t_assert_eq "parallel" "$_ParMode" "Hauptfall bleibt parallel"

_reset_opts
w2u_parse_args "rsync://10.0.0.1/e" "$_Tmp/ziel"
t_assert_eq "rsync://10.0.0.1/e" "$_ParSrc" "Quelle = Modulwurzel: Worker-Quelle unveraendert"
t_assert_eq "" "$_SrcPrefix" "kein Praefix"
t_assert_eq "$_Tmp/ziel/e" "$_ParDst" "ohne Praefix ist _ParDst gleich _DstRoot"
t_assert_eq "parallel" "$_ParMode" "Modulwurzel ist parallel uebertragbar"

_reset_opts
# Die Meldung wird in eine DATEI umgeleitet und von dort gelesen, nicht per
# Kommandosubstitution eingefangen: "$(w2u_parse_args …)" liefe in einer
# Subshell, und die gesetzten Variablen (_ParSrc, _SrcPrefix, _ParMode) kaemen
# hier nie an - die Asserts darunter pruefen dann Reste des VORIGEN Aufrufs.
# Genau diese Falle steckte unbemerkt im Block darunter (siehe dort).
w2u_parse_args "rsync://10.0.0.1:8873/e/Daten/Archiv" "$_Tmp/ziel" 2> "$_Tmp/hinweis.txt"
_Out="$(cat "$_Tmp/hinweis.txt")"
t_assert_eq "rsync://10.0.0.1:8873/e" "$_ParSrc" "Port bleibt in der Modulwurzel erhalten"
t_assert_eq "Daten/Archiv" "$_SrcPrefix" "mehrstufiger Praefix erkannt"
t_assert_eq "einstroemig" "$_ParMode" "tieferer Unterpfad: Kuerzung geht nicht auf, also einstroemig"
# Der Ratschlag in dieser Meldung muss zur Tiefe des Praefixes passen. Vor dem
# Fix nannte er '<ziel>' - also genau den Aufruf, der gerade abgelehnt wurde,
# und der Anwender landete beim zweiten Versuch wieder einstroemig (in Task 12
# gegen einen echten Daemon nachgemessen). Geprueft wird deshalb der
# Zwischenpfad im Vorschlag UND, dass dort kein "/." steht (die naheliegende
# dirname-Loesung liefert fuer ein einsegmentiges Praefix genau das).
t_assert_contains "$_Out" "<ziel>/Daten" "mehrstufiges Praefix: der Vorschlag nimmt den Zwischenpfad mit"
_HatPunkt=nein
case "$_Out" in
    *"<ziel>/."*) _HatPunkt=ja ;;
esac
t_assert_eq "nein" "$_HatPunkt" "der Vorschlag enthaelt kein '<ziel>/.'"

_reset_opts
# Auch hier in eine Datei statt in eine Substitution. Vorher stand hier ein
# "$(w2u_parse_args …)", und der _ParMode-Assert darunter pruefte in Wahrheit
# den Wert, den der VORIGE (nicht substituierte) Aufruf hinterlassen hatte -
# er war vakuum-gruen. Aufgefallen, als der Aufruf darueber ebenfalls eine
# Substitution wurde und dieser Assert plaetzlich fehlschlug.
w2u_parse_args "rsync://10.0.0.1/e/Archiv/" "$_Tmp/ziel" 2> "$_Tmp/hinweis.txt"
_Out="$(cat "$_Tmp/hinweis.txt")"
t_assert_eq "einstroemig" "$_ParMode" "Quelle MIT Schraegstrich: Kuerzung geht nicht auf"
t_assert_contains "$_Out" "EINSTROEMIG" "und der Anwender erfaehrt es SOFORT, nicht erst am Ende"
t_assert_contains "$_Out" "OHNE abschliessenden Schraegstrich" "die Meldung sagt auch, wie man volle Parallelitaet bekommt"
# Einsegmentiges Praefix: hier IST '<ziel>' der richtige Rat (nachgemessen),
# der Fix fuer den mehrstufigen Fall darf ihn nicht mit verschlimmern.
t_assert_contains "$_Out" "'pull.sh rsync://10.0.0.1/e/Archiv <ziel>'" "einsegmentiges Praefix: der Vorschlag bleibt '<ziel>'"

_reset_opts
w2u_parse_args "rsync://10.0.0.1/e/Archiv/" "$_Tmp/ziel/Archiv" 2>/dev/null
t_assert_eq "parallel" "$_ParMode" "Schraegstrich-Form mit spiegelndem Ziel bleibt parallel"
t_assert_eq "$_Tmp/ziel" "$_ParDst" "und _ParDst ist das gekuerzte Ziel"

_reset_opts
w2u_parse_args "rsync://10.0.0.1//e//Archiv" "$_Tmp/ziel"
t_assert_eq "rsync://10.0.0.1/e" "$_ParSrc" "doppelte Schraegstriche in der URL werden zusammengezogen"
t_assert_eq "Archiv" "$_SrcPrefix" "... und verfaelschen den Praefix nicht"
_reset_opts

# Einstroemig + fehlende Beweisschicht: dieselbe Klasse wie Ruling 5, nur mit
# der AUFRUFFORM als zweitem Faktor. Ohne Chunk-Buchfuehrung traegt nur noch
# der Dateizahl-Vergleich - faellt der auch weg, kann der Lauf nur FAIL melden.
_Out="$(bash "$_Root/pull.sh" --no-verify "rsync://10.0.0.1/e/Daten/Archiv" /tmp 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "einstroemig + --no-verify wird abgelehnt"
t_assert_contains "$_Out" "einstroemig" "die Ablehnung nennt die Aufrufform"

# Hier kann der rc allein NICHT unterscheiden: ohne die Ablehnung liefe dieser
# Aufruf die ganze Pruefzeit und meldete am Ende ebenfalls 1 - genau der
# stundenlange Umweg, den Ruling 5 verhindern soll. Unterscheidend ist deshalb,
# dass es GAR KEINEN Lauf gab: kein Abschlussbericht in der Ausgabe.
mkdir -p "$_Tmp/dst-ein-ex/Archiv"
printf 'inhalt\n' > "$_Tmp/dst-ein-ex/Archiv/datei.txt"
_Out="$(bash "$_Root/pull.sh" --exclude-from "$_Tmp/ex.txt" --rsync "$_Fake" "rsync://10.0.0.1/e/Daten/Archiv" "$_Tmp/dst-ein-ex" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "einstroemig + --exclude-from wird abgelehnt"
t_assert_contains "$_Out" "einstroemig" "die Ablehnung nennt die Aufrufform"
case "$_Out" in
    *Abschlussbericht*) _Has=ja ;;
    *)                  _Has=nein ;;
esac
t_assert_eq "nein" "$_Has" "und zwar SOFORT - es wurde nicht erst geprueft und dann FAIL gemeldet"

# --verify-only ist von der Aufrufform unabhaengig - es uebertraegt ohnehin
# nichts. Diese Kombination darf NICHT abgelehnt werden.
_reset_opts
w2u_parse_args --verify-only "rsync://10.0.0.1/e/Daten/Archiv" /tmp 2>/dev/null
t_assert_eq "1" "$_VerifyOnly" "--verify-only bleibt auch in der einstroemigen Aufrufform erlaubt"
_reset_opts

# Geprueft wird das Schreibrecht dort, wo die Worker WIRKLICH schreiben - und
# das ist das Zielverzeichnis, nicht der Vorfahre "$_ParDst". Die Dateien landen
# unter "_ParDst/<praefix>", und das IST $_DstRoot.
#
# Vorher stand die Pruefung auf dem Vorfahren, und sie war in BEIDE Richtungen
# falsch (im Abschluss-Review gefunden, hier in beiden Richtungen gepinnt):
#   a) ein nur-lesbarer VORFAHRE lehnte einen Lauf ab, der funktioniert haette -
#      mit --no-verify sogar per Abbruch statt per Warnung, weil ohne Zerlegung
#      keine bindende Beweisschicht bleibt;
#   b) ein nicht beschreibbares ZIEL fiel gar nicht auf, obwohl genau dort
#      geschrieben wird.
mkdir -p "$_Tmp/ro/Archiv"
chmod 500 "$_Tmp/ro"
if [ -w "$_Tmp/ro" ]; then
    t_skip "laeuft als root - ein nicht beschreibbares Elternverzeichnis ist so nicht herstellbar"
else
    # TMPDIR umgebogen: dieser Lauf endet mit FAIL (die Attrappe uebertraegt
    # nichts), und nach einem FAIL bleiben die Logs liegen - ohne die Umleitung
    # im echten TMPDIR des Anwenders.
    mkdir -p "$_Tmp/tmp-ro"
    _Out="$(TMPDIR="$_Tmp/tmp-ro" bash "$_Root/pull.sh" --rsync "$_Fake" "rsync://10.0.0.1/e/Archiv/" "$_Tmp/ro/Archiv" 2>&1 || true)"
    case "$_Out" in
        *EINSTROEMIG*) _Has=ja ;;
        *)             _Has=nein ;;
    esac
    t_assert_eq "nein" "$_Has" "a) nur-lesbarer VORFAHRE, beschreibbares Ziel: KEIN Rueckfall - dort schreibt niemand hinein"
    t_assert_contains "$_Out" "parallele Phase" "a) die parallele Phase laeuft"

    # b) Jetzt das ZIEL selbst. Erreichbar nur ohne abschliessenden
    # Schraegstrich an der Quelle: bei der Schraegstrich-Form ist $_DstRoot das
    # genannte Zielverzeichnis, und dessen Schreibrecht prueft der Preflight
    # schon weiter oben ab.
    mkdir -p "$_Tmp/ro2/Daten/Archiv" "$_Tmp/tmp-ro2"
    chmod 500 "$_Tmp/ro2/Daten/Archiv"
    _Out="$(TMPDIR="$_Tmp/tmp-ro2" bash "$_Root/pull.sh" --rsync "$_Fake" "rsync://10.0.0.1/e/Daten/Archiv" "$_Tmp/ro2/Daten" 2>&1 || true)"
    chmod 700 "$_Tmp/ro2/Daten/Archiv"
    t_assert_contains "$_Out" "EINSTROEMIG" "b) nicht beschreibbares ZIEL schaltet auf einstroemig um"
    t_assert_contains "$_Out" "nicht beschreibbar" "b) und nennt den Grund"
    # Der Rat muss zum Grund passen: hier stimmt der Zielpfad bereits, es fehlen
    # die Rechte - "waehle ein Ziel, das auf den Praefix endet" waere Unsinn.
    t_assert_contains "$_Out" "es fehlen die Rechte" "b) und einen Rat, der zum Grund passt"
    case "$_Out" in
        *"OHNE abschliessenden Schraegstrich"*) _Has=ja ;;
        *)                                      _Has=nein ;;
    esac
    t_assert_eq "nein" "$_Has" "b) und NICHT den Rat aus dem anderen Fall"
fi
chmod 700 "$_Tmp/ro"

# Verankerte Ausschlussmuster ("/Bild") gelten relativ zur Wurzel des
# Transfers - und die ist in der parallelen Phase die Modulwurzel, in
# Sweep/Verify aber $_SrcUrl. Mit modul-relativem Praefix meint dasselbe Muster
# also zwei Stellen. CONTROLLER-RULING: solche Laeufe werden ABGELEHNT, nicht
# per Umschreibung geradegebogen - ein daneben getroffenes Muster schliesst zu
# viel aus, und das ist Datenverlust.
mkdir -p "$_Tmp/dst-ex"
printf '/Bild\n' > "$_Tmp/anker.txt"
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-ex" --rsync "$_Fake" --exclude-from "$_Tmp/anker.txt" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-ex" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "verankertes Muster + modul-relativer Praefix wird ABGELEHNT"
t_assert_contains "$_Out" "VERANKERTE" "die Ablehnung benennt das Problem"
t_assert_contains "$_Out" "OHNE fuehrenden Schraegstrich" "und nennt den ersten Ausweg"
t_assert_contains "$_Out" "rsync://10.0.0.1/e" "und den zweiten: gegen die Modulwurzel laufen"

# Dieselbe Ausschlussdatei OHNE Praefix (Quelle ist die Modulwurzel): dort gibt
# es nur eine Wurzel, der Anker ist eindeutig - der Lauf muss durchgehen.
mkdir -p "$_Tmp/dst-ex-root"
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-ex-root" --rsync "$_Fake" --exclude-from "$_Tmp/anker.txt" rsync://10.0.0.1/e "$_Tmp/dst-ex-root" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "verankertes Muster OHNE Praefix bleibt erlaubt"

# Kommentare, Leerzeilen und Muster, die nur INNEN einen Schraegstrich haben,
# sind keine Anker - eine Datei daraus darf keinen Lauf kosten. ("Bild/x" ohne
# fuehrenden Schraegstrich vergleicht rsync gegen das Pfadende, also
# wurzelunabhaengig.)
printf '# /Bild\n; /Ton\n\n   \nThumbs.db\nBild/zwischenablage\n' > "$_Tmp/freimuster.txt"
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-ex2" --rsync "$_Fake" --exclude-from "$_Tmp/freimuster.txt" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-ex" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Kommentare, Leerzeilen und freie Muster werden NICHT als Anker missverstanden"
case "$_Out" in
    *VERANKERTE*) _Has=ja ;;
    *)            _Has=nein ;;
esac
t_assert_eq "nein" "$_Has" "und loesen die Meldung auch nicht aus"

# Im TROCKENLAUF wird dasselbe Muster nur GEWARNT: er uebertraegt nichts und
# faellt kein Urteil - dieselbe Trennlinie wie bei den Flag-Kombinationen.
_Out="$(bash "$_Root/pull.sh" --dry-run --rsync "$_Fake" --exclude-from "$_Tmp/anker.txt" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-ex" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Trockenlauf mit verankerten Mustern laeuft, statt abzulehnen"
t_assert_contains "$_Out" "VERANKERTE" "warnt aber, dass ein echter Lauf abgelehnt wuerde"

# --- Logverzeichnis: pruefen, BEVOR angelegt wird ----------------------------
# Ein abgelehntes --log-dir im Zielbaum darf nichts hinterlassen - und im
# Trockenlauf schon gar nicht, der legt grundsaetzlich nichts an. "mkdir -p"
# auf den Logpfad erzeugte sonst als Nebenwirkung auch das Zielverzeichnis.
mkdir -p "$_Tmp/dry-a"
_Out="$(bash "$_Root/pull.sh" --dry-run --rsync "$_Fake" --log-dir "$_Tmp/dry-a/Archiv/logs" rsync://10.0.0.1/e/Archiv "$_Tmp/dry-a" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "--log-dir im Zielbaum wird auch im Trockenlauf abgelehnt"
[ -e "$_Tmp/dry-a/Archiv" ] && _Has=ja || _Has=nein
t_assert_eq "nein" "$_Has" "und dabei wird NICHTS angelegt - weder Logverzeichnis noch Zielwurzel"

# ".." im Logpfad: der Vergleich muss KANONISCH stimmen, nicht lexikalisch -
# und zwar in BEIDE Richtungen. Beides ist reproduziert worden, deshalb steht
# beides hier: repariert jemand nur die eine Richtung, faellt die andere um.
mkdir -p "$_Tmp/dotdot/Archiv/x"
# (1) Die gefaehrliche Richtung: sieht lexikalisch nach "ausserhalb" aus, wird
#     von mkdir aber INNERHALB des verglichenen Baums angelegt - der Lauf
#     uebertruege stundenlang und fiele am Ende am Dateizahl-Vergleich um.
_Out="$(bash "$_Root/pull.sh" --rsync "$_Fake" --log-dir "$_Tmp/dotdot/foo/../Archiv/logs" rsync://10.0.0.1/e/Archiv "$_Tmp/dotdot" 2>&1)"; _Rc=$?
t_assert_rc 1 "$_Rc" "'..' im Logpfad, das kanonisch INS Ziel zeigt, wird abgelehnt"
t_assert_contains "$_Out" "im Zielbaum" "und zwar mit der Zielbaum-Begruendung"
# Der rc allein unterscheidet hier NICHT: ohne die Ablehnung laeuft der Transfer
# durch und faellt am Ende am Dateizahl-Vergleich ebenfalls auf 1 - genau der
# teure Weg, den die Pruefung abkuerzt. Unterscheidend ist, dass es keinen Lauf
# gab.
case "$_Out" in
    *Abschlussbericht*) _Has=ja ;;
    *)                  _Has=nein ;;
esac
t_assert_eq "nein" "$_Has" "und BEVOR uebertragen wird - nicht erst im Abschlussbericht"
# (2) Die andere Richtung: liegt kanonisch AUSSERHALB und muss durchgehen.
mkdir -p "$_Tmp/state-dd"
# "nichtda" existiert bewusst NICHT: liegt das ".." hinter einem existierenden
# Segment, loest schon der Existenztest des Betriebssystems alles auf, und der
# Fall waere keiner. Kanonisch zeigt der Pfad auf "$_Tmp/dotdot/logs-outside",
# also NEBEN das Ziel "$_Tmp/dotdot/Archiv".
_Out="$(bash "$_Probe" "$_Root/pull.sh" "$_Tmp/state-dd/s" --rsync "$_Fake" --log-dir "$_Tmp/dotdot/Archiv/nichtda/../../logs-outside" rsync://10.0.0.1/e/Archiv "$_Tmp/dotdot" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "'..' im Logpfad, das kanonisch AUS dem Ziel herausfuehrt, wird NICHT abgelehnt"
[ -d "$_Tmp/dotdot/logs-outside" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "und das Logverzeichnis entsteht dort, wo der Pfad kanonisch hinzeigt"

# Ein existierendes, aber schreibgeschuetztes Logverzeichnis: "mkdir -p" liefert
# dafuer 0. Ohne eigene Pruefung stuerbe der Lauf spaeter an einer Umleitung,
# und die Diagnose zeigte auf rsync statt auf das Logverzeichnis.
mkdir -p "$_Tmp/rolog" "$_Tmp/dst-rolog"
chmod 500 "$_Tmp/rolog"
if [ -w "$_Tmp/rolog" ]; then
    t_skip "laeuft als root - ein schreibgeschuetztes Logverzeichnis ist so nicht herstellbar"
else
    _Out="$(bash "$_Root/pull.sh" --rsync "$_Fake" --log-dir "$_Tmp/rolog" rsync://10.0.0.1/e/Archiv "$_Tmp/dst-rolog" 2>&1)"; _Rc=$?
    t_assert_rc 1 "$_Rc" "schreibgeschuetztes --log-dir bricht ab"
    t_assert_contains "$_Out" "Logverzeichnis nicht beschreibbar" "und die Meldung zeigt auf das Logverzeichnis, nicht auf rsync"
fi
chmod 700 "$_Tmp/rolog"

# ---------------------------------------------------------------------------
# Gegen einen ECHTEN Daemon: die parallele Phase muss DATEIEN liefern
#
# Der Bug, gegen den dieser Test steht, meldete rc 0 und uebertrug nichts. Ein
# Test, der nur den Rueckgabewert prueft, waere blind gewesen. Gezaehlt wird
# deshalb der Zielbaum, und zwar im Sweep - der Stelle GENAU zwischen
# paralleler Phase und der Reparatur, die den Ausfall sonst verdeckt.
# ---------------------------------------------------------------------------
if ! d_available; then
    t_skip "kein daemon-faehiges rsync - die Integrationstests der parallelen Phase brauchen einen"
else
    _ParProbe="$_Tmp/probe-par.sh"
    cat > "$_ParProbe" <<'PARPROBE'
#!/usr/bin/env bash
set -uo pipefail
_Pull="$1"; shift
_State="$1"; shift
W2U_LIB_ONLY=1 . "$_Pull"
# NUR der Sweep wird ersetzt - alles davor (Zerlegung, Chunks, paralleler
# Transfer) laeuft echt.
w2u_sweep() {
    {
        printf 'PARMODE=%s\n' "$_ParMode"
        printf 'PARSRC=%s\n' "$_ParSrc"
        printf 'PARDST=%s\n' "$_ParDst"
        printf 'PAR_FILES=%s\n' "$(find "$_DstRoot" -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf 'PAR_TREE=%s\n' "$( (cd "$_DstRoot" 2>/dev/null && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ') )"
    } >> "$_State"
    return 0
}
w2u_verify() { return 0; }
w2u_report() { return 0; }
main "$@"
PARPROBE

    _DSrc="$_Tmp/dsrc"
    mkdir -p "$_DSrc/Daten/BRIEFE/1" "$_DSrc/Daten/BRIEFE/2" "$_DSrc/Daten/Bild" "$_DSrc/Daten/leer"
    printf 'a\n' > "$_DSrc/Daten/BRIEFE/1/1 AC.DOC"
    printf 'b\n' > "$_DSrc/Daten/BRIEFE/2/2 AC.DOC"
    printf 'c\n' > "$_DSrc/Daten/BRIEFE/Größe & Maß.DOC"
    printf 'd\n' > "$_DSrc/Daten/Bild/direkt.txt"
    printf 'e\n' > "$_DSrc/Daten/oben.txt"

    if ! d_start "$_DSrc"; then
        t_skip "rsync-Daemon konnte nicht binden"
    else
        mkdir -p "$_Tmp/dst-par"
        _StateP="$_Tmp/state-par"
        : > "$_StateP"
        _Out="$(bash "$_ParProbe" "$_Root/pull.sh" "$_StateP" --jobs 2 "$D_Url/Daten" "$_Tmp/dst-par" 2>&1)"; _Rc=$?
        t_assert_rc 0 "$_Rc" "Hauptfall (Unterpfad-URL) laeuft durch"
        t_assert_eq "parallel" "$(_pval "$_StateP" PARMODE)" "Hauptfall uebertraegt parallel"
        t_assert_eq "5" "$(_pval "$_StateP" PAR_FILES)" "die parallele Phase hat wirklich DATEIEN geliefert - nicht bloss rc 0 gemeldet"
        t_assert_contains "$(_pval "$_StateP" PAR_TREE)" "BRIEFE/1/1 AC.DOC" "und zwar in der richtigen Struktur (kein doppelter Praefix)"
        [ -d "$_Tmp/dst-par/Daten/Daten" ] && _Has=ja || _Has=nein
        t_assert_eq "nein" "$_Has" "kein 'Daten/Daten' - _ParDst ist richtig gekuerzt"

        # Dasselbe mit OPENRSYNC als Client - der Vorgabe auf den Ziel-Macs und
        # genau der Fall, in dem der Ausfall LAUTLOS war (rc 0, null Dateien).
        # Nur die Dateizahl deckt ihn auf, kein Rueckgabewert.
        if [ -x /usr/bin/rsync ]; then
            mkdir -p "$_Tmp/dst-open"
            _StateO="$_Tmp/state-open"
            : > "$_StateO"
            _Out="$(bash "$_ParProbe" "$_Root/pull.sh" "$_StateO" --jobs 2 --rsync /usr/bin/rsync "$D_Url/Daten" "$_Tmp/dst-open" 2>&1)"; _Rc=$?
            t_assert_rc 0 "$_Rc" "Lauf mit openrsync als Client geht durch"
            t_assert_eq "5" "$(_pval "$_StateO" PAR_FILES)" "auch openrsync liefert in der parallelen Phase DATEIEN (mit dem Bug waeren es 0 bei rc 0)"
        else
            t_skip "kein /usr/bin/rsync (openrsync) vorhanden"
        fi

        # Vollstaendiger Lauf ohne Attrappen: derselbe Aufruf, den das README zeigt.
        mkdir -p "$_Tmp/dst-voll"
        _Out="$(bash "$_Root/pull.sh" --jobs 2 "$D_Url/Daten" "$_Tmp/dst-voll" 2>&1)"; _Rc=$?
        t_assert_rc 0 "$_Rc" "vollstaendiger Lauf gegen den echten Daemon endet mit PASS"
        t_assert_contains "$_Out" "ERGEBNIS: PASS" "und meldet PASS"
        t_assert_eq "5" "$(find "$_Tmp/dst-voll/Daten" -type f | wc -l | tr -d ' ')" "alle 5 Dateien am Ziel"
        [ -d "$_Tmp/dst-voll/Daten/leer" ] && _Has=ja || _Has=nein
        t_assert_eq "ja" "$_Has" "leeres Verzeichnis ueberlebt"

        # Rueckfall-Pfad: Quelle mit Schraegstrich, Ziel spiegelt den Pfad nicht.
        # Muss korrekt uebertragen UND sagen, dass es einstroemig laeuft.
        mkdir -p "$_Tmp/dst-ein"
        _Out="$(bash "$_Root/pull.sh" --jobs 2 "$D_Url/Daten/" "$_Tmp/dst-ein" 2>&1)"; _Rc=$?
        t_assert_rc 0 "$_Rc" "einstroemige Aufrufform endet ebenfalls mit PASS"
        t_assert_contains "$_Out" "einstroemig" "und sagt LAUT, dass nicht parallel uebertragen wird"
        t_assert_contains "$_Out" "Parallelitaet   : keine" "der Bericht widerspricht der Ansage nicht - er nennt keine Parallelitaet"
        t_assert_eq "5" "$(find "$_Tmp/dst-ein" -type f | wc -l | tr -d ' ')" "auch einstroemig kommen alle Dateien an"
        d_stop
    fi
fi

t_summary
