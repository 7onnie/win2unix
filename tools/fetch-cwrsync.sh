#!/usr/bin/env bash
# Baut windows/bin und windows/etc reproduzierbar aus dem Chocolatey-Paket.
# Das Paket enthaelt KEIN Installer-Wrapper-Skript, sondern ein echtes portables
# Bundle (Spec 2.1). Laeuft auf dem Entwickler-Mac, nicht auf dem Zielsystem.
set -euo pipefail

_CwVersion="6.4.8"
_Url="https://packages.chocolatey.org/rsync.${_CwVersion}.nupkg"
_Root="$(cd "$(dirname "$0")/.." && pwd)"
_Work="$(mktemp -d)"
_BinNew="$_Root/windows/bin.new"
_EtcNew="$_Root/windows/etc.new"
trap 'rm -rf "$_Work" "$_BinNew" "$_EtcNew"' EXIT

# Falls ein frueherer Lauf zwischen Staging und dem finalen "mv" abgebrochen
# ist (z.B. kill -9, das den EXIT-Trap dieses Laufs nicht mehr sehen kann):
# Reste von einem VORHERIGEN Aufruf vor dem eigenen Lauf wegraeumen, damit
# "mkdir" unten nicht auf einen halb befuellten Rest trifft.
rm -rf "$_BinNew" "$_EtcNew"

# Erwartete DLLs laut Task-Vorgabe (6.4.8, x64 free). Diese Liste ist NICHT
# die Kopierquelle (das war ein Fehler in einer frueheren Fassung: eine feste
# Liste als alleinige Kopierquelle wuerde bei einem kuenftigen _CwVersion-Bump
# mit einer zusaetzlichen DLL genau die stille Luecke aufreissen, die diese
# Pruefung eigentlich verhindern soll - die neue DLL wuerde nie kopiert, aber
# jede Pruefung gegen diese Liste wuerde trotzdem "bestehen"). Sie ist eine
# Mindestmenge, die vor dem Kopieren UND nach dem Kopieren gegen das Ergebnis
# geprueft wird; kopiert wird per Glob (siehe unten), damit eine kuenftige
# zusaetzliche DLL nie verloren geht.
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
[ -f "$_Inner" ] || { echo "FEHLER: erwartetes Bundle fehlt: $_Inner" >&2; exit 1; }

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

echo "[+] uebernehme Binaries in Staging-Verzeichnisse"
# Erst in windows/bin.new und windows/etc.new kopieren, NICHT direkt in
# windows/bin und windows/etc. Der bestehende Bestand bleibt dabei komplett
# unberuehrt - ein Fehlschlag beim Kopieren (z.B. Platte voll) bricht das
# Skript per "set -e" hier ab, bevor irgendetwas Bestehendes geloescht wurde.
mkdir -p "$_BinNew" "$_EtcNew"
cp "$_Work/cw/bin/rsync.exe" "$_BinNew/"
# Kopiert per Glob statt nur die _ExpectedDlls-Liste einzeln zu kopieren:
# damit geht eine kuenftige, in einer neueren _CwVersion zusaetzlich
# ausgelieferte DLL nie verloren. Der Glob kann an dieser Stelle nicht leer
# matchen - die Pruefschleife weiter oben hat schon sichergestellt, dass
# zumindest alle _ExpectedDlls im entpackten Bundle vorhanden sind, und faellt
# der Glob trotzdem einmal leer aus, bricht "cp" mit "No such file or
# directory" laut ab (auf bash 3.2 ohne nullglob wird das Glob-Muster dann
# woertlich als Dateiname an cp uebergeben) - set -e stoppt das Skript, es
# entsteht kein leeres bin.new, das unbemerkt durchrutscht.
cp "$_Work/cw/bin/"cyg*.dll "$_BinNew/"
cp "$_Work/cw/etc/nsswitch.conf" "$_EtcNew/"

echo "[+] verifiziere Staging-Verzeichnisse"
# Verifikation laeuft gegen bin.new/etc.new, NICHT gegen windows/bin und
# windows/etc - die existieren zu diesem Zeitpunkt unveraendert vom Beginn des
# Laufs. Erst wenn diese Pruefung besteht, wird unten destruktiv getauscht.
# Nicht nur melden dass das Skript durchgelaufen ist, sondern nachsehen, dass
# es tatsaechlich etwas Brauchbares produziert hat: Dateien da, nicht leer,
# und rsync.exe ist wirklich ein PE-Executable (Magic "MZ") statt z.B. ein
# HTML-Fehlerdokument, das zufaellig durch alle bisherigen Pruefungen kam.
_VerifyFail=0

for _F in "$_BinNew/rsync.exe" "$_EtcNew/nsswitch.conf"
do
    if [ ! -s "$_F" ]
    then
        echo "FEHLER Verifikation: $_F fehlt oder ist leer." >&2
        _VerifyFail=1
    fi
done

for _Dll in $_ExpectedDlls
do
    _F="$_BinNew/$_Dll"
    if [ ! -s "$_F" ]
    then
        echo "FEHLER Verifikation: $_F fehlt oder ist leer." >&2
        _VerifyFail=1
    fi
done

_ExeMagic="$(head -c 2 "$_BinNew/rsync.exe" 2>/dev/null || true)"
if [ "$_ExeMagic" != "MZ" ]
then
    echo "FEHLER Verifikation: rsync.exe (Staging) ist kein PE-Executable (Magic Bytes: '$_ExeMagic')." >&2
    _VerifyFail=1
fi

if [ "$_VerifyFail" -ne 0 ]
then
    echo "FEHLER: Verifikation des erzeugten Bundles fehlgeschlagen - windows/bin und windows/etc bleiben unveraendert." >&2
    exit 1
fi

echo "[+] uebernehme Lizenzdateien und tausche Staging gegen windows/bin, windows/etc"
# Legal-Dateien sind reine Overwrites (kein rm -rf davor), deshalb kein
# eigenes Staging noetig. Der destruktive Teil - rm -rf + mv - steht bewusst
# als LETZTER Schritt, nachdem alles oben bereits als vollstaendig und
# gueltig bestaetigt ist. Das Zeitfenster mit einem halb geloeschten
# windows/bin schrumpft damit auf zwei "mv"-Befehle, die je einzeln atomar
# sind (selbes Dateisystem, siehe "mktemp -d" bzw. windows/ selbst).
cp "$_Work/nupkg/legal/LICENSE.txt" "$_Root/windows/LICENSE.txt"
cp "$_Work/nupkg/legal/VERIFICATION.txt" "$_Root/windows/VERIFICATION.txt"
rm -rf "$_Root/windows/bin" "$_Root/windows/etc"
mv "$_BinNew" "$_Root/windows/bin"
mv "$_EtcNew" "$_Root/windows/etc"

echo "[+] fertig:"
ls -la "$_Root/windows/bin"
