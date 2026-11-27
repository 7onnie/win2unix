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
::   - geplante Aufgabe "win2unix-rsyncd" (SYSTEM, startet auch nach einem
::     Neustart) - DAS ist der Server. Entfernen: STOP-RSYNC-SERVER.cmd
:: Alles wird im Fenster angezeigt, wenn es passiert.
::
:: Der Server haengt NICHT an diesem Fenster und nicht an der Anmeldung
:: (Issue #13): die Transfers dauern Tage, die Kisten werden per RDP bedient,
:: und Abmelden beendete frueher den Server samt aller Transfers.
::
:: Argumente (normalerweise keine - Doppelklick):
::   elevated         setzt die .cmd selbst beim Neustart mit Adminrechten
::   ohne-admin-test  ueberspringt die Rechte-Pruefung. Nur wenn die Erkennung
::                    auf dieser Maschine falsch negativ ist: sonst laeuft der
::                    Server ohne Adminrechte und laesst STILL Profile aus.
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
::        Falsch NEGATIV waere sonst eine Sackgasse: der elevierte Lauf bricht
::        ab, der Rat "Als Administrator ausfuehren" setzt kein Argument, also
::        wieder Elevation, wieder Abbruch. Deshalb der dokumentierte Ausweg
::        "ohne-admin-test" - auf einer Maschine, deren Daten der ganze Zweck
::        sind, ist ein Notausgang billiger als ein unerreichbarer Server.
set "_IsAdmin=nein"
if /i "%~1"=="ohne-admin-test" (
    set "_IsAdmin=ja"
    echo  [!] Rechte-Pruefung per Argument uebersprungen. Laeuft dieses Fenster
    echo      NICHT als Administrator, fehlen im Ergebnis still fremde
    echo      Benutzerprofile - danach ist die Quelle verschrottet.
) else (
    net session >nul 2>&1
    if not errorlevel 1 set "_IsAdmin=ja"
)
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
        echo      Bitte ein cmd-Fenster per Rechtsklick als Administrator oeffnen
        echo      und darin starten:  START-RSYNC-SERVER.cmd ohne-admin-test
        echo      Das ueberspringt die Pruefung, nicht die Rechte: ohne Adminrechte
        echo      werden fremde Benutzerprofile STILL uebersprungen.
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

:: --- 4. IPv4-Adressen sammeln. Die Liste dient nur noch der Anzeige und den
::        Copy-Paste-Zeilen am Ende - "hosts allow" ist fest 0.0.0.0/0. Alles wird mit LF
::        geschrieben ([IO.File] statt "> datei"), damit kein CR in eine
::        Config oder in eine for/f-Variable geraet. .NET-Pfade sind ABSOLUT,
::        weil .NET relative Pfade gegen das Prozess-Arbeitsverzeichnis
::        aufloest und nicht gegen den Ort von PowerShell.
echo  [+] Ermittle IPv4-Adressen...
del /q "w2u-ips.tmp" >nul 2>&1
powershell -NoProfile -Command "$ips = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=true' | ForEach-Object { $_.IPAddress } | Where-Object { $_ -like '*.*.*.*' -and $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' }); [IO.File]::WriteAllText('%~dp0w2u-ips.tmp', [string]::Join([string][char]10, $ips) + [string][char]10)"

set "_IpCnt=0"
if exist "w2u-ips.tmp" (
    for /f "usebackq delims=" %%I in ("w2u-ips.tmp") do (
        set /a _IpCnt+=1
        echo  [+]   %%I
    )
)
if "!_IpCnt!"=="0" (
    echo  [!] Keine IPv4-Adresse erkannt - die Befehle unten zeigen einen
    echo      Platzhalter statt der IP dieses Rechners.
)
:: hosts allow ist IMMER offen (Issue #8). Frueher standen hier die lokalen
:: /24-Netze - das hat im ersten Ernstfall den legitimen Client ausgesperrt.
:: Das Modul ist read only, die Firewall-Regel ohnehin fuer alle offen, und
:: die Maschine wird verschrottet. Wer es enger will, aendert die Zeile in
:: rsyncd.conf: der Daemon liest die Config bei jeder Verbindung neu. Ein
:: Neustart dieses Skripts wuerde sie dagegen neu erzeugen.
set "_Allow=0.0.0.0/0"
echo  [+] hosts allow = !_Allow! ^(jeder, der Port 873 erreicht, darf lesen^)

:: --- 4b. Laeuft schon ein Server? (Issue #11) Frueher startete jeder weitere
::         Klick einen Daemon, der an "Address already in use" starb, waehrend
::         das Fenster "Server laeuft" meldete - und die rsyncd.conf des ALTEN,
::         noch laufenden Daemons war ueberschrieben (er liest sie bei jeder
::         Verbindung neu). Laeuft schon ein rsync, wird deshalb NICHTS
::         angefasst: keine Config, keine Aufgabe, laufende Transfers bleiben.
call :PortHolder
if defined _PortPid (
    if /i "!_PortName!"=="rsync.exe" (
        echo.
        echo  [+] Ein rsync-Server laeuft bereits ^(PID !_PortPid!^). Es wird NICHTS
        echo      veraendert - rsyncd.conf bleibt, laufende Transfers laufen weiter.
        echo      Neu aufsetzen: STOP-RSYNC-SERVER.cmd, danach diese Datei erneut.
        call :ShowHints
        del /q "w2u-ips.tmp" >nul 2>&1
        pause
        exit /b 0
    )
    echo  [!] Port 873 ist belegt von "!_PortName!" ^(PID !_PortPid!^), nicht von
    echo      rsync. Dieses Programm beenden, dann diese Datei erneut starten.
    echo.
    del /q "w2u-ips.tmp" >nul 2>&1
    pause
    exit /b 1
)

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

:: --- 5b. Riegel fuer die letzte lieferentscheidende Annahme: dass Cygwin die
::         Laufwerke unter /cygdrive/<x>/ einhaengt. Stimmt der Prefix nicht,
::         startet der Daemon, das Fenster meldet "laeuft", und die Module sind
::         LEER - der Anwender erfaehrt es erst von der Gegenseite. Geprueft
::         wird mit dem mitgelieferten Binary, ohne Daemon, ohne Netz und ohne
::         Rekursion (--list-only auf einer Wurzel ist sofort fertig).
::         Gemessen auf dem Entwickler-Mac mit rsync 3.5.0: vorhandenes
::         Verzeichnis rc 0, fehlendes rc 23 samt change_dir-Meldung.
set "_FirstDrv="
for /f "usebackq tokens=1 delims=|" %%A in ("w2u-drives.tmp") do (
    if not defined _FirstDrv set "_FirstDrv=%%A"
)
echo  [+] Pruefe den Cygwin-Laufwerkspfad /cygdrive/!_FirstDrv!/ ...
del /q "w2u-probe.tmp" >nul 2>&1
bin\rsync.exe --list-only "/cygdrive/!_FirstDrv!/" >"w2u-probe.tmp" 2>&1
if errorlevel 1 (
    rem Nicht jeder rc ungleich 0 ist der gesuchte Fehler. Auf einer Windows-
    rem Wurzel liegen Eintraege, die selbst ein Administrator nicht lesen darf
    rem - System Volume Information gehoert nur SYSTEM. rsync quittiert das mit
    rem rc 23, obwohl der Prefix stimmt. Abgebrochen wird deshalb nur beim
    rem eindeutigen Befund "change_dir" - so heisst es, wenn das Verzeichnis
    rem selbst nicht existiert, also der /cygdrive-Prefix falsch ist.
    findstr /L /C:"change_dir" "w2u-probe.tmp" >nul
    if not errorlevel 1 (
        echo  [!] /cygdrive/!_FirstDrv!/ existiert fuer rsync.exe nicht. Die Module
        echo      waeren leer, deshalb wird NICHTS gestartet. rsync sagte:
        type "w2u-probe.tmp"
        echo.
        pause
        exit /b 1
    )
    echo  [i]   Probelesen meldete Fehler, aber das Verzeichnis existiert -
    echo        einzelne unlesbare Eintraege sind auf einer Windows-Wurzel normal.
    echo        Ausschluesse in rsyncd.module.template halten sie ohnehin heraus.
    echo        rsync sagte:
    type "w2u-probe.tmp"
)
del /q "w2u-probe.tmp" >nul 2>&1

:: --- 6. rsyncd.conf aus den Templates bauen. Die Templates sind dieselben
::        Dateien, gegen die tests/test_rsyncd_conf.sh einen echten Daemon
::        startet - deshalb stehen sie nicht hier drin. Wer sie hier inlinet,
::        macht diesen Test wertlos.
::        Geschrieben wird mit LF. Gemessen wurde, dass rsync auch CRLF frisst;
::        LF macht die Frage aber egal - auch nach einem Notepad-Speichern.
::        Entfernt werden ALLE CR, nicht nur CRLF-Paare. Grund (Review-Fund):
::        der WMI-Rueckfall oben schreibt seine Zeilen mit "echo", also mit
::        CRLF, und aus dieser Datei liest for/f das letzte Feld MIT dem CR.
::        Das landete als "comment = unbekannt (0<CR> GB)" in der Config - ein
::        EINZELNES CR mitten in der Zeile, das eine Paar-Ersetzung nicht
::        trifft. "alle CR weg" ist auf einem LF-Ergebnis dasselbe wie
::        "CRLF -> LF" und faengt den Einzelgaenger mit.
echo  [+] Erzeuge rsyncd.conf ^(!_DrvCnt! Laufwerk^(e^)^)...
:: Die alte Datei MUSS vorher weg. WriteAllText ueberschreibt nur bei
:: Erfolg: scheitert das ReadAllText auf dem Template (geloescht, vom
:: Virenscanner gesperrt, PowerShell-Fehler), bliebe die rsyncd.conf des
:: VORIGEN Laufs liegen, der "if not exist"-Riegel unten waere eine
:: Tautologie, und die Modul-Schleife haengte nur an. Bedient wuerden dann
:: die neuen Module (bei doppeltem [c] gewinnt der letzte Block), aber der
:: globale Kopf waere der ALTE - also das "hosts allow" der vorigen
:: Maschine, waehrend das Fenster oben das neu berechnete Subnetz gemeldet
:: hat. Das Bundle wandert per USB-Stick ueber mehrere Kisten in
:: verschiedenen Subnetzen; genau dieser Fall ist hier der Normalfall.
del /q "rsyncd.conf" >nul 2>&1
powershell -NoProfile -Command "$t = [IO.File]::ReadAllText('%~dp0rsyncd.head.template') -replace '@HOSTSALLOW@', '!_Allow!'; [IO.File]::WriteAllText('%~dp0rsyncd.conf', ($t -replace ([string][char]13), ''))"
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
    powershell -NoProfile -Command "$m = [IO.File]::ReadAllText('%~dp0rsyncd.module.template') -replace '@DRIVE@', '%%A' -replace '@PATH@', '/cygdrive/%%A/' -replace '@LABEL@', '%%B (%%C GB)'; [IO.File]::AppendAllText('%~dp0rsyncd.conf', [string][char]10 + ($m -replace ([string][char]13), ''))"
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

:: --- 9. Server als geplante Aufgabe starten (Issue #13). Laeuft als SYSTEM,
::        unabhaengig von diesem Fenster und von der Anmeldung, startet nach
::        einem Neustart wieder. Die Vorlage ist rsyncd.task.template (dort
::        steht, warum jede Einstellung da ist); der Pfad wird XML-escaped
::        eingesetzt, die Datei als UTF-16 geschrieben, wie schtasks /XML sie
::        erwartet. schtasks statt Register-ScheduledTask: das Cmdlet gibt es
::        erst ab Windows 8.
echo  [+] AENDERT DIESE MASCHINE: geplante Aufgabe "win2unix-rsyncd" ^(SYSTEM,
echo      startet auch nach einem Neustart^). Entfernen: STOP-RSYNC-SERVER.cmd
del /q "w2u-task.xml" >nul 2>&1
powershell -NoProfile -Command "$d = '%~dp0'.TrimEnd([char]92); $e = [Security.SecurityElement]::Escape($d).Replace('$', '$$'); $t = [IO.File]::ReadAllText('%~dp0rsyncd.task.template') -replace '@WORKDIR@', $e; [IO.File]::WriteAllText('%~dp0w2u-task.xml', $t, [Text.Encoding]::Unicode)"
if not exist "w2u-task.xml" (
    echo  [!] Aufgabe konnte nicht vorbereitet werden - fehlt rsyncd.task.template?
    echo.
    pause
    exit /b 1
)
schtasks /Create /TN "win2unix-rsyncd" /XML "%~dp0w2u-task.xml" /F >"w2u-schtasks.tmp" 2>&1
if errorlevel 1 (
    echo  [!] schtasks konnte die Aufgabe nicht anlegen:
    type "w2u-schtasks.tmp"
    echo.
    pause
    exit /b 1
)
schtasks /Run /TN "win2unix-rsyncd" >"w2u-schtasks.tmp" 2>&1
if errorlevel 1 (
    echo  [!] schtasks konnte die Aufgabe nicht starten:
    type "w2u-schtasks.tmp"
    echo.
    pause
    exit /b 1
)
del /q "w2u-schtasks.tmp" >nul 2>&1
del /q "w2u-task.xml" >nul 2>&1

:: Erst "laeuft" melden, wenn der Port wirklich lauscht. Frueher stand hier
:: "Server laeuft", auch wenn der Daemon eine Sekunde spaeter starb.
:: ping als Wartezeit: "timeout" bricht ohne Konsole ab, ping gibt es ueberall.
echo  [+] Warte, bis der Server auf Port 873 lauscht...
set "_Up=nein"
for /l %%W in (1,1,15) do (
    if "!_Up!"=="nein" (
        call :PortHolder
        if defined _PortPid set "_Up=ja"
        if "!_Up!"=="nein" ping -n 2 127.0.0.1 >nul
    )
)
if "!_Up!"=="nein" (
    echo  [!] Der Server lauscht nach 15 s nicht auf Port 873. Ende von rsyncd.log:
    powershell -NoProfile -Command "Get-Content '%~dp0rsyncd.log' -ErrorAction SilentlyContinue | Select-Object -Last 15"
    echo.
    echo      Aufgabe entfernen mit STOP-RSYNC-SERVER.cmd.
    del /q "w2u-ips.tmp" >nul 2>&1
    pause
    exit /b 1
)
if /i not "!_PortName!"=="rsync.exe" (
    echo  [!] Port 873 lauscht, aber der Prozess heisst "!_PortName!" ^(PID !_PortPid!^).
)
echo  [+] Server laeuft ^(PID !_PortPid!^).
call :ShowHints
del /q "w2u-ips.tmp" >nul 2>&1
del /q "w2u-drives.tmp" >nul 2>&1
pause
exit /b 0

:: ===========================================================================
:: Unterprogramme
:: ===========================================================================

:: Wer lauscht auf TCP 873? Setzt _PortPid und _PortName (leer = niemand).
:: Erkannt an Spalte 3 "0.0.0.0:0" bzw. "[::]:0" (IPv6) statt am Statustext: der ist lokalisiert
:: (englisch "Listening", deutsch "ABHOEREN"). Auf einem lauschenden IPv4-Socket ist die
:: Gegenadresse immer 0.0.0.0:0, auf einer bestehenden Verbindung nie - die
:: Zeilen der laufenden Transfers (lokal :873, Gegenseite echte IP) fallen
:: also heraus. Dieselbe Funktion steht in STOP-RSYNC-SERVER.cmd.
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

:: Adressen und fertige Befehle fuer die Gegenseite.
:ShowHints
echo.
echo  ========================================================
echo   Auf dem Mac/Linux-Rechner ausfuehren:
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
echo     curl -fsSL -o /tmp/pull.sh https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh
echo     bash /tmp/pull.sh rsync://IP/e/Archiv /ziel/
echo.
echo   Mehrere IPv4-Adressen oben heissen: mehrere Netzwerkkarten. Die nehmen,
echo   die im selben Netz wie der Mac/Linux-Rechner liegt.
echo.
echo   Der Server laeuft als geplante Aufgabe "win2unix-rsyncd" unter SYSTEM.
echo   Dieses Fenster schliessen, abmelden ^(auch RDP^) und Neustart beenden
echo   ihn NICHT. Beenden und entfernen: STOP-RSYNC-SERVER.cmd
echo  ========================================================
echo.
exit /b 0
