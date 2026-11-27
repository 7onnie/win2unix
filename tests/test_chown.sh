#!/usr/bin/env bash
# --chown U:G (Issue #12). Der echte Besitzerwechsel braucht root und laeuft
# im Ende-zu-Ende-Test auf dem Linux-Zielrechner. Hier: Pruefungen beim Parsen
# und die Argumentliste, die Worker und Sweep bekommen.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

_TmpRoot="$(mktemp -d)"
trap 'rm -rf "$_TmpRoot"' EXIT
_Me="$(id -un):$(id -gn)"

if [ "$(id -u)" -ne 0 ]; then
    _Out="$(bash "$_Root/pull.sh" --chown "$_Me" "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
    t_assert_rc 3 "$_Rc" "--chown ohne root: Exit 3 (Einrichtungsfehler)"
    t_assert_contains "$_Out" "root" "--chown ohne root: die Meldung nennt den Grund"
fi
_Out="$(bash "$_Root/pull.sh" --chown "gibtsnicht-w2u:gibtsnicht-w2u" "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "--chown mit unbekanntem Benutzer: Exit 3"
t_assert_contains "$_Out" "gibtsnicht-w2u" "unbekannter Benutzer wird genannt"
_Out="$(bash "$_Root/pull.sh" --chown "nurname" "rsync://10.0.0.1/e/x" "$_TmpRoot" 2>&1)"; _Rc=$?
t_assert_rc 3 "$_Rc" "--chown ohne Gruppe (Format U:G verlangt): Exit 3"

# Argumentliste in Bibliotheksform: Worker und Sweep bekommen dieselben
# Zusaetze aus w2u_xfer_args.
W2U_LIB_ONLY=1 . "$_Root/pull.sh"
_XChmod="--chmod=Du+rwx,Fu+rw"
_XProto="--protocol=30"
_XChown="--chown=1002:1002"
_Args=( -rlt )
w2u_xfer_args
t_assert_eq "-rlt --chmod=Du+rwx,Fu+rw --protocol=30 --chown=1002:1002" "${_Args[*]}" "Transfer-Argumente: chmod, protocol, chown"
_XChown=""
_Args=( -rlt )
w2u_xfer_args
t_assert_eq "-rlt --chmod=Du+rwx,Fu+rw --protocol=30" "${_Args[*]}" "ohne --chown kein --chown-Argument"

# Aufloesung U:G -> numerisch (wegen --numeric-ids)
w2u_resolve_owner "$_Me"
t_assert_eq "$(id -u):$(id -g)" "$_ChownIds" "U:G wird numerisch aufgeloest"

# Abschluss-chown darf Symlinks im Baum NICHT folgen (Review-Fund, kritisch):
# GNU "chown -R -H" dereferenziert jeden Link im Baum - ein haengender Link
# (rsyncd "munged" Links: /rsyncd-munged/...) liess den chown scheitern, ein
# Link nach /etc haette root dort den Besitzer aendern lassen. Mit GNU chown
# geprueft, wenn vorhanden (gchown aus coreutils auf macOS).
_Gnu=""
if chown --version 2>/dev/null | grep -q GNU; then
    _Gnu="$(command -v chown)"
elif command -v gchown >/dev/null 2>&1; then
    _Gnu="$(command -v gchown)"
fi
if [ -n "$_Gnu" ]; then
    mkdir -p "$_TmpRoot/shim" "$_TmpRoot/baum/sub"
    ln -s "$_Gnu" "$_TmpRoot/shim/chown"
    echo x > "$_TmpRoot/baum/sub/f"
    ln -s /rsyncd-munged/gibtsnicht "$_TmpRoot/baum/sub/haengend"
    _SavePath="$PATH"
    PATH="$_TmpRoot/shim:$PATH"
    _ChownIds="$(id -u):$(id -g)"
    _DstRoot="$_TmpRoot/baum"
    w2u_final_chown; _Rc=$?
    PATH="$_SavePath"
    t_assert_rc 0 "$_Rc" "Abschluss-chown mit haengendem Symlink im Baum (GNU chown): rc 0"
else
    t_skip "kein GNU chown - Symlink-Fall des Abschluss-chown nicht pruefbar"
fi

t_summary
