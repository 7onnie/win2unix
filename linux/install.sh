#!/usr/bin/env bash
# win2unix / linux/install.sh - richtet die Transfers als systemd-Dienste ein.
#
# Einmal mit sudo ausfuehren, danach braucht der Bediener kein Passwort mehr:
#   sudo bash linux/install.sh
# Erneut ausfuehren = aktualisieren (pull.sh und w2u werden ersetzt,
# Auftraege und Status bleiben).
#
# Legt an:
#   /opt/win2unix/pull.sh, /opt/win2unix/w2u, /usr/local/bin/w2u (Link)
#   /etc/systemd/system/win2unix@.service
#   /etc/win2unix/jobs/            (gehoert dem Bediener)
#   /var/lib/win2unix/             (root:<Gruppe des Bedieners>, 2775)
#   /etc/sudoers.d/win2unix        (systemctl auf win2unix@* ohne Passwort)
#
# Info, bewusst so: wer /etc/win2unix/jobs schreiben darf, bestimmt, was root
# holt und wem es danach gehoert. Der Bediener ist ohnehin Administrator.
set -euo pipefail

# ---- Konfiguration (Zero-Touch: hier aendern, keine Rueckfragen) ------------
_OpUser="${W2U_OP_USER:-${SUDO_USER:-}}"   # Bediener; leer = Abbruch
_Prefix=""                                 # --root DIR: alles unter DIR (Tests)
# -----------------------------------------------------------------------------

_Here="$(cd "$(dirname "$0")" && pwd)"
_Repo="$(cd "$_Here/.." && pwd)"

die() {
    printf 'ABBRUCH: %s\n' "$*" >&2
    exit 1
}
say() {
    printf '[+] %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) _Prefix="${2:?--root braucht ein Verzeichnis}"; shift 2 ;;
        --user) _OpUser="${2:?--user braucht einen Benutzer}"; shift 2 ;;
        *) die "unbekannte Option: $1" ;;
    esac
done

[ -n "$_OpUser" ] || die "Bediener unbekannt - mit sudo starten oder --user NAME angeben"
id "$_OpUser" >/dev/null 2>&1 || die "Benutzer $_OpUser gibt es nicht"
_OpGroup="$(id -gn "$_OpUser")"

if [ -z "$_Prefix" ]; then
    [ "$(id -u)" -eq 0 ] || die "als root ausfuehren: sudo bash $0"
    command -v systemctl >/dev/null 2>&1 || die "kein systemd (systemctl fehlt)"
fi
command -v python3 >/dev/null 2>&1 || die "python3 fehlt"
python3 -c 'import curses' 2>/dev/null || die "python3 ohne curses-Modul"
command -v rsync >/dev/null 2>&1 || die "rsync fehlt"
if [ -z "$_Prefix" ]; then
    rsync --help 2>&1 | grep -q -- '--chown' || die "rsync ohne --chown (GNU rsync >= 3.1 noetig)"
fi
_Systemctl="$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)"

_Opt="$_Prefix/opt/win2unix"
_Etc="$_Prefix/etc/win2unix"
_Var="$_Prefix/var/lib/win2unix"
_Unit="$_Prefix/etc/systemd/system/win2unix@.service"
_Sudo="$_Prefix/etc/sudoers.d/win2unix"
_Bin="$_Prefix/usr/local/bin"

say "Programme nach $_Opt"
mkdir -p "$_Opt" "$_Bin" "$(dirname "$_Unit")" "$(dirname "$_Sudo")"
# Ersetzen per mv: ein laufender Dienst liest pull.sh beim naechsten Start neu,
# ein halb geschriebenes Skript sieht er so nie.
install -m 0755 "$_Repo/pull.sh" "$_Opt/pull.sh.new"
mv -f "$_Opt/pull.sh.new" "$_Opt/pull.sh"
install -m 0755 "$_Here/w2u" "$_Opt/w2u.new"
mv -f "$_Opt/w2u.new" "$_Opt/w2u"
ln -sfn "/opt/win2unix/w2u" "$_Bin/w2u"
# Ausdruecklich 0755: unter sudo gilt oft eine strenge umask (gemessen: 0770),
# dann kaemen nur root und eine Gruppe an Programm und Auftraege.
chmod 0755 "$_Opt"

say "Dienst-Vorlage $_Unit"
install -m 0644 "$_Here/win2unix@.service" "$_Unit"

say "Auftraege $_Etc/jobs (gehoert $_OpUser)"
mkdir -p "$_Etc/jobs"
chmod 0755 "$_Etc"
if [ -z "$_Prefix" ]; then
    chown "$_OpUser:$_OpGroup" "$_Etc/jobs"
fi
chmod 0755 "$_Etc/jobs"

say "Status und Logs $_Var (root:$_OpGroup, 2775)"
mkdir -p "$_Var"
if [ -z "$_Prefix" ]; then
    chown "root:$_OpGroup" "$_Var"
fi
chmod 2775 "$_Var"

say "sudo-Regel $_Sudo (nur systemctl auf win2unix@*, ohne Passwort)"
_Tmp="$(mktemp)"
{
    printf '# win2unix: %s steuert die Transfer-Dienste ohne Passwort. Angelegt von install.sh.\n' "$_OpUser"
    printf '%s ALL=(root) NOPASSWD: %s enable --now win2unix@*, %s disable --now win2unix@*, %s restart win2unix@*, %s reset-failed win2unix@*, %s start win2unix@*, %s stop win2unix@*\n' \
        "$_OpUser" "$_Systemctl" "$_Systemctl" "$_Systemctl" "$_Systemctl" "$_Systemctl" "$_Systemctl"
} > "$_Tmp"
# Eine kaputte Datei in sudoers.d sperrt sudo fuer ALLE - vorher pruefen.
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$_Tmp" >/dev/null || { rm -f "$_Tmp"; die "sudo-Regel ungueltig (visudo -cf)"; }
fi
install -m 0440 "$_Tmp" "$_Sudo"
rm -f "$_Tmp"

if [ -z "$_Prefix" ]; then
    "$_Systemctl" daemon-reload
fi
say "fertig. Bedienung als $_OpUser: w2u   (TUI)  oder  w2u --help"
