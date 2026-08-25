#!/usr/bin/env bash
# Prueft die AUSGELIEFERTEN Config-Bausteine der Windows-Seite gegen einen echten
# rsync-Daemon. Die .cmd laesst sich hier nicht ausfuehren - die von ihr erzeugte
# rsyncd.conf aber schon, und genau dort sitzen die teuren Fehler (Spec 2.5).
# Voraussetzung, die diesen Test ueberhaupt sinnvoll macht: der Test setzt die
# Config aus DENSELBEN Template-Dateien zusammen, die die .cmd liest. Wer die
# Templates in die .cmd inlinet, macht diesen Test wertlos.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi

# Fehlende Templates sind ein FEHLER, kein Skip: ohne sie ist die .cmd nicht
# lauffaehig, und ein gruener Lauf wuerde genau das verschweigen.
_Missing=nein
for _T in rsyncd.head.template rsyncd.module.template; do
    if [ -f "$_Root/windows/$_T" ]; then
        _Have=ja
    else
        _Have=nein
        _Missing=ja
    fi
    t_assert_eq "ja" "$_Have" "Template windows/$_T ist vorhanden"
done
if [ "$_Missing" = "ja" ]; then
    t_summary
fi

_Src="$(mktemp -d)"
_Src2="$(mktemp -d)"
_Dst="$(mktemp -d)"
_Cfg="$(mktemp -d)"
_Cfg2="$(mktemp -d)"
_Cfg3="$(mktemp -d)"

w_cleanup() {
    local _D _Pid
    for _D in "$_Cfg" "$_Cfg2" "$_Cfg3"; do
        _Pid="$(cat "$_D/rsyncd.pid" 2>/dev/null)"
        [ -n "$_Pid" ] && kill "$_Pid" 2>/dev/null
    done
    rm -rf "$_Src" "$_Src2" "$_Dst" "$_Cfg" "$_Cfg2" "$_Cfg3"
}
trap w_cleanup EXIT

# Quelle: eine sichtbare Datei plus genau die Namen, die serverseitig
# ausgeschlossen sein MUESSEN. "System Volume Information" enthaelt Leerzeichen -
# in rsyncd.conf ist exclude eine whitespace-getrennte Liste ohne Quoting,
# deshalb steht dort die Wildcard-Schreibweise (Controller-Ruling 1).
echo hallo > "$_Src/datei.txt"
mkdir -p "$_Src/System Volume Information"
echo geheim > "$_Src/System Volume Information/tracking.log.blf"
mkdir -p "$_Src/\$RECYCLE.BIN"
echo geloescht > "$_Src/\$RECYCLE.BIN/muell.txt"
echo auslagerung > "$_Src/pagefile.sys"
echo ruhezustand > "$_Src/hiberfil.sys"
echo swap > "$_Src/swapfile.sys"
echo dump > "$_Src/DumpStack.log.tmp"

# Startport aus der PID streuen statt fest: ein fester Port kollidiert bei
# schnell aufeinanderfolgenden Laeufen mit TIME_WAIT (gemessen in Task 4,
# siehe tests/lib/daemon.sh). Jeder w_start nimmt den naechsten freien.
_PortNext=$(( 8800 + ($$ % 150) ))
W_Port=""

# Baut die Config exakt so zusammen wie START-RSYNC-SERVER.cmd: Head-Template mit
# ersetztem @HOSTSALLOW@, dann je Laufwerk ein Modul-Template. port/address
# ergaenzt nur der Test - auf Windows gilt der Default 873 auf allen Adressen.
w_build_conf() {
    local _Dir="$1" _Port="$2"
    sed 's|@HOSTSALLOW@|127.0.0.1|' "$_Root/windows/rsyncd.head.template" > "$_Dir/rsyncd.conf"
    printf 'port = %s\naddress = 127.0.0.1\n' "$_Port" >> "$_Dir/rsyncd.conf"
    printf '\n' >> "$_Dir/rsyncd.conf"
    sed -e 's|@DRIVE@|c|' -e "s|@PATH@|$_Src|" -e 's|@LABEL@|Testlaufwerk|' \
        "$_Root/windows/rsyncd.module.template" >> "$_Dir/rsyncd.conf"
}

