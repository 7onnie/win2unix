#!/usr/bin/env bash
# Startet einen echten rsync-Daemon fuer Tests. Braucht ein rsync mit --daemon;
# Apple-openrsync kann das NICHT, deshalb wird sauber geskippt statt zu scheitern.

D_Port=8873
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
    cat > "$D_Dir/rsyncd.conf" <<EOF
use chroot = false
strict modes = false
max connections = 32
lock file = $D_Dir/rsyncd.lock
pid file = $D_Dir/rsyncd.pid
log file = $D_Dir/rsyncd.log
port = $D_Port
address = 127.0.0.1

[test]
    path = $_Serve
    read only = true
    list = yes
EOF
    "$D_Bin" --daemon --config="$D_Dir/rsyncd.conf"
    sleep 1
    # Ohne diese Pruefung wuerde ein verwaister Daemon aus einem
    # abgestuerzten Lauf, der Port 8873 noch haelt, den neuen Start
    # unbemerkt scheitern lassen (still kein Bind) - D_Url wuerde trotzdem
    # gesetzt, und alle folgenden Tests liefen gegen den alten Daemon mit
    # fremdem Datenbestand. Der Aufrufer muss bei rc 1 sauber skippen statt
    # weiterzumachen.
    if [ ! -f "$D_Dir/rsyncd.pid" ]; then
        return 1
    fi
    D_Url="rsync://127.0.0.1:$D_Port/test"
    return 0
}

d_stop() {
    [ -n "$D_Dir" ] || return 0
    [ -f "$D_Dir/rsyncd.pid" ] && kill "$(cat "$D_Dir/rsyncd.pid")" 2>/dev/null
    rm -rf "$D_Dir"
}
