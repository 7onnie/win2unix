#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

_T="$(mktemp -d)"
trap 'rm -rf "$_T"' EXIT

_mk() { _I=1; : > "$1"; while [ "$_I" -le "$2" ]; do printf 'eintrag %d\n' "$_I" >> "$1"; _I=$((_I + 1)); done; }

# Fall A: 308 Pakete, P_max 8 -> 4*8=32 Divisor -> ceil(308/32)=10 je Chunk -> 31 Chunks
_mk "$_T/a.work" 308
mkdir -p "$_T/ca"
w2u_chunk "$_T/a.work" "$_T/ca" 8 "$_T/a.list"
t_assert_eq "31" "$(grep -c . "$_T/a.list")" "Fall A: 31 Chunks"
t_assert_eq "10" "$(wc -l < "$(head -1 "$_T/a.list")" | tr -d ' ')" "Fall A: 10 Eintraege im ersten Chunk"

# Fall B: 13193 Pakete -> ceil(13193/32)=413 > _ChunkMax -> auf 100 gedeckelt -> 132 Chunks
_mk "$_T/b.work" 13193
mkdir -p "$_T/cb"
w2u_chunk "$_T/b.work" "$_T/cb" 8 "$_T/b.list"
t_assert_eq "132" "$(grep -c . "$_T/b.list")" "Fall B: 132 Chunks, Obergrenze greift"

# Randfall: ein einziges Paket
_mk "$_T/c.work" 1
mkdir -p "$_T/cc"
w2u_chunk "$_T/c.work" "$_T/cc" 8 "$_T/c.list"
t_assert_eq "1" "$(grep -c . "$_T/c.list")" "ein Paket ergibt einen Chunk"

# Summenprobe: kein Eintrag darf verloren gehen
_Sum=0
while IFS= read -r _C; do _Sum=$((_Sum + $(wc -l < "$_C"))); done < "$_T/b.list"
t_assert_eq "13193" "$_Sum" "Summe aller Chunk-Zeilen entspricht der Arbeitsliste"

t_summary