# Zweite Variante: so wie die .cmd es auf einer Maschine mit ZWEI Netzwerkkarten
# und ZWEI Platten schreibt - "hosts allow" als leerzeichengetrennte Subnetzliste
# und mehr als ein Modul-Block. Beides erzeugt nur die .cmd, die hier nicht
# laufen kann; die Form, in der sie es tut, ist damit trotzdem geprueft.
w_build_multi() {
    local _Dir="$1" _Port="$2"
    sed 's|@HOSTSALLOW@|10.0.0.0/24 127.0.0.0/24|' "$_Root/windows/rsyncd.head.template" > "$_Dir/rsyncd.conf"
    printf 'port = %s\naddress = 127.0.0.1\n' "$_Port" >> "$_Dir/rsyncd.conf"
    printf '\n' >> "$_Dir/rsyncd.conf"
    sed -e 's|@DRIVE@|c|' -e "s|@PATH@|$_Src|" -e 's|@LABEL@|System (120 GB)|' \
        "$_Root/windows/rsyncd.module.template" >> "$_Dir/rsyncd.conf"
    printf '\n' >> "$_Dir/rsyncd.conf"
    sed -e 's|@DRIVE@|d|' -e "s|@PATH@|$_Src2|" -e 's|@LABEL@|Daten (2000 GB)|' \
        "$_Root/windows/rsyncd.module.template" >> "$_Dir/rsyncd.conf"
}

# $1 = Arbeitsverzeichnis, $2 = "crlf" schreibt die Config mit CRLF-Zeilenenden.
# Setzt bei Erfolg W_Port. Der Daemon laeuft im Arbeitsverzeichnis, weil lock/pid/
# log im Head-Template RELATIV stehen - auf Windows ist das der Bundle-Ordner.
w_start() {
    local _Dir="$1" _Eol="${2:-lf}" _Build="${3:-w_build_conf}"
    local _I=0 _Port
    while [ "$_I" -lt 10 ]; do
        _Port="$_PortNext"
        _PortNext=$(( _PortNext + 1 ))
        _I=$(( _I + 1 ))
        rm -f "$_Dir/rsyncd.pid"
        "$_Build" "$_Dir" "$_Port"
        if [ "$_Eol" = "crlf" ]; then
            # awk statt sed: BSD-sed kennt kein \r im Ersetzungsteil.
            awk '{ printf "%s\r\n", $0 }' "$_Dir/rsyncd.conf" > "$_Dir/rsyncd.crlf"
            mv "$_Dir/rsyncd.crlf" "$_Dir/rsyncd.conf"
        fi
        # "< /dev/null" ist PFLICHT (Fund aus Task 4, siehe tests/lib/daemon.sh):
        # rsync --daemon prueft per getpeername(stdin), ob es aus inetd kommt. Ist
        # stdin ein SOCKET - jeder Agenten-/CI-Runner ohne Terminal -, geht es in
        # den inetd-Modus, daemonisiert nie, schreibt nie rsyncd.pid, und der Test
        # HAENGT statt zu scheitern. Gemessen: 38 s ohne eine einzige Assert-Zeile.
        # Ausgabe in eine DATEI, nicht in $(...): der abgeloeste Daemon erbt stdout
        # und haelt die Pipe offen - eine Kommandosubstitution wartet dann ewig.
        ( cd "$_Dir" && "$D_Bin" --daemon --config="$_Dir/rsyncd.conf" < /dev/null ) \
            > "$_Dir/start.err" 2>&1
        sleep 1
        if [ -f "$_Dir/rsyncd.pid" ]; then
            W_Port="$_Port"
            return 0
        fi
    done
    return 1
}

w_stop() {
    local _Dir="$1" _Pid
    _Pid="$(cat "$_Dir/rsyncd.pid" 2>/dev/null)"
    [ -n "$_Pid" ] && kill "$_Pid" 2>/dev/null
    rm -f "$_Dir/rsyncd.pid"
    return 0
}

# testlib hat bewusst kein assert_not_contains - hier gebraucht, deshalb lokal
# ueber t_assert_eq, damit Zaehler und Ausgabeformat gleich bleiben.
w_assert_absent() {
    local _Haystack="$1" _Needle="$2" _Label="$3" _Found
    case "$_Haystack" in
        *"$_Needle"*) _Found=ja ;;
        *)            _Found=nein ;;
    esac
    t_assert_eq "nein" "$_Found" "$_Label"
}

# Auch das ist ein FEHLER, kein Skip: rsync ist laut d_available daemon-faehig,
# also liegt es an der Config, wenn kein Daemon hochkommt.
if w_start "$_Cfg"; then
    _Started=ja
else
    _Started=nein
fi
t_assert_eq "ja" "$_Started" "Daemon startet mit der aus den Templates gebauten Config"
if [ "$_Started" = "nein" ]; then
    printf '       rsync sagte: [%s]\n' "$(cat "$_Cfg/start.err" 2>/dev/null)"
    t_summary
fi

_Out="$("$D_Bin" "rsync://127.0.0.1:$W_Port/" 2>&1)"
t_assert_contains "$_Out" "c " "Modul c wird gelistet"
t_assert_contains "$_Out" "Testlaufwerk" "Kommentar aus dem Template kommt an"

