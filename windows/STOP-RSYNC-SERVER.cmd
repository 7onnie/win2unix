@echo off
:: ===========================================================================
:: win2unix / STOP-RSYNC-SERVER.cmd
::
:: Beendet den rsync-Server, den START-RSYNC-SERVER.cmd als geplante Aufgabe
:: "win2unix-rsyncd" eingerichtet hat, und entfernt die Aufgabe. Laufende
:: Transfers brechen dabei ab - pull.sh setzt beim naechsten Aufruf fort.
::
:: Bleibt bewusst stehen (die Maschine wird verschrottet): Firewall-Regel und
:: Energieeinstellungen.
:: ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
title win2unix - rsync-Server beenden
cd /d "%~dp0" 2>nul

echo.
echo  === win2unix - rsync-Server beenden ===
echo.

:: Administrator-Rechte: schtasks /Delete fuer eine SYSTEM-Aufgabe und
:: taskkill auf einen SYSTEM-Prozess brauchen sie. Dieselbe Doppelprobe wie in
:: START-RSYNC-SERVER.cmd (Begruendung dort).
set "_IsAdmin=nein"
net session >nul 2>&1
if not errorlevel 1 set "_IsAdmin=ja"
if "!_IsAdmin!"=="nein" (
    fsutil dirty query %SystemDrive% >nul 2>&1
    if not errorlevel 1 set "_IsAdmin=ja"
)
if "!_IsAdmin!"=="nein" (
    if "%~1"=="elevated" (
        echo  [!] Auch nach der Rechte-Anfrage keine Administrator-Rechte erkannt.
        echo      Bitte ein cmd-Fenster als Administrator oeffnen und darin starten.
        echo.
        pause
        exit /b 1
    )
    echo  [i] Keine Administrator-Rechte - fordere sie an ^(UAC-Abfrage^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)

echo  [+] Beende und entferne die geplante Aufgabe "win2unix-rsyncd"...
schtasks /End /TN "win2unix-rsyncd" >nul 2>&1
schtasks /Delete /TN "win2unix-rsyncd" /F >nul 2>&1
if errorlevel 1 (
    echo  [i]   Es war keine Aufgabe "win2unix-rsyncd" registriert.
) else (
    echo  [+]   Aufgabe entfernt.
)

:: Auch ein Daemon aus einer alten Version (im Fenster gestartet) haelt Port
:: 873 - deshalb zusaetzlich alle rsync.exe beenden. Auf dieser Maschine laeuft
:: rsync nur als dieser Server.
echo  [+] Beende rsync.exe...
taskkill /IM rsync.exe /F >nul 2>&1
ping -n 3 127.0.0.1 >nul

call :PortHolder
if defined _PortPid (
    echo  [!] Port 873 ist weiter belegt von "!_PortName!" ^(PID !_PortPid!^).
    echo      Von Hand beenden:  taskkill /PID !_PortPid! /F
    echo.
    pause
    exit /b 1
)
echo  [+] Port 873 ist frei - der Server ist aus.
echo      Firewall-Regel und Energieeinstellungen bleiben bewusst stehen.
echo.
pause
exit /b 0

:: Wer lauscht auf TCP 873? Setzt _PortPid und _PortName (leer = niemand).
:: Kopie aus START-RSYNC-SERVER.cmd - Begruendung dort.
:PortHolder
set "_PortPid="
set "_PortName="
for /f "tokens=2,3,5" %%A in ('netstat -ano 2^>nul') do (
    set "_Lsn=nein"
    if "%%B"=="0.0.0.0:0" set "_Lsn=ja"
    if "%%B"=="[::]:0" set "_Lsn=ja"
    if "!_Lsn!"=="ja" (
        set "_Loc=%%A"
        if "!_Loc:~-4!"==":873" (
            if not defined _PortPid set "_PortPid=%%C"
        )
    )
)
if defined _PortPid (
    for /f "tokens=1 delims=," %%N in ('tasklist /FI "PID eq !_PortPid!" /FO CSV /NH 2^>nul') do set "_PortName=%%~N"
)
exit /b 0
