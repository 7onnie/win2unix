#!/usr/bin/env bash
# TUI-Formular [n] muss auf Enter warten. Fehler aus dem Ernstfall: die Liste
# fragt alle 2 s nach Tasten, und dieselbe Grenze liess jedes Formularfeld nach
# 2 s mit dem Vorgabewert weiterspringen. Echter Pseudo-Terminal-Lauf.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
if ! python3 -c 'import curses, pty' 2>/dev/null; then
    t_skip "python3 ohne curses/pty"
    t_summary
fi
_Out="$(python3 "$_Here/lib/tui_form_pty.py" "$_Root" 2>&1)"; _Rc=$?
t_assert_rc 0 "$_Rc" "Formular wartet auf Enter, springt nicht nach 2 s weiter ($_Out)"
t_summary
