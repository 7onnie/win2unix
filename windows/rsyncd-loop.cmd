@echo off
:: ===========================================================================
:: win2unix / rsyncd-loop.cmd - NICHT anklicken. Wird von der geplanten Aufgabe
:: "win2unix-rsyncd" gestartet (siehe rsyncd.task.template).
::
:: Warum eine Schleife: "RestartOnFailure" der Aufgabenplanung greift nur, wenn
:: die Aufgabe nicht STARTEN kann - endet der gestartete Prozess spaeter (Absturz
:: mitten im wochenlangen Transfer), startet sie nichts neu. Diese Schleife tut
:: es, nach 60 s Pause. Beendet wird sie von STOP-RSYNC-SERVER.cmd: erst die
:: Aufgabe (trifft diese Schleife), dann rsync.exe.
:: ===========================================================================
cd /d "%~dp0"
:Loop
bin\rsync.exe --daemon --no-detach --config=rsyncd.conf
>>"rsyncd.log" echo %date% %time% [win2unix] rsync.exe endete mit Exit-Code %errorlevel% - Neustart in 60 s
ping -n 61 127.0.0.1 >nul
goto Loop
