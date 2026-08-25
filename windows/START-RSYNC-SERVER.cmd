@echo off
setlocal EnableExtensions EnableDelayedExpansion
title win2unix - rsync-Server

:: ===========================================================================
:: win2unix / START-RSYNC-SERVER.cmd
::
:: Stellt alle lokalen Laufwerke dieser Maschine READ ONLY als rsync-Module
:: bereit, damit ein Mac/Linux-Rechner sie mit pull.sh abholen kann. Es wird
:: NICHTS installiert - dieser Ordner wird kopiert, diese Datei angeklickt.
::
:: Bewusst dauerhafte Aenderungen an dieser Maschine (sie wird verschrottet):
::   - Firewall-Regel "win2unix rsync" fuer TCP 873 eingehend, bleibt stehen
::   - Energiesparen/Standby/Platten-Timeout im aktiven Schema auf "nie"
:: Beides wird im Fenster angezeigt, wenn es passiert.
::
:: Annahmen (siehe .superpowers/.../task-11-report.md fuer die Begruendung):
::   - Windows 7 / Server 2008 R2 oder neuer. Grund: PowerShell 2.0 (fuer die
::     Templates und die WMI-Abfragen) und "netsh advfirewall".
::   - Bewusst NICHT benutzt, weil erst ab Windows 8/2012 vorhanden:
::     Get-CimInstance, Get-NetIPAddress.
::   - Bewusst NICHT benutzt: "ipconfig | findstr IPv4" - die Beschriftung ist
::     lokalisiert; WMI liefert die Adressen sprachunabhaengig.
:: ===========================================================================

cd /d "%~dp0" 2>nul

echo.
echo  === win2unix - temporaerer rsync-Server ===
echo.

:: --- 0. Steht das Bundle da, wo es arbeiten kann?
::        Ein UNC-Pfad (\\server\freigabe) laesst sich nicht als Arbeits-
::        verzeichnis setzen; "cd /d" scheitert dann still und cmd bleibt in
::        C:\Windows\system32 - das ist als Administrator SCHREIBBAR, die
::        Config landete also unbemerkt im Systemordner. Der RELATIVE Test auf
::        bin\rsync.exe faellt genau darauf herein und deckt zugleich ein
::        unvollstaendig kopiertes Bundle ab. Er kommt vor der Rechte-Anfrage,
::        weil eine UAC-Abfrage fuer einen Ordner, in dem es sowieso nicht
::        weitergeht, nur Zeit kostet. Gelesen wird hier, geaendert nichts.
if not exist "bin\rsync.exe" (
    echo  [!] bin\rsync.exe wurde nicht gefunden.
    echo      Diesen Ordner KOMPLETT auf eine lokale Festplatte kopieren
    echo      ^(nicht direkt von \\Server\Freigabe starten^) und erneut anklicken.
    echo.
    pause
    exit /b 1
)

:: --- 1. Administrator-Rechte. Der Test steht ganz vorn: ohne Adminrechte
::        liest der Daemon fremde Benutzerprofile nicht und laesst still
::        Verzeichnisse aus - genau der Fehler, den niemand bemerkt.
::        Zwei Proben, weil "net session" den Dienst "Server" (LanmanServer)
::        braucht: ist der abgeschaltet, schlaegt es AUCH als Administrator
::        fehl. "fsutil dirty query" braucht ihn nicht und scheitert ohne
::        Adminrechte an Access Denied. Eine der beiden muss durchgehen.
set "_IsAdmin=nein"
net session >nul 2>&1
if not errorlevel 1 set "_IsAdmin=ja"
if "!_IsAdmin!"=="nein" (
    fsutil dirty query %SystemDrive% >nul 2>&1
    if not errorlevel 1 set "_IsAdmin=ja"
)

if "!_IsAdmin!"=="nein" (
    rem Der Marker "elevated" verhindert eine UAC-Endlosschleife: waere die
    rem Rechteerkennung auf dieser Maschine kaputt, wuerde sich das Skript
    rem sonst unbegrenzt selbst neu starten.
    if "%~1"=="elevated" (
        echo  [!] Auch nach der Rechte-Anfrage keine Administrator-Rechte erkannt.
        echo      Bitte per Rechtsklick "Als Administrator ausfuehren" starten.
        echo      Ohne Adminrechte werden fremde Benutzerprofile STILL uebersprungen.
        echo.
        pause
        exit /b 1
    )
    echo  [i] Keine Administrator-Rechte - fordere sie an ^(UAC-Abfrage^)...
    rem -WorkingDirectory ist Pflicht: ein per RunAs gestartetes .cmd erbt das
    rem Verzeichnis des Aufrufers NICHT, es startet in C:\Windows\system32.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -WorkingDirectory '%~dp0' -Verb RunAs"
    if errorlevel 1 (
        echo  [!] Rechte-Anfrage abgebrochen oder fehlgeschlagen - nichts gestartet.
        echo.
        pause
    )
    exit /b
)
echo  [+] Administrator-Rechte vorhanden.

