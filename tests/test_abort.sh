#!/usr/bin/env bash
# Issue #14: SIGTERM/SIGINT auf den Hauptprozess beendet ALLES (xargs, Worker,
# rsync), kein Chunk wird neu gestartet, Exit != 0, keine Erfolgsmarker.
# Ein SIGINT ist hier nicht testbar: ein Hintergrundprozess einer nicht
# interaktiven Shell erbt SIGINT als "ignoriert", und das laesst sich nicht
# trappen. Der INT-Trap ruft dieselbe Funktion w2u_on_signal wie der TERM-Trap.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

_T="$(mktemp -d)"
trap 'rm -rf "$_T"' EXIT
mkdir -p "$_T/stub" "$_T/chunks" "$_T/logs"

cat > "$_T/stub/rsync" <<'STUB_EOF'
#!/bin/bash
# langsamer Fake-rsync: jeder Start wird protokolliert, die PID gemerkt
_D="$(dirname "$0")"
printf 'start %s %s\n' "$$" "$(date +%s)" >> "$_D/starts"
printf '%s\n' "$$" >> "$_D/pids"
exec sleep 30
STUB_EOF
chmod +x "$_T/stub/rsync"

: > "$_T/list"
_I=1
while [ "$_I" -le 6 ]; do
    printf 'x%s\n' "$_I" > "$_T/chunks/c$_I"
    printf '%s\n' "$_T/chunks/c$_I" >> "$_T/list"
    _I=$((_I + 1))
done

cat > "$_T/runner.sh" <<RUN_EOF
#!/bin/bash
W2U_LIB_ONLY=1 . "$_Root/pull.sh"
_TmpDir="$_T"; _LogDir="$_T/logs"; _ResultFile="$_T/results"; : > "\$_ResultFile"
_RsyncBin="$_T/stub/rsync"; _ParSrc="rsync://x/m"; _ParDst="$_T/dst"
_MaxRetry=3; _RetryPause=0; _RsyncTimeout=300
_AbortFlag="$_T/abort"
trap 'w2u_on_signal 143' TERM
trap 'w2u_on_signal 130' INT
w2u_run_list "$_T/list" 2
: > "$_T/erfolg"
RUN_EOF

bash "$_T/runner.sh" > "$_T/out.log" 2>&1 &
_Main=$!
_W=0
while [ "$_W" -lt 50 ]; do
    [ -f "$_T/stub/pids" ] && [ "$(grep -c . "$_T/stub/pids")" -ge 2 ] && break
    sleep 0.2
    _W=$((_W + 1))
done
_Before="$(grep -c . "$_T/stub/starts" 2>/dev/null || echo 0)"
kill -TERM "$_Main"
_Rc=0
wait "$_Main" || _Rc=$?
sleep 2

_Alive=0
for _P in $(cat "$_T/stub/pids" 2>/dev/null); do
    kill -0 "$_P" 2>/dev/null && _Alive=$((_Alive + 1))
done
_After="$(grep -c . "$_T/stub/starts" 2>/dev/null || echo 0)"

echo "== Abbruch-Test (#14)"
t_assert_eq "2" "$_Before" "vor dem Signal liefen 2 Worker (Vorbedingung)"
t_assert_eq "0" "$_Alive" "(a) nach dem Signal lebt kein rsync/Worker mehr"
t_assert_eq "$_Before" "$_After" "(b) kein Chunk wurde nach dem Signal (neu) gestartet"
t_assert_eq "143" "$_Rc" "(c) Exit-Code des Hauptprozesses ist 143 (SIGTERM)"
[ -e "$_T/erfolg" ] && _Erf=ja || _Erf=nein
t_assert_eq "nein" "$_Erf" "(d) kein Erfolgsmarker"
t_assert_eq "0" "$(grep -c . "$_T/results")" "(d) keine Ergebniszeile fuer abgebrochene Chunks"
t_summary
