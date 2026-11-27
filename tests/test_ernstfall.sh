#!/usr/bin/env bash
# Fehler aus dem ersten Ernstfall (2026-11-27), gegen einen echten Daemon.
#
# 1) Rechte: Cygwin bildet Windows-ACLs auf Modi wie d---r-x--- oder r-xr-xr-x
#    ab. rsync ohne -p uebernimmt sie fuer NEUE Ordner - danach darf der
#    Eigentuemer im eigenen Ordner nichts anlegen ("mkdir ... Permission
#    denied"), und find zaehlt nicht hinein ("lokal ?"). Nachgestellt mit einem
#    Quellordner 0555 (lesbar fuer den Daemon, aber ohne Schreibrecht) und einem
#    VORHANDENEN Zielordner 0050 aus einem frueheren Lauf.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Rechte wirken nicht"
    t_summary
fi

_TmpRoot="$(mktemp -d)"
export TMPDIR="$_TmpRoot"
_Src="$_TmpRoot/src"
trap 'd_stop; chmod -R u+rwx "$_TmpRoot" 2>/dev/null; rm -rf "$_TmpRoot"' EXIT

mkdir -p "$_Src/A/BILD/ro/sub" "$_Src/A/BILD/alt/inner" "$_Src/A/BILD/ok"
echo eins > "$_Src/A/BILD/ro/sub/f1.jpg"
echo zwei > "$_Src/A/BILD/ro/f2.jpg"
echo drei > "$_Src/A/BILD/alt/inner/f3.jpg"
echo vier > "$_Src/A/BILD/ok/f4.jpg"
chmod 444 "$_Src/A/BILD/ro/sub/f1.jpg" "$_Src/A/BILD/ro/f2.jpg"
chmod 555 "$_Src/A/BILD/ro/sub" "$_Src/A/BILD/ro"

if ! d_start "$_Src"; then
    t_skip "Daemon nicht startbar"
    t_summary
fi

# Ziel mit einem Ordner aus einem frueheren Lauf, dem der Eigentuemer alle
# Rechte fehlen (so lag ThumbCache im Ernstfall auf dem Linux-Rechner).
_Z="$_TmpRoot/z"
mkdir -p "$_Z/A/BILD/alt"
chmod 050 "$_Z/A/BILD/alt"

_Out="$(bash "$_Root/pull.sh" --jobs 2 "$D_Url/A/BILD" "$_Z/A" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Windows-Rechte: Lauf endet mit rc 0"
t_assert_contains "$_Out" "ERGEBNIS: PASS" "Windows-Rechte: PASS"
t_assert_eq "4" "$(find "$_Z/A/BILD" -type f 2>/dev/null | wc -l | tr -d ' ')" "Windows-Rechte: alle 4 Dateien am Ziel"
[ -w "$_Z/A/BILD/ro/sub" ] && _W=ja || _W=nein
t_assert_eq "ja" "$_W" "neu angelegte Ordner sind fuer den Eigentuemer beschreibbar"
[ -r "$_Z/A/BILD/ro/f2.jpg" ] && [ -w "$_Z/A/BILD/ro/f2.jpg" ] && _W=ja || _W=nein
t_assert_eq "ja" "$_W" "neu angelegte Dateien sind fuer den Eigentuemer les- und schreibbar"
[ -x "$_Z/A/BILD/alt" ] && [ -w "$_Z/A/BILD/alt" ] && _W=ja || _W=nein
t_assert_eq "ja" "$_W" "vorhandener Ordner ohne Eigentuemer-Rechte wird repariert"

# Argumente: --chmod an Worker und Sweep; --protocol=30 nur bei GNU rsync mit
# Protokoll >= 31 (negative Nanosekunden von Cygwin-rsync 3.4.1 brechen 3.5.0
# sonst mit "modtime_nsec out of range" ab).
W2U_LIB_ONLY=1 . "$_Root/pull.sh"
_RsyncBin="$D_Bin"
w2u_rsync_extra
case " ${_RsyncExtra[*]} " in
    *" --chmod=Du+rwx,Fu+rw "*) _Has=ja ;;
    *) _Has=nein ;;
esac
t_assert_eq "ja" "$_Has" "Transfer-Argumente enthalten --chmod=Du+rwx,Fu+rw"
_Proto="$("$D_Bin" --version 2>&1 | sed -n 's/.*protocol version \([0-9]*\).*/\1/p' | head -1)"
case " ${_RsyncExtra[*]} " in
    *" --protocol=30 "*) _Has=ja ;;
    *) _Has=nein ;;
esac
if [ "${_Proto:-0}" -ge 31 ]; then
    t_assert_eq "ja" "$_Has" "GNU rsync mit Protokoll $_Proto: --protocol=30"
else
    t_assert_eq "nein" "$_Has" "rsync mit Protokoll $_Proto: kein --protocol"
fi
if [ -x /usr/bin/rsync ] && /usr/bin/rsync --version 2>&1 | grep -qi openrsync; then
    _RsyncBin=/usr/bin/rsync
    w2u_rsync_extra
    case " ${_RsyncExtra[*]} " in
        *" --protocol="*) _Has=ja ;;
        *) _Has=nein ;;
    esac
    t_assert_eq "nein" "$_Has" "openrsync: kein --protocol (spricht ohnehin 29)"
fi

t_summary
