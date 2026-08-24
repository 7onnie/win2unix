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
trap 'd_stop; rm -rf "$_Src"' EXIT
if ! d_start "$_Src"; then
    t_skip "rsync-Daemon konnte nicht binden (Port $D_Port evtl. von einem verwaisten Lauf belegt) - Test wird uebersprungen statt gegen den falschen Daemon zu laufen"
    t_summary
fi

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
    # Ruling 1 (Review): "ABBRUCH" allein waere auch von "w2u_die irgendwas"
    # erfuellt. Die eigentliche Forderung ist, dass die rsync-Diagnose selbst
    # sichtbar wird - hier konkret die Permission-denied-Meldung von rsync.
    t_assert_contains "$_Err" "Permission denied" "die rsync-Fehlermeldung selbst ist sichtbar, nicht nur eine generische ABBRUCH-Zeile"
    t_assert_contains "$_Err" "rc 23" "der rsync-Exit-Code steht in der Meldung"

    # Review-Fund: "_Raw=$(...)" ist ein einfaches Kommando. Unter set -e
    # (aktiv in main()) feuert errexit GENAU an dieser Zuweisung, bevor
    # "_Rc=$?" gelesen und bevor w2u_die erreicht wird - und weil stderr in
    # _Raw statt aufs Terminal ging, nimmt die verworfene Variable die
    # Diagnose mit. Das war in der bisherigen Suite unsichtbar, weil sie nur
    # "set -uo pipefail" (ohne -e) setzt UND jeder Aufruf eine
    # Kommandosubstitution ist - beides maskiert den Bug. Dieser Test bildet
    # die Produktionsbedingungen nach: set -e aktiv, UND der Aufruf in
    # Nicht-Substitutions-Form (Umleitung in eine Datei), so wie
    # w2u_decompose (Task 4) es voraussichtlich tun wird.
    _ProbeOut="$(mktemp)"
    _ProbeErr="$(mktemp)"
    _ProbeScript="$(mktemp)"
    cat > "$_ProbeScript" <<EOF
#!/usr/bin/env bash
set -e
W2U_LIB_ONLY=1
. "$_Root/pull.sh"
w2u_find_rsync
w2u_remote_list "$D_Url" "gesperrt" > "$_ProbeOut"
EOF
    chmod +x "$_ProbeScript"
    "$_ProbeScript" >/dev/null 2>"$_ProbeErr"
    _ProbeRc=$?
    rm -f "$_ProbeScript"

    t_assert_eq "1" "$_ProbeRc" "unter set -e und Umleitung in eine Datei: rc bleibt 1 (w2u_die), nicht das nackte rsync-rc 23"
    t_assert_eq "0" "$(wc -c < "$_ProbeOut" | tr -d ' ')" "bei Fehlschlag landet keine (Teil-)Ausgabe in der Zieldatei"
    t_assert_contains "$(cat "$_ProbeErr")" "ABBRUCH" "unter set -e + Datei-Umleitung erscheint trotzdem die ABBRUCH-Meldung"
    t_assert_contains "$(cat "$_ProbeErr")" "Permission denied" "unter set -e + Datei-Umleitung bleibt die rsync-Diagnose sichtbar statt mit der verworfenen Variable verloren zu gehen"

    rm -f "$_ProbeOut" "$_ProbeErr"

    chmod 755 "$_Src/gesperrt"

    # Danebenliegend: ein wirklich leeres Verzeichnis bleibt weiterhin sauber
    # leer - beide Faelle muessen unterscheidbar sein.
    _Out="$(w2u_remote_list "$D_Url" "leer")"
    t_assert_eq "" "$_Out" "echtes leeres Verzeichnis bleibt weiterhin sauber leer (Kontrastfall)"
fi

t_summary
