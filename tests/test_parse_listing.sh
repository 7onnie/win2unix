#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

_Fixture="$(mktemp)"
trap 'rm -f "$_Fixture"' EXIT
cat > "$_Fixture" <<'EOF'
drwxr-xr-x          160 2026/08/24 23:29:29 .
-rw-r--r--            5 2026/08/24 23:29:29 root.txt
drwxr-xr-x           96 2026/08/24 23:33:01 Müller Praxis
-rw-r--r--        22907 2026/03/01 17:48:00 Datei mit  doppelten   Leerzeichen.DOC
drwxr-xr-x           96 2020/01/01 12:00:00 Ordner 2026/01/01 12:00:00 fies
-rw-r--r--            0 2026/08/24 23:29:29 leer.dat
lrwxrwxrwx           12 2026/08/24 23:29:29 link
Kopfzeile ohne Zeitstempel
EOF
printf -- '-rw-r--r--            7 2026/08/24 23:29:29 mit-cr.txt\r\n' >> "$_Fixture"

_Out="$(w2u_parse_listing < "$_Fixture")"

t_assert_eq "7" "$(printf '%s\n' "$_Out" | grep -c .)" "sieben Eintraege, Punkt und Kopfzeile weg"
t_assert_contains "$_Out" "$(printf 'f\troot.txt')" "einfache Datei"
t_assert_contains "$_Out" "$(printf 'd\tMüller Praxis')" "Umlaut und Leerzeichen im Ordnernamen"
t_assert_contains "$_Out" "$(printf 'f\tDatei mit  doppelten   Leerzeichen.DOC')" "mehrfache Leerzeichen bleiben erhalten"
t_assert_contains "$_Out" "$(printf 'd\tOrdner 2026/01/01 12:00:00 fies')" "Zeitstempel IM Dateinamen bricht den Parser nicht"
t_assert_contains "$_Out" "$(printf 'f\tlink')" "Symlink zaehlt als Blatt"
t_assert_contains "$_Out" "$(printf 'f\tmit-cr.txt')" "CR am Zeilenende wird entfernt"
_HasCr="$(printf '%s' "$_Out" | tr -d '\r' | wc -c)"
_RawCr="$(printf '%s' "$_Out" | wc -c)"
t_assert_eq "$_RawCr" "$_HasCr" "Ausgabe enthaelt kein CR mehr"

t_summary
