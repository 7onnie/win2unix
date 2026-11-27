#!/usr/bin/env bash
# linux/install.sh im Testmodus (--root DIR): legt alles unter DIR an, ohne
# root, ohne systemd. Geprueft werden Dateien, Rechte und die sudo-Regel.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

_T="$(mktemp -d)"
trap 'rm -rf "$_T"' EXIT
_Me="$(id -un)"

_Out="$(bash "$_Root/linux/install.sh" --root "$_T" --user "$_Me" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "install.sh --root laeuft durch"
for _F in opt/win2unix/pull.sh opt/win2unix/w2u etc/systemd/system/win2unix@.service etc/sudoers.d/win2unix; do
    [ -f "$_T/$_F" ] && _Has=ja || _Has=nein
    t_assert_eq "ja" "$_Has" "$_F angelegt"
done
[ -x "$_T/opt/win2unix/w2u" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "w2u ausfuehrbar"
[ -L "$_T/usr/local/bin/w2u" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "/usr/local/bin/w2u ist ein Link"
_Mode="$(stat -c %a "$_T/var/lib/win2unix" 2>/dev/null || stat -f %p "$_T/var/lib/win2unix" | sed 's/.*\(....\)$/\1/')"
t_assert_eq "2775" "$_Mode" "Statusverzeichnis 2775"
t_assert_eq "440" "$(stat -f %Lp "$_T/etc/sudoers.d/win2unix" 2>/dev/null || stat -c %a "$_T/etc/sudoers.d/win2unix")" "sudo-Regel 0440"
_Rule="$(cat "$_T/etc/sudoers.d/win2unix")"
t_assert_contains "$_Rule" "$_Me ALL=(root) NOPASSWD:" "sudo-Regel fuer den Bediener"
t_assert_contains "$_Rule" "enable --now win2unix@*" "Regel erlaubt enable --now"
t_assert_contains "$_Rule" "disable --now win2unix@*" "Regel erlaubt disable --now"
t_assert_contains "$_Rule" "reset-failed win2unix@*" "Regel erlaubt reset-failed"
if [ -x /usr/sbin/visudo ]; then
    /usr/sbin/visudo -cf "$_T/etc/sudoers.d/win2unix" >/dev/null 2>&1 && _Ok=ja || _Ok=nein
    t_assert_eq "ja" "$_Ok" "visudo akzeptiert die Regel"
fi
_Unit="$(cat "$_T/etc/systemd/system/win2unix@.service")"
t_assert_contains "$_Unit" "ExecStart=/opt/win2unix/w2u run %i" "Unit startet w2u run"
t_assert_contains "$_Unit" "RestartPreventExitStatus=3" "Unit: Exit 3 ohne Neustart"
t_assert_contains "$_Unit" "StartLimitIntervalSec=0" "Unit: gibt nie auf"
t_assert_contains "$_Unit" "WantedBy=multi-user.target" "Unit: ueberlebt Reboot (enable)"
cmp -s "$_Root/pull.sh" "$_T/opt/win2unix/pull.sh" && _Ok=ja || _Ok=nein
t_assert_eq "ja" "$_Ok" "pull.sh unveraendert kopiert"

# Zweiter Lauf = Aktualisierung: laeuft durch, Auftraege bleiben
echo "SRC=x" > "$_T/etc/win2unix/jobs/a.conf"
_Out="$(bash "$_Root/linux/install.sh" --root "$_T" --user "$_Me" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "zweiter Lauf (Aktualisierung) laeuft durch"
[ -f "$_T/etc/win2unix/jobs/a.conf" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "Auftraege bleiben bei der Aktualisierung"

t_summary