:: --- 2. Ist der Ordner beschreibbar? Hier entstehen rsyncd.conf, rsyncd.lock,
::        rsyncd.pid und rsyncd.log. Von CD/DVD oder einer read-only-Freigabe
::        gestartet scheiterte sonst erst die Config, dann der Daemon - beides
::        mit unbrauchbaren Meldungen.
del /q "w2u-write.tmp" >nul 2>&1
echo test> "w2u-write.tmp" 2>nul
if not exist "w2u-write.tmp" (
    echo  [!] Dieser Ordner ist nicht beschreibbar.
    echo      Bundle auf eine lokale Festplatte kopieren, z.B. C:\win2unix\.
    echo.
    pause
    exit /b 1
)
del /q "w2u-write.tmp" >nul 2>&1

:: --- 3. PowerShell ist Pflicht: es befuellt die Templates und liefert die
::        IP-Adressen. Ab Windows 7 immer vorhanden, unter XP nie.
::        Erst der feste Pfad, dann "where": ein leeres oder kaputtes PATH darf
::        nicht als "PowerShell fehlt" durchgehen, und "where" selbst gibt es
::        auf ganz alten Systemen nicht.
set "_HasPs=nein"
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "_HasPs=ja"
if "!_HasPs!"=="nein" (
    where powershell.exe >nul 2>&1
    if not errorlevel 1 set "_HasPs=ja"
)
if "!_HasPs!"=="nein" (
    echo  [!] powershell.exe nicht gefunden - diese Windows-Version ist zu alt.
    echo      Fallback ohne Skript: bin\rsync.exe --daemon --config=... mit einer
    echo      handgeschriebenen rsyncd.conf ^(Vorlagen: rsyncd.*.template^).
    echo.
    pause
    exit /b 1
)

:: --- 4. IPv4-Adressen sammeln. Dieselbe Liste dient zweimal: fuer "hosts
::        allow" und fuer die Copy-Paste-Zeilen am Ende. Alles wird mit LF
::        geschrieben ([IO.File] statt "> datei"), damit kein CR in eine
::        Config oder in eine for/f-Variable geraet. .NET-Pfade sind ABSOLUT,
::        weil .NET relative Pfade gegen das Prozess-Arbeitsverzeichnis
::        aufloest und nicht gegen den Ort von PowerShell.
echo  [+] Ermittle IPv4-Adressen...
del /q "w2u-ips.tmp" >nul 2>&1
powershell -NoProfile -Command "$ips = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=true' | ForEach-Object { $_.IPAddress } | Where-Object { $_ -like '*.*.*.*' -and $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' }); [IO.File]::WriteAllText('%~dp0w2u-ips.tmp', [string]::Join([string][char]10, $ips) + [string][char]10)"

set "_Allow="
set "_IpCnt=0"
if exist "w2u-ips.tmp" (
    for /f "usebackq delims=" %%I in ("w2u-ips.tmp") do (
        set /a _IpCnt+=1
        echo  [+]   %%I
        for /f "tokens=1-3 delims=." %%a in ("%%I") do (
            if not defined _Seen_%%a_%%b_%%c (
                set "_Seen_%%a_%%b_%%c=1"
                set "_Allow=!_Allow! %%a.%%b.%%c.0/24"
            )
        )
    )
)
if defined _Allow set "_Allow=!_Allow:~1!"
if "!_IpCnt!"=="0" (
    rem Keine Adresse gefunden heisst nicht "kein Netz" - es kann auch die
    rem WMI-Abfrage sein. Ein Server, der niemanden hereinlaesst, ist hier
    rem nutzlos, also oeffnen statt raten. Die Maschine wird verschrottet.
    set "_Allow=0.0.0.0/0"
    echo  [!] Keine IPv4-Adresse erkannt - "hosts allow" wird auf 0.0.0.0/0
    echo      gesetzt ^(jeder im Netz darf lesen^).
)
echo  [+] hosts allow = !_Allow!

