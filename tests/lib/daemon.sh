#!/usr/bin/env bash
# Startet einen echten rsync-Daemon fuer Tests. Braucht ein rsync mit --daemon;
# Apple-openrsync kann das NICHT, deshalb wird sauber geskippt statt zu scheitern.

D_Port=8873    # Fallback-Anzeige vor dem ersten d_start; d_start waehlt den
               # tatsaechlich gebundenen Port neu (per $$ + Nachbarn-Fallback)
               # und ueberschreibt diese Variable mit dem echten Wert.
D_Url=""
D_Dir=""
D_Bin=""

d_available() {
    local _C _V
    for _C in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
        if [ -x "$_C" ]; then
            # Komplett in eine Variable einlesen und per case pruefen statt
            # zu pipen: ein direktes "$_C --version | head -1 | grep ..."
            # kann unter set -o pipefail per SIGPIPE (rc 141) fehlschlagen,
            # wenn head die Pipe schliesst, bevor rsync alle Zeilen
            # geschrieben hat. Ueber eine Variable plus case ist die ganze
            # SIGPIPE-Klasse strukturell unmoeglich, nicht nur umgangen.
            _V="$("$_C" --version 2>/dev/null)"
            case "$_V" in
                "rsync  version 3"*)
                    D_Bin="$_C"
                    return 0
                    ;;
            esac
        fi
    done
    return 1
}

d_start() {
    D_Dir="$(mktemp -d)"
    local _Serve="$1"
    local _Base _I _Cand
    # Fester Port 8873 war die eigentliche Fehlerursache, nicht der
    # sleep 1: bei schneller Wiederholung (mehrere Suite-Laeufe kurz
    # hintereinander, oder mehrere Tasks/Testdateien, die diesen Harness
    # nutzen) haelt TCP TIME_WAIT den zuletzt genutzten Port noch belegt,
    # auch nachdem der Daemon-Prozess schon beendet ist - der naechste
    # d_start auf demselben festen Port scheitert dann zuverlaessig am
    # Bind. Deshalb: Startpunkt ueber $$ (PID dieses Testprozesses) auf
    # einen Bereich verteilen, damit unabhaengige Laeufe selten denselben
    # Port wollen, UND ein paar Nachbarports als Fallback durchprobieren,
    # falls der gewaehlte trotzdem belegt ist (z.B. TIME_WAIT von einem
    # ANDEREN Lauf, der zufaellig auf den gleichen Startpunkt kam).
    _Base=$(( 8800 + ($$ % 150) ))
    _I=0
    while [ "$_I" -lt 10 ]; do
        _Cand=$(( _Base + _I ))
        rm -f "$D_Dir/rsyncd.pid"
        cat > "$D_Dir/rsyncd.conf" <<EOF
use chroot = false
strict modes = false
max connections = 32
lock file = $D_Dir/rsyncd.lock
pid file = $D_Dir/rsyncd.pid
log file = $D_Dir/rsyncd.log
port = $_Cand
address = 127.0.0.1

[test]
    path = $_Serve
    read only = true
    list = yes
EOF
        # "< /dev/null" ist PFLICHT, nicht Kosmetik (Fund in Task 4, zweimal
        # reproduziert): rsync --daemon prueft per getpeername(stdin), ob es aus
        # inetd gestartet wurde. Ist stdin ein SOCKET, geht es NICHT in den
        # Standalone-Modus, sondern bedient stdin als waere es eine eingehende
        # Verbindung - es daemonisiert nie, schreibt nie rsyncd.pid, und d_start
        # laeuft durch alle zehn Kandidatenports und HAENGT dann. Im Log steht
        # dann "malformed address" plus "connect from UNKNOWN ()". Betroffen ist
        # jede Aufrufumgebung mit Socket-stdin (Agenten-/CI-Runner, die die Suite
        # nicht von einem Terminal starten). Ein haengender Harness ist teurer
        # als ein fehlschlagender: er blockiert und liefert nicht mal ein
        # Fehlerbild. Nicht entfernen.
        "$D_Bin" --daemon --config="$D_Dir/rsyncd.conf" < /dev/null
        sleep 1
        # Bind-Check aus Ruling 2 bleibt unveraendert bestehen: ohne ihn
        # wuerde ein verwaister Daemon aus einem abgestuerzten Lauf den
        # neuen Start unbemerkt scheitern lassen (still kein Bind), D_Url
        # waere trotzdem gesetzt, und alle folgenden Tests liefen gegen den
        # alten Daemon mit fremdem Datenbestand. Hier entscheidet er
        # zusaetzlich, ob der naechste Kandidatenport probiert wird.
        if [ -f "$D_Dir/rsyncd.pid" ]; then
            D_Port="$_Cand"
            D_Url="rsync://127.0.0.1:$D_Port/test"
            return 0
        fi
        _I=$((_I + 1))
    done
    # Alle Kandidaten belegt oder Bind sonst gescheitert - der Aufrufer muss
    # sauber skippen statt weiterzumachen.
    return 1
}

d_stop() {
    [ -n "$D_Dir" ] || return 0
    [ -f "$D_Dir/rsyncd.pid" ] && kill "$(cat "$D_Dir/rsyncd.pid")" 2>/dev/null
    rm -rf "$D_Dir"
}
