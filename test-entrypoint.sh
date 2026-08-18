#!/usr/bin/env bash
# The one thing docker-entrypoint.sh has to get right: the database comes up
# first, and SQL Developer never launches if it didn't. Run: ./test-entrypoint.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

run() { # $1 = exit status the stubbed database startup returns
    local stub
    stub=$(mktemp -d)
    printf '#!/bin/sh\necho db\nexit %s\n' "$1" > "${stub}/sudo"
    printf '#!/bin/sh\necho gui\n' > "${stub}/sqldeveloper.sh"
    chmod +x "${stub}/sudo" "${stub}/sqldeveloper.sh"
    (cd "${stub}" && PATH="${stub}:${PATH}" bash "${here}/docker-entrypoint.sh" 2>/dev/null)
    rm -rf "${stub}"
}

[ "$(run 0)" = "$(printf 'db\ngui')" ] \
    || { echo "FAIL: expected the database to start, then SQL Developer"; exit 1; }
[ "$(run 1)" = "db" ] \
    || { echo "FAIL: SQL Developer launched even though the database failed to start"; exit 1; }
echo ok
