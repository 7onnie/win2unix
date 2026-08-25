#!/usr/bin/env bash
# Baut windows/bin und windows/etc reproduzierbar aus dem Chocolatey-Paket.
# Das Paket enthaelt KEIN Installer-Wrapper-Skript, sondern ein echtes portables
# Bundle (Spec 2.1). Laeuft auf dem Entwickler-Mac, nicht auf dem Zielsystem.
set -euo pipefail

_CwVersion="6.4.8"
_Url="https://packages.chocolatey.org/rsync.${_CwVersion}.nupkg"
_Root="$(cd "$(dirname "$0")/.." && pwd)"
_Work="$(mktemp -d)"
trap 'rm -rf "$_Work"' EXIT

# Erwartete DLLs laut Task-Vorgabe (6.4.8, x64 free). Fest verdrahtet statt nur
# per Glob kopiert: ein Glob, der nichts trifft, wuerde sonst klaglos ein leeres
# windows/bin erzeugen und das Skript liefe trotzdem "erfolgreich" durch.
_ExpectedDlls="cygwin1.dll cygcrypto-3.dll cygiconv-2.dll cygintl-8.dll cygz.dll cygzstd-1.dll cyglz4-1.dll cygpopt-0.dll cyggcc_s-seh-1.dll cygxxhash-0.dll"

echo "[+] lade $_Url"
curl -fsSL -o "$_Work/rsync.nupkg" "$_Url"

# curl -f laesst curl bei HTTP-Fehlerstatus (404 etc.) fehlschlagen und damit
# "set -e" das Skript abbrechen - das faengt den offensichtlichen Fall. Es
# faengt NICHT eine 200-Antwort mit HTML/Fehlertext im Body (z.B. ein
# CDN-Fehlerdokument). Deshalb hier zusaetzlich pruefen, dass die Datei
# tatsaechlich ein Zip ist (Magic Bytes "PK"), bevor unzip einen unklaren
# Fehler wirft.
_Magic="$(head -c 2 "$_Work/rsync.nupkg" 2>/dev/null || true)"
if [ "$_Magic" != "PK" ]
then
    echo "FEHLER: $_Work/rsync.nupkg ist kein Zip (Magic Bytes: '$_Magic')." >&2
    echo "        Vermutlich eine Fehlerseite statt des Pakets - Inhalt pruefen:" >&2
    head -c 300 "$_Work/rsync.nupkg" >&2 || true
    echo >&2
    exit 1
fi

_NupkgSize="$(wc -c < "$_Work/rsync.nupkg" | tr -d ' ')"
if [ "$_NupkgSize" -lt 1000000 ]
then
    echo "FEHLER: heruntergeladenes .nupkg ist mit ${_NupkgSize} Bytes verdaechtig klein (erwartet ~5.7 MB)." >&2
    exit 1
fi

echo "[+] entpacke aeusseres Paket"
unzip -q "$_Work/rsync.nupkg" -d "$_Work/nupkg"
_Inner="$_Work/nupkg/tools/cwrsync_${_CwVersion}_x64_free.zip"
[ -f "$_Inner" ] || { echo "FEHLER: erwartetes Bundle fehlt: $_Inner"; exit 1; }

echo "[+] entpacke inneres cwRsync-Bundle"
unzip -q "$_Inner" -d "$_Work/cw"

# Layout-Annahme (Spec: 6.4.8 hat bin/ und etc/ direkt an der Wurzel, anders
# als 6.2.2 mit einem versionierten Unterordner). Vor dem Loeschen des
# bestehenden windows/bin bzw. windows/etc pruefen, dass das frisch entpackte
# Bundle das erwartete Layout hat - sonst stuende das Repo nach einem
# fehlgeschlagenen spaeteren Schritt ohne Binaries da.
if [ ! -d "$_Work/cw/bin" ] || [ ! -d "$_Work/cw/etc" ]
then
    echo "FEHLER: entpacktes Bundle hat nicht das erwartete Layout (bin/ und etc/ an der Wurzel)." >&2
    echo "        Version ${_CwVersion} evtl. genestet wie 6.2.2 - Inhalt pruefen:" >&2
    find "$_Work/cw" -maxdepth 2 >&2 || true
    exit 1
fi