# Der eigentliche Punkt: max connections OHNE lock file bricht GENAU hier ab
# ("@ERROR: failed to open lock file"), waehrend das Modul-Listing oben noch
# funktioniert - Spec 2.5. Die zwei Einstellungen gehoeren zusammen.
_Out="$("$D_Bin" --list-only -r "rsync://127.0.0.1:$W_Port/c/" 2>&1)"
t_assert_contains "$_Out" "datei.txt" "Transfer-Pfad funktioniert, lock file ist korrekt gesetzt"

# Controller-Ruling 1: die Wildcard-Muster muessen ueber Leerzeichen hinweg
# greifen. Mit der Nicht-Wildcard-Form zerfaellt das Muster in drei nutzlose
# Woerter und der Ordner taucht hier wieder auf.
w_assert_absent "$_Out" "System Volume Information" "exclude greift trotz Leerzeichen im Namen"
# Nur $RECYCLE.BIN hat hier eine Fixture. Die zweite Schreibweise
# $Recycle.Bin liesse sich auf einem case-insensitiven Dateisystem gar nicht
# als zweiter Eintrag anlegen - sie steht im Template fuer NTFS-Namen, die
# Cygwin so ausliefert, und ist hier ehrlich ungetestet.
w_assert_absent "$_Out" "RECYCLE" "exclude haelt \$RECYCLE.BIN zurueck"
w_assert_absent "$_Out" "pagefile.sys" "exclude haelt pagefile.sys zurueck"
w_assert_absent "$_Out" "hiberfil.sys" "exclude haelt hiberfil.sys zurueck"
w_assert_absent "$_Out" "swapfile.sys" "exclude haelt swapfile.sys zurueck"
w_assert_absent "$_Out" "DumpStack.log" "exclude haelt DumpStack.log* zurueck"

# read only ist die einzige Sicherung dagegen, dass ein Fehlgriff auf der
# Unix-Seite die Quelle beschaedigt, bevor sie gesichert ist.
echo neu > "$_Cfg/neu.txt"
"$D_Bin" "$_Cfg/neu.txt" "rsync://127.0.0.1:$W_Port/c/" >/dev/null 2>&1
_Rc=$?
[ "$_Rc" -ne 0 ] && _RoOk=ja || _RoOk=nein
t_assert_eq "ja" "$_RoOk" "read only verhindert Schreibzugriff"

w_stop "$_Cfg"

# Die .cmd erzeugt die Config auf Windows. Ob rsync eine Config mit CRLF-Enden
# frisst, ist damit keine Geschmacksfrage - es entscheidet, ob der Server dort
# startet. Deshalb hier gemessen statt angenommen. (Die .cmd schreibt trotzdem
# LF, damit die Antwort nicht mehr traegt; ein Notepad-Save darf nichts kaputt
# machen, und dieser Test sagt, ob das stimmt.)
if w_start "$_Cfg2" crlf; then
    _Out="$("$D_Bin" --list-only -r "rsync://127.0.0.1:$W_Port/c/" 2>&1)"
    t_assert_contains "$_Out" "datei.txt" "Config mit CRLF-Zeilenenden funktioniert auch"
    "$D_Bin" -rt "rsync://127.0.0.1:$W_Port/c/datei.txt" "$_Dst/" >/dev/null 2>&1
    t_assert_eq "hallo" "$(cat "$_Dst/datei.txt" 2>/dev/null)" "echter Dateitransfer aus dem Modul"
    w_stop "$_Cfg2"
else
    t_skip "Daemon mit CRLF-Config startet nicht - Config MUSS dann LF haben"
fi

echo hallo > "$_Src2/zweitplatte.txt"
if w_start "$_Cfg3" lf w_build_multi; then
    _Out="$("$D_Bin" "rsync://127.0.0.1:$W_Port/" 2>&1)"
    t_assert_contains "$_Out" "System (120 GB)" "mehrere Module: c ist da"
    t_assert_contains "$_Out" "Daten (2000 GB)" "mehrere Module: d ist da"
    _Out="$("$D_Bin" --list-only -r "rsync://127.0.0.1:$W_Port/d/" 2>&1)"
    t_assert_contains "$_Out" "zweitplatte.txt" "Transfer aus Modul d, hosts allow mit zwei Subnetzen"
    w_stop "$_Cfg3"
else
    t_assert_eq "ja" "nein" "Daemon startet mit zwei Modulen und zwei Subnetzen in hosts allow"
    printf '       rsync sagte: [%s]\n' "$(cat "$_Cfg3/start.err" 2>/dev/null)"
fi

t_summary