:: --- 5. Laufwerke ermitteln. DriveType=3 sind die fest eingebauten Platten.
::        Volume-Labels werden auf ASCII-Grundzeichen reduziert: sie landen in
::        einer for/f-Zeile mit Trennzeichen "|" und in einer PowerShell-
::        Zeichenkette. Ein Label mit |, !, ' oder % wuerde beides zerlegen.
::        Reihenfolge: erst filtern, dann auf leer pruefen - sonst entsteht
::        "c||500", und for/f fasst die zwei Trenner zu einem zusammen.
echo  [+] Suche lokale Laufwerke...
del /q "w2u-drives.tmp" >nul 2>&1
powershell -NoProfile -Command "$rows = @(Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $d = $_.DeviceID.Substring(0,1).ToLower(); $l = ''; if ($_.VolumeName) { $l = ($_.VolumeName -replace '[^A-Za-z0-9 _.+-]', '').Trim() }; if (-not $l) { $l = 'ohne Label' }; $g = 0; if ($_.Size) { $g = [math]::Round($_.Size / 1GB) }; $d + '|' + $l + '|' + $g }); [IO.File]::WriteAllText('%~dp0w2u-drives.tmp', [string]::Join([string][char]10, $rows) + [string][char]10)"

set "_DrvCnt=0"
if exist "w2u-drives.tmp" (
    for /f "usebackq tokens=1,2,3 delims=|" %%A in ("w2u-drives.tmp") do set /a _DrvCnt+=1
)
if "!_DrvCnt!"=="0" (
    rem Fallback: Buchstaben durchprobieren. Bewusst groeber - hier koennen
    rem auch USB- oder optische Laufwerke auftauchen. Ein Modul zu viel ist
    rem read only und harmlos; eine Maschine, die nichts anbietet, ist der
    rem Totalausfall.
    echo  [!] WMI lieferte kein Laufwerk - probiere Laufwerksbuchstaben durch.
    echo      Achtung: dabei koennen auch USB-/CD-Laufwerke als Modul erscheinen.
    for %%D in (c d e f g h i j k l m n o p q r s t u v w x y z) do (
        if exist %%D:\ (
            rem Das Trennzeichen erst per Variable einsetzen: in Anfuehrungs-
            rem zeichen bei set und danach per verzoegerter Erweiterung kommt es
            rem nie in die Zeilenzerlegung von cmd, wird also nie zur Pipe.
            set "_Row=%%D|unbekannt|0"
            >>"w2u-drives.tmp" echo !_Row!
            set /a _DrvCnt+=1
        )
    )
)
if "!_DrvCnt!"=="0" (
    rem Kein Modul heisst: der Daemon startet, das Fenster sagt "laeuft", und
    rem die Gegenseite bekommt eine leere Liste. Dieser stille Erfolg wird
    rem hier bewusst zum Abbruch.
    echo  [!] Kein einziges Laufwerk gefunden - es gibt nichts anzubieten.
    echo      Der Server wird NICHT gestartet.
    echo.
    pause
    exit /b 1
)

:: --- 6. rsyncd.conf aus den Templates bauen. Die Templates sind dieselben
::        Dateien, gegen die tests/test_rsyncd_conf.sh einen echten Daemon
::        startet - deshalb stehen sie nicht hier drin. Wer sie hier inlinet,
::        macht diesen Test wertlos.
::        Geschrieben wird mit LF. Gemessen wurde, dass rsync auch CRLF frisst;
::        LF macht die Frage aber egal - auch nach einem Notepad-Speichern.
echo  [+] Erzeuge rsyncd.conf ^(!_DrvCnt! Laufwerk^(e^)^)...
powershell -NoProfile -Command "$t = [IO.File]::ReadAllText('%~dp0rsyncd.head.template') -replace '@HOSTSALLOW@', '!_Allow!'; [IO.File]::WriteAllText('%~dp0rsyncd.conf', ($t -replace ([char]13 + [char]10), [string][char]10))"
if not exist "rsyncd.conf" (
    echo  [!] rsyncd.conf konnte nicht erzeugt werden - fehlt rsyncd.head.template?
    echo.
    pause
    exit /b 1
)

