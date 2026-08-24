#!/usr/bin/env bash
#
# win2unix / pull.sh - holt EINEN Ordner von einem Windows-rsync-Daemon.
#
# Aufruf:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh)" -- \
#        rsync://<WIN-IP>/e/Archiv /opt/data/files/
#
# NICHT "curl | bash" verwenden: dabei ist stdin der Skript-Stream, und die
# Datei-Listen wuerden den restlichen Skriptcode lesen.

W2U_VERSION="0.1.0"

# ---------- Konfiguration (Zero-Touch: alles hier, keine Rueckfragen) ----------
_JobCnt=0              # 0 = Auto-Messung (Spec 5.4)
_PMax=8                # hoechste Parallelitaet, die die Messung probiert
_MaxRetry=3
_RetryPause=5          # Sekunden, waechst linear mit dem Versuch
_ChunkMax=100          # Obergrenze Eintraege je Chunk (Spec 5.5)
_ThresholdFactor=4     # SCHWELLE = _ThresholdFactor * _PMax (Spec 5.3)
_MaxItems=200000       # Notbremse gegen explodierende Ebenen
_RsyncBin=""           # leer = automatisch suchen
_LogDir=""             # leer = unter dem Zielverzeichnis anlegen
_ExcludeFrom=""
_DoVerify=1
_VerifyOnly=0
_DryRun=0
_DoChecksum=0

# ---------- Laufzeit-Zustand ----------
_SrcUrl=""
_DstDir=""
_DstRoot=""
_TmpDir=""
_ResultFile=""
_StartTs=0

w2u_log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
w2u_warn() { printf '[%s] WARNUNG: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
w2u_die()  { printf '[%s] ABBRUCH: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

w2u_usage() {
    cat >&2 <<'EOF'
Aufruf: pull.sh [Optionen] rsync://<WIN-IP>/<modul>/<pfad> <zielverzeichnis>

  Quelle OHNE abschliessenden Slash  -> legt <zielverzeichnis>/<ordnername> an
  Quelle MIT abschliessendem Slash   -> schreibt den Inhalt direkt ins Ziel

Optionen:
  --jobs N            feste Parallelitaet, ueberspringt die Auto-Messung
  --exclude-from DATEI
  --log-dir PFAD
  --verify-only       nur pruefen, nichts uebertragen
  --no-verify         Verifikation ueberspringen (nicht empfohlen)
  --checksum          Verifikation zusaetzlich mit Pruefsummen (langsam)
  --dry-run           nur zeigen, was passieren wuerde
  --version
EOF
}

# Liest ein rsync-Listing von stdin, schreibt "TYP<TAB>NAME".
# Format ist immer: perms size YYYY/MM/DD HH:MM:SS name
# --out-format wird von openrsync im Listing-Modus ignoriert (Spec 2.2), deshalb
# wird geparst statt formatiert. Der Name ist ALLES nach dem Zeitstempel, sonst
# gehen Leerzeichen verloren. Keine Intervall-Quantoren: BSD-awk kann sie nicht.
w2u_parse_listing() {
    awk '
    {
        sub(/\r$/, "")
        if (match($0, / [0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] /) == 0) next
        _Name = substr($0, RSTART + RLENGTH)
        if (_Name == "." || _Name == "") next
        if (substr($0, 1, 1) == "d") {
            printf "d\t%s\n", _Name
        } else {
            printf "f\t%s\n", _Name
        }
    }'
}

# Sucht ein brauchbares rsync. Auf den Ziel-Macs ist das Apple-openrsync
# (Protokoll 29) - das reicht als CLIENT vollstaendig aus (Spec 2.2).
w2u_find_rsync() {
    if [ -n "$_RsyncBin" ]; then
        [ -x "$_RsyncBin" ] || w2u_die "kein ausfuehrbares rsync unter $_RsyncBin"
        return 0
    fi
    local _C
    for _C in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
        if [ -x "$_C" ]; then
            _RsyncBin="$_C"
            return 0
        fi
    done
    _RsyncBin="$(command -v rsync 2>/dev/null || true)"
    [ -n "$_RsyncBin" ] || w2u_die "kein rsync gefunden"
    return 0
}

# Listet GENAU EINE Ebene unterhalb von <basis>/<rel>.
#
# CONTROLLER-RULING: der rsync-Exit-Code darf nicht verworfen werden. Ein
# nicht lesbares Verzeichnis (rc 23, Permission denied) und ein wirklich
# leeres Verzeichnis (rc 0, Ausgabe nur der "."-Eintrag) erzeugen beide null
# geparste Zeilen - ueber die Zeilenzahl allein sind sie nicht zu
# unterscheiden. w2u_decompose (Task 4) wuerde "null Eintraege" sonst immer
# als leeres Verzeichnis behandeln und den kompletten Unterbaum stillschweigend
# aus der Arbeitsliste fallen lassen. Deshalb: rsync-Aufruf getrennt vom
# Parsen ausfuehren (Ausgabe erst in eine Variable), rc separat pruefen -
# "cmd | parser" wuerde ohnehin nur den rc des Parsers liefern, weil pipefail
# in gesourcten Test-Shells nicht aktiv ist.
#
# Fix (Review): "_Raw=$(...)" ist ein einfaches Kommando - unter set -e
# (aktiv in main()) feuert errexit GENAU an dieser Zuweisung, wenn rsync
# ungleich 0 endet, also bevor "_Rc=$?" gelesen und bevor w2u_die erreicht
# wird. Da stderr in _Raw umgeleitet ist statt aufs Terminal, geht die
# Diagnose mit der verworfenen Variable verloren, und der Aufrufer sieht nur
# ein nacktes rsync-rc ohne Meldung - besonders in Nicht-Substitutions-Form
# (Umleitung in eine Datei, Pipe), wie w2u_decompose (Task 4) sie
# voraussichtlich nutzt. "|| _Rc=$?" ist die dokumentierte errexit-Ausnahme
# und haelt den Aufruf am Leben, bis die rc-Pruefung unten laeuft.
w2u_remote_list() {
    local _Base="$1" _Rel="$2" _Url _Raw _Rc=0
    _Base="${_Base%/}"
    if [ -n "$_Rel" ]; then
        _Url="$_Base/$_Rel/"
    else
        _Url="$_Base/"
    fi
    _Raw="$("$_RsyncBin" --list-only -d "$_Url" 2>&1)" || _Rc=$?
    if [ "$_Rc" -ne 0 ]; then
        w2u_die "rsync-Listing fehlgeschlagen fuer $_Url (rc $_Rc): $_Raw"
    fi
    printf '%s\n' "$_Raw" | w2u_parse_listing
}

main() {
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        w2u_usage
        exit 2
    fi
    w2u_die "noch nicht implementiert"
}

[ "${W2U_LIB_ONLY:-0}" = "1" ] || main "$@"
