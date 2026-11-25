#!/usr/bin/env bash
# Attrappe fuer "rsync --list-only -d [--exclude-from=F] <lokaler-pfad>/".
# Braucht weder Daemon noch rsync. Nachgebildet wird nur, was die Zerlegung
# beruehrt:
#  - Ausgabeformat "perms size datum zeit name" mit "." als erster Zeile
#  - nicht lesbares Verzeichnis: Meldung "Permission denied", rc 23
#  - --exclude-from: ausgeschlossene Eintraege erscheinen im Listing NICHT.
#    Muster ohne "/" gelten gegen den Namen; ein fuehrendes "/" verankert an
#    der Wurzel des Listings - und das ist wie bei echtem rsync die Wurzel der
#    Auflistung selbst (das gelistete Verzeichnis), auf jeder Ebene.
# Jeder Aufruf haengt seine URL an $FAKE_RSYNC_LOG.
_Ex=""
_Url=""
for _A in "$@"; do
    case "$_A" in
        --exclude-from=*) _Ex="${_A#--exclude-from=}" ;;
        -*) ;;
        *) _Url="$_A" ;;
    esac
done
[ -z "${FAKE_RSYNC_LOG-}" ] || printf '%s\n' "$_Url" >> "$FAKE_RSYNC_LOG"
_Dir="${_Url%/}"
if [ ! -d "$_Dir" ] || [ ! -r "$_Dir" ] || [ ! -x "$_Dir" ]; then
    printf 'rsync: [sender] opendir "%s" failed: Permission denied (13)\n' "$_Dir"
    printf 'rsync error: some files/attrs were not transferred (code 23)\n'
    exit 23
fi
_Excluded() {
    local _N="$1" _IsDir="$2" _L _P
    [ -n "$_Ex" ] || return 1
    while IFS= read -r _L || [ -n "$_L" ]; do
        _L="${_L%$'\r'}"
        case "$_L" in ""|"#"*|";"*) continue ;; esac
        _P="${_L#/}"
        case "$_P" in
            */) [ "$_IsDir" = 1 ] || continue; _P="${_P%/}" ;;
        esac
        case "$_N" in
            $_P) return 0 ;;
        esac
    done < "$_Ex"
    return 1
}
printf 'drwxr-xr-x          4,096 2026/01/01 00:00:00 .\n'
for _E in "$_Dir"/* "$_Dir"/.[!.]*; do
    [ -e "$_E" ] || [ -L "$_E" ] || continue
    _N="${_E##*/}"
    if [ -d "$_E" ] && [ ! -L "$_E" ]; then
        _Excluded "$_N" 1 && continue
        printf 'drwxr-xr-x          4,096 2026/01/01 00:00:00 %s\n' "$_N"
    else
        _Excluded "$_N" 0 && continue
        printf -- '-rw-r--r--              1 2026/01/01 00:00:00 %s\n' "$_N"
    fi
done
exit 0
