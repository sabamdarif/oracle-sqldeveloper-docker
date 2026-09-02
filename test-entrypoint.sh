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

    # One stub serves the four things the entrypoint asks sudo for, naming
    # whichever it was: `container-entrypoint.sh`, `resetPassword`, the
    # `healthcheck.sh` that decides whether a database is already reachable, and
    # the `lsnrctl stop` that clears a leftover listener.
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
    healthcheck.sh)
        exit "${STUB_HEALTHY:-1}"
        ;;
    lsnrctl)
        echo "${STUB_LSNRCTL_OUT:-TNS-12541: TNS:no listener}"
        exit "${STUB_LSNRCTL_STATUS:-1}"
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
            STUB_HEALTHY="${STUB_HEALTHY:-1}" \
            STUB_LSNRCTL_OUT="${STUB_LSNRCTL_OUT:-}" \
            STUB_LSNRCTL_STATUS="${STUB_LSNRCTL_STATUS:-1}" \
            ORACLE_BASE="${stub}/oracle" \
            ORACLE_SID="XE" \
            ORACLE_PASSWORD="secret" \
            bash "${here}/docker-entrypoint.sh" 2>/dev/null
    )
    printf 'status=%s\n' "$?"
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

foreign=$(STUB_LSNRCTL_OUT='TNS-01189: The listener could not authenticate the user' run 0)
[ "$(steps "${foreign}")" = "" ] ||
    fail "a listener on port 1521 that is not ours must stop the start before the database"
[ "${foreign#*status=}" != 0 ] ||
    fail "a listener on port 1521 that is not ours must fail, not skip silently"

[ "$(steps "$(STUB_LSNRCTL_STATUS=0 run 0)")" = "db gui " ] ||
    fail "a listener a previous run left behind must be stopped, then the database started"

# TNS-01189 would abort the start if the listener were touched at all, so reaching
# the GUI is what proves a reachable database was left alone.
[ "$(steps "$(STUB_HEALTHY=0 STUB_LSNRCTL_OUT='TNS-01189: no' run 0)")" = "db gui " ] ||
    fail "a database that is already reachable must keep the listener it is registered with"

echo ok
