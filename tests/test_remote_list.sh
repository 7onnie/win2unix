#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync gefunden (openrsync kann kein --daemon)"
    t_summary
fi

_Src="$(mktemp -d)"
mkdir -p "$_Src/ordner a" "$_Src/leer"
echo x > "$_Src/datei.txt"
echo y > "$_Src/ordner a/tief.txt"
d_start "$_Src"
trap 'd_stop; rm -rf "$_Src"' EXIT

w2u_find_rsync
t_assert_eq "0" "$?" "rsync gefunden"

_Out="$(w2u_remote_list "$D_Url" "")"
t_assert_contains "$_Out" "$(printf 'f\tdatei.txt')" "Datei auf Ebene 1"
t_assert_contains "$_Out" "$(printf 'd\tordner a')" "Ordner mit Leerzeichen auf Ebene 1"
t_assert_contains "$_Out" "$(printf 'd\tleer')" "leerer Ordner wird gelistet"
t_assert_eq "3" "$(printf '%s\n' "$_Out" | grep -c .)" "genau drei Eintraege, nicht rekursiv"

_Out="$(w2u_remote_list "$D_Url" "ordner a")"
t_assert_eq "$(printf 'f\ttief.txt')" "$_Out" "Unterebene wird korrekt gelistet"

_Out="$(w2u_remote_list "$D_Url" "leer")"
t_assert_eq "" "$_Out" "leerer Ordner liefert leere Liste"

# CONTROLLER-RULING: ein nicht lesbares Verzeichnis (rc 23, Permission denied)
# darf NICHT mit einem wirklich leeren Verzeichnis (rc 0) verwechselt werden -
# beide erzeugen null geparste Zeilen, sind aber grundverschieden. Als root
# ignoriert der Prozess die Rechte, also hier ueberspringen statt falsch
# gruen zu melden.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Rechte-Test (chmod 000) ist wirkungslos"
else
    mkdir -p "$_Src/gesperrt"
    echo z > "$_Src/gesperrt/geheim.txt"
    chmod 000 "$_Src/gesperrt"

    _Rc=0
    _Err="$(w2u_remote_list "$D_Url" "gesperrt" 2>&1)" || _Rc=$?
    t_assert_eq "1" "$_Rc" "nicht lesbares Verzeichnis schlaegt hart fehl statt leere Liste zu liefern"
    t_assert_contains "$_Err" "ABBRUCH" "Fehlschlag wird sichtbar gemeldet, nicht nach /dev/null geworfen"

    chmod 755 "$_Src/gesperrt"

    # Danebenliegend: ein wirklich leeres Verzeichnis bleibt weiterhin sauber
    # leer - beide Faelle muessen unterscheidbar sein.
    _Out="$(w2u_remote_list "$D_Url" "leer")"
    t_assert_eq "" "$_Out" "echtes leeres Verzeichnis bleibt weiterhin sauber leer (Kontrastfall)"
fi

t_summary
