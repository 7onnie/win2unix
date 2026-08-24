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
            # Erst komplett in eine Variable einlesen, dann mit head/grep
            # pruefen: ein direktes "$_C --version | head -1 | grep ..." kann
            # unter set -o pipefail per SIGPIPE (rc 141) fehlschlagen, wenn
            # head die Pipe schliesst, bevor rsync alle Zeilen geschrieben hat.
            _V="$("$_C" --version 2>/dev/null)"
            if printf '%s\n' "$_V" | head -1 | grep -q '^rsync  *version 3'; then
                D_Bin="$_C"
                return 0
            fi
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
    D_Url="rsync://127.0.0.1:$D_Port/test"
}

d_stop() {
    [ -f "$D_Dir/rsyncd.pid" ] && kill "$(cat "$D_Dir/rsyncd.pid")" 2>/dev/null
    rm -rf "$D_Dir"
}
