#!/usr/bin/env bash
# Wrapper, damit run_all.sh die Python-Tests von linux/w2u mitfaehrt.
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP kein python3"
    exit 0
fi
python3 -m unittest "$_Here/test_w2u.py" 2>&1 | grep -E "^(FAIL|ERROR|Ran|OK|FAILED)|Error" | tail -n 20
exit "${PIPESTATUS[0]}"
