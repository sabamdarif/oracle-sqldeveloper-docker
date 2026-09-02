#!/usr/bin/env bash
# What docker-entrypoint.sh has to get right: the database comes up first, SQL
# Developer never launches if it didn't, and the image config's password wins on a
# database that already exists. Run: ./test-entrypoint.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# $1 = exit status the stubbed database startup returns
# $2 = "existing" to pretend the database has been initialized before
run() {
    local stub status="$1" existing="${2:-fresh}"
    stub=$(mktemp -d)

    # One stub serves both `sudo -iu oracle env ... container-entrypoint.sh` and
    # `sudo -iu oracle resetPassword ...`, naming whichever it was asked for.
    cat >"${stub}/sudo" <<'STUB'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
    container-entrypoint.sh)
        echo db
        exit "${STUB_DB_STATUS:-0}"
        ;;
    resetPassword)
        echo reset
        exit 0
        ;;
    esac
done
exit 0
STUB
    printf '#!/bin/sh\necho gui\n' >"${stub}/sqldeveloper.sh"
    chmod +x "${stub}/sudo" "${stub}/sqldeveloper.sh"

    [ "$existing" = existing ] && mkdir -p "${stub}/oracle/oradata/dbconfig/XE"

    (
        cd "${stub}" || exit 1
        PATH="${stub}:${PATH}" \
            STUB_DB_STATUS="${status}" \
            ORACLE_BASE="${stub}/oracle" \
            ORACLE_SID="XE" \
            ORACLE_PASSWORD="secret" \
            bash "${here}/docker-entrypoint.sh" 2>/dev/null
    )
    rm -rf "${stub}"
}
# The steps the stubs reported, in order, so a test can assert on the sequence.
steps() { printf '%s\n' "$1" | grep -Ex 'db|reset|gui' | tr '\n' ' '; }

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ "$(steps "$(run 0)")" = "db gui " ] ||
    fail "a fresh database must start, then hand the container to SQL Developer"

[ "$(steps "$(run 1)")" = "db " ] ||
    fail "SQL Developer must not launch when the database fails to start"

[ "$(steps "$(run 0 existing)")" = "db reset gui " ] ||
    fail "an existing database must have the configured password re-applied"

echo ok