[ -f "$_Work/cw/bin/rsync.exe" ] || { echo "FEHLER: $_Work/cw/bin/rsync.exe fehlt im entpackten Bundle." >&2; exit 1; }
[ -f "$_Work/cw/etc/nsswitch.conf" ] || { echo "FEHLER: $_Work/cw/etc/nsswitch.conf fehlt im entpackten Bundle." >&2; exit 1; }

# Alle erwarteten DLLs vor dem Kopieren pruefen - lieber hier abbrechen als ein
# unvollstaendiges bin/ ins Repo committen, das erst auf dem Zielsystem beim
# Doppelklick mit "DLL fehlt" auffaellt.
for _Dll in $_ExpectedDlls
do
    [ -f "$_Work/cw/bin/$_Dll" ] || { echo "FEHLER: erwartete DLL fehlt im Bundle: $_Dll" >&2; exit 1; }
done

[ -f "$_Work/nupkg/legal/LICENSE.txt" ] || { echo "FEHLER: legal/LICENSE.txt fehlt im .nupkg." >&2; exit 1; }
[ -f "$_Work/nupkg/legal/VERIFICATION.txt" ] || { echo "FEHLER: legal/VERIFICATION.txt fehlt im .nupkg." >&2; exit 1; }

echo "[+] uebernehme Binaries"
# Ab hier wird das bestehende windows/bin und windows/etc geloescht. Alle oben
# stehenden Pruefungen laufen bewusst VORHER, damit ein Fehlschlag danach
# (Kopieren, Platte voll, ...) das Repo nicht ohne funktionierende Binaries
# zuruecklaesst. Ein Fehlschlag ab hier ist trotzdem theoretisch moeglich
# (z.B. Platte voll waehrend cp) - siehe Verifikation unten, die genau das
# abfaengt statt nur "Skript durchgelaufen" zu vermelden.
rm -rf "$_Root/windows/bin" "$_Root/windows/etc"
mkdir -p "$_Root/windows/bin" "$_Root/windows/etc"
cp "$_Work/cw/bin/rsync.exe" "$_Root/windows/bin/"
for _Dll in $_ExpectedDlls
do
    cp "$_Work/cw/bin/$_Dll" "$_Root/windows/bin/"
done
cp "$_Work/cw/etc/nsswitch.conf" "$_Root/windows/etc/"
cp "$_Work/nupkg/legal/LICENSE.txt" "$_Root/windows/LICENSE.txt"
cp "$_Work/nupkg/legal/VERIFICATION.txt" "$_Root/windows/VERIFICATION.txt"

echo "[+] verifiziere Ergebnis"
# Nicht nur melden dass das Skript durchgelaufen ist, sondern nachsehen, dass
# es tatsaechlich etwas Brauchbares produziert hat: Dateien da, nicht leer,
# und rsync.exe ist wirklich ein PE-Executable (Magic "MZ") statt z.B. ein
# HTML-Fehlerdokument, das zufaellig durch alle bisherigen Pruefungen kam.
_VerifyFail=0

for _F in "$_Root/windows/bin/rsync.exe" "$_Root/windows/etc/nsswitch.conf" "$_Root/windows/LICENSE.txt" "$_Root/windows/VERIFICATION.txt"
do
    if [ ! -s "$_F" ]
    then
        echo "FEHLER Verifikation: $_F fehlt oder ist leer." >&2
        _VerifyFail=1
    fi
done

for _Dll in $_ExpectedDlls
do
    _F="$_Root/windows/bin/$_Dll"
    if [ ! -s "$_F" ]
    then
        echo "FEHLER Verifikation: $_F fehlt oder ist leer." >&2
        _VerifyFail=1
    fi
done

_ExeMagic="$(head -c 2 "$_Root/windows/bin/rsync.exe" 2>/dev/null || true)"
if [ "$_ExeMagic" != "MZ" ]
then
    echo "FEHLER Verifikation: windows/bin/rsync.exe ist kein PE-Executable (Magic Bytes: '$_ExeMagic')." >&2
    _VerifyFail=1
fi

if [ "$_VerifyFail" -ne 0 ]
then
    echo "FEHLER: Verifikation des erzeugten Bundles fehlgeschlagen - siehe oben." >&2
    exit 1
fi

echo "[+] fertig:"
ls -la "$_Root/windows/bin"
