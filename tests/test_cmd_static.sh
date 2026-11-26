#!/usr/bin/env bash
# Statische Pruefungen an START-RSYNC-SERVER.cmd. Die .cmd laesst sich hier
# nicht ausfuehren - was sie dem Anwender sagt und welche Werte sie setzt,
# laesst sich aber am Text festnageln.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"

_Cmd="$_Root/windows/START-RSYNC-SERVER.cmd"

# Issue #8: hosts allow ist IMMER offen. Das /24-Limit hat im ersten Ernstfall
# den legitimen Client ausgesperrt; Modul read only, Firewall-Regel ohnehin
# offen, Maschine wird verschrottet.
if grep -q '^set "_Allow=0\.0\.0\.0/0"' "$_Cmd"; then
    _Open=ja
else
    _Open=nein
fi
t_assert_eq "ja" "$_Open" "hosts allow wird unbedingt (nicht eingerueckt, nicht im if) auf 0.0.0.0/0 gesetzt"

if grep -q '\.0/24' "$_Cmd"; then
    _Sub=ja
else
    _Sub=nein
fi
t_assert_eq "nein" "$_Sub" "keine /24-Subnetze mehr in hosts allow"

# Die bash -c "$(curl ...)"-Form scheitert auf Linux: pull.sh ist groesser als
# MAX_ARG_STRLEN (128 KB) - "Argumentliste ist zu lang". Weder das Fenster noch
# README noch der Kopf von pull.sh duerfen sie empfehlen.
for _F in windows/START-RSYNC-SERVER.cmd README.md pull.sh; do
    if grep -q 'bash -c "\$(curl -fsSL' "$_Root/$_F"; then
        _Bad=ja
    else
        _Bad=nein
    fi
    t_assert_eq "nein" "$_Bad" "$_F empfiehlt nicht die bash -c \"\$(curl ...)\"-Form"
done

t_summary