:: Ein Modul je Laufwerk, path = /cygdrive/<buchstabe>/. Absichtlich flach: die
:: parallele Phase von pull.sh adressiert die MODULWURZEL und haengt die Pfade
:: darunter an - rsync://IP/c/Users/X ist Modul c plus Praefix Users/X.
set "_ConfBad="
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("w2u-drives.tmp") do (
    echo  [+]   Laufwerk %%A: ^(%%B, %%C GB^) als Modul [%%A]
    powershell -NoProfile -Command "$m = [IO.File]::ReadAllText('%~dp0rsyncd.module.template') -replace '@DRIVE@', '%%A' -replace '@PATH@', '/cygdrive/%%A/' -replace '@LABEL@', '%%B (%%C GB)'; [IO.File]::AppendAllText('%~dp0rsyncd.conf', [string][char]10 + ($m -replace ([char]13 + [char]10), [string][char]10))"
    rem Je Laufwerk nachsehen, ob der Block wirklich in der Datei steht. Sonst
    rem waere ein Fehlschlag beim dritten von vier Laufwerken ein stiller
    rem Teilerfolg: Server laeuft, ein Laufwerk fehlt einfach.
    findstr /L /C:"[%%A]" "rsyncd.conf" >nul || set "_ConfBad=ja"
)

if defined _ConfBad (
    echo  [!] Mindestens ein Modul fehlt in rsyncd.conf - Server wird NICHT
    echo      gestartet. Bitte rsyncd.conf und rsyncd.module.template pruefen.
    echo.
    pause
    exit /b 1
)

:: --- 7. Firewall. Die Regel bleibt bewusst stehen - die Maschine wird
::        verschrottet. Ein doppelter Aufruf legt eine zweite gleichnamige
::        Regel an; das ist wirkungsgleich und darum egal.
echo  [+] AENDERT DIESE MASCHINE: Firewall-Regel "win2unix rsync", TCP 873 eingehend.
netsh advfirewall firewall add rule name="win2unix rsync" dir=in action=allow protocol=TCP localport=873 >nul 2>&1
if errorlevel 1 (
    echo  [!]   Firewall-Regel fehlgeschlagen. Falls die Gegenseite nicht
    echo        durchkommt, ist Port 873 hier zu oeffnen.
)

:: --- 8. Energiesparen aus, sonst schlaeft die Maschine mitten im TB-Transfer
::        ein. Nur die AC-Werte: dieser Rechner steht am Netz.
echo  [+] AENDERT DIESE MASCHINE: Standby, Ruhezustand, Platten- und
echo      Bildschirm-Timeout im aktiven Energieschema auf "nie".
powercfg /change standby-timeout-ac 0 >nul 2>&1
if errorlevel 1 echo  [!]   powercfg standby-timeout-ac fehlgeschlagen - Maschine kann einschlafen.
powercfg /change hibernate-timeout-ac 0 >nul 2>&1
powercfg /change disk-timeout-ac 0 >nul 2>&1
powercfg /change monitor-timeout-ac 0 >nul 2>&1

:: --- 9. Adressen und fertige Befehle fuer die Gegenseite.
echo.
echo  ========================================================
echo   Server laeuft. Auf dem Mac/Linux-Rechner ausfuehren:
echo.
if "!_IpCnt!"=="0" (
    echo     rsync rsync://IP-DIESES-RECHNERS/
) else (
    for /f "usebackq delims=" %%I in ("w2u-ips.tmp") do (
        echo     rsync rsync://%%I/
    )
)
echo.
echo   Das listet die Laufwerke. Dann den gewuenschten Ordner holen, z.B.:
echo     bash -c "$(curl -fsSL https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh)" -- rsync://IP/e/Archiv /ziel/
echo.
echo   Mehrere IPv4-Adressen oben heissen: mehrere Netzwerkkarten. Die nehmen,
echo   die im selben Netz wie der Mac/Linux-Rechner liegt.
echo.
echo   Dieses Fenster schliessen beendet den Server.
echo  ========================================================
echo.

del /q "w2u-ips.tmp" >nul 2>&1
del /q "w2u-drives.tmp" >nul 2>&1

:: --no-detach: der Daemon bleibt Kind dieses Fensters, Fenster zu = Server aus.
:: Ohne das liefe er unsichtbar weiter, auf einer Maschine, die niemand mehr
:: anfasst. Die relativen lock/pid/log-Pfade der Config beziehen sich auf das
:: Arbeitsverzeichnis - das ist dieser Ordner (cd /d oben).
bin\rsync.exe --daemon --no-detach --config=rsyncd.conf
echo.
echo  [i] Server beendet ^(Exit-Code %ERRORLEVEL%^). Protokoll: rsyncd.log
echo.
pause
