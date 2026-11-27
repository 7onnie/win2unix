#!/usr/bin/env bash
# Issue #13: der Daemon laeuft als geplante Aufgabe unter SYSTEM, unabhaengig
# von der Anmeldung. Die .cmd und die Aufgabe laufen nur auf Windows - hier
# werden die Vorlage (als echtes XML) und die Schluesselstellen der Skripte
# festgenagelt.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

_Win="$_Root/windows"
_Tpl="$_Win/rsyncd.task.template"
_Start="$_Win/START-RSYNC-SERVER.cmd"
_Stop="$_Win/STOP-RSYNC-SERVER.cmd"

has() {
    if grep -q -- "$2" "$1" 2>/dev/null; then
        printf 'ja'
    else
        printf 'nein'
    fi
}

# ---- Vorlage der Aufgabe -----------------------------------------------------
[ -f "$_Tpl" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "Vorlage windows/rsyncd.task.template existiert"

# Mit eingesetztem Pfad muss es wohlgeformtes XML sein - schtasks lehnt sonst
# ab, und das faellt erst auf der Windows-Kiste auf.
_Xml="$(mktemp)"
trap 'rm -f "$_Xml"' EXIT
sed -e 's|@WORKDIR@|C:\\win2unix|g' -e 's| encoding="UTF-16"||' "$_Tpl" > "$_Xml" 2>/dev/null
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$_Xml" >/dev/null 2>&1 && _Ok=ja || _Ok=nein
    t_assert_eq "ja" "$_Ok" "Vorlage ist wohlgeformtes XML"
else
    t_skip "kein xmllint"
fi

t_assert_eq "ja" "$(has "$_Tpl" '<UserId>S-1-5-18</UserId>')" "laeuft als SYSTEM (sprachunabhaengige SID)"
t_assert_eq "ja" "$(has "$_Tpl" '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>')" "keine Laufzeitgrenze (Standard 72 h bricht den Transfer ab)"
t_assert_eq "ja" "$(has "$_Tpl" '<BootTrigger>')" "startet nach einem Neustart von selbst"
t_assert_eq "ja" "$(has "$_Tpl" '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>')" "stoppt nicht bei Akku"
t_assert_eq "ja" "$(has "$_Tpl" '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>')" "startet auch auf Akku"
t_assert_eq "ja" "$(has "$_Tpl" '<StopOnIdleEnd>false</StopOnIdleEnd>')" "stoppt nicht beim Ende einer Leerlaufphase"
t_assert_eq "ja" "$(has "$_Tpl" '<RunOnlyIfIdle>false</RunOnlyIfIdle>')" "laeuft nicht nur im Leerlauf"
t_assert_eq "ja" "$(has "$_Tpl" '<Priority>4</Priority>')" "normale Prioritaet (Standard 7 drosselt Platte und CPU)"
t_assert_eq "ja" "$(has "$_Tpl" '<RestartOnFailure>')" "startet nach einem Absturz neu"
t_assert_eq "ja" "$(has "$_Tpl" '<WorkingDirectory>@WORKDIR@</WorkingDirectory>')" "Arbeitsverzeichnis = Bundle (lock/pid/log stehen relativ)"
t_assert_eq "ja" "$(has "$_Tpl" '<Arguments>/c rsyncd-loop.cmd</Arguments>')" "startet die Neustart-Schleife (RestartOnFailure greift nur beim Start)"
t_assert_eq "ja" "$(has "$_Tpl" '<Count>255</Count>')" "RestartOnFailure-Count im Schema-Bereich (max 255)"
_Loop="$_Win/rsyncd-loop.cmd"
t_assert_eq "ja" "$(has "$_Loop" 'bin\\rsync.exe --daemon --no-detach --config=rsyncd.conf')" "Schleife startet den Daemon im Vordergrund"
t_assert_eq "ja" "$(has "$_Loop" 'goto Loop')" "Schleife startet nach Ende neu"
_Lf="$(LC_ALL=C grep -c $'[^\r]$' "$_Loop" 2>/dev/null)" || _Lf=0
t_assert_eq "0" "$_Lf" "Schleife: jede Zeile endet mit CRLF"

# [!] mit verzoegerter Erweiterung: ein einzelnes ! verschwindet, zwei paaren
# sich mit !var! - die Meldung wird verstuemmelt. Nach setlocal also nur [^^!].
for _F in "$_Start" "$_Stop"; do
    _Bad="$(awk '/EnableDelayedExpansion/ { _On = 1 } _On && /echo  \[!\]/ { _N++ } END { print _N + 0 }' "$_F")"
    t_assert_eq "0" "$_Bad" "${_F##*/}: kein unmaskiertes [!] nach setlocal EnableDelayedExpansion"
done
t_assert_eq "ja" "$(has "$_Start" 'schtasks /Query /TN "win2unix-rsyncd"')" "START erkennt einen alten Server im Fenster"
t_assert_eq "ja" "$(has "$_Start" 'rsync://127.0.0.1/!_FirstDrv!/')" "START liest nach dem Start ein Modul ueber das Netz"

# ---- START -------------------------------------------------------------------
t_assert_eq "ja" "$(has "$_Start" 'schtasks /Create /TN "win2unix-rsyncd" /XML')" "START registriert die Aufgabe aus XML"
t_assert_eq "ja" "$(has "$_Start" 'schtasks /Run /TN "win2unix-rsyncd"')" "START startet die Aufgabe"
t_assert_eq "ja" "$(has "$_Start" 'SecurityElement')" "Pfad wird XML-escaped eingesetzt"
t_assert_eq "ja" "$(has "$_Start" "('netstat -ano 2")" "START prueft Port 873 vor dem Ueberschreiben der Config (#11)"
t_assert_eq "ja" "$(has "$_Start" '"\[::\]:0"')" "Port-Pruefung erkennt auch IPv6-Sockets"
t_assert_eq "nein" "$(has "$_Start" 'LISTENING')" "Port-Pruefung haengt nicht am lokalisierten Statustext"
t_assert_eq "nein" "$(has "$_Start" '^bin\\rsync.exe --daemon')" "Daemon laeuft nicht mehr im Vordergrund des Fensters"
t_assert_eq "nein" "$(has "$_Start" 'schliessen beendet den Server')" "Fenster verspricht nicht mehr 'Fenster zu = Server aus'"
t_assert_eq "ja" "$(has "$_Start" 'STOP-RSYNC-SERVER.cmd')" "START nennt den Weg zum Beenden"

# Die Datei ist CRLF - cmd.exe verschluckt sich an LF-Labels (goto/call).
_Lf="$(LC_ALL=C grep -c $'[^\r]$' "$_Start" 2>/dev/null)" || _Lf=0
t_assert_eq "0" "$_Lf" "START: jede Zeile endet mit CRLF"

# ---- STOP --------------------------------------------------------------------
[ -f "$_Stop" ] && _Has=ja || _Has=nein
t_assert_eq "ja" "$_Has" "STOP-RSYNC-SERVER.cmd existiert"
t_assert_eq "ja" "$(has "$_Stop" 'schtasks /Delete /TN "win2unix-rsyncd" /F')" "STOP entfernt die Aufgabe"
t_assert_eq "ja" "$(has "$_Stop" 'taskkill /IM rsync.exe /F')" "STOP beendet den Daemon"
t_assert_eq "ja" "$(has "$_Stop" "('netstat -ano 2")" "STOP prueft, dass der Port frei ist"
_Lf="$(LC_ALL=C grep -c $'[^\r]$' "$_Stop" 2>/dev/null)" || _Lf=0
t_assert_eq "0" "$_Lf" "STOP: jede Zeile endet mit CRLF"

t_summary
