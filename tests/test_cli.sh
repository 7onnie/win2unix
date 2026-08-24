#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

# Laden im Library-Modus darf NICHTS ausfuehren und muss rc 0 liefern
_Out="$(W2U_LIB_ONLY=1 bash -c ". '$_Root/pull.sh'; echo GELADEN" 2>&1)"
_Rc=$?
t_assert_rc 0 "$_Rc" "pull.sh laesst sich im Library-Modus laden"
t_assert_contains "$_Out" "GELADEN" "Library-Modus fuehrt main nicht aus"

# Ohne Argumente: Usage und Exit 2
_Out="$(bash "$_Root/pull.sh" 2>&1)"; _Rc=$?
t_assert_rc 2 "$_Rc" "Aufruf ohne Argumente liefert rc 2"
t_assert_contains "$_Out" "Aufruf:" "Usage wird ausgegeben"

t_summary
