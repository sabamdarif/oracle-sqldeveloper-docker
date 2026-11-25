#!/usr/bin/env bash
# What docker-entrypoint.sh has to get right: the database comes up first, SQL
# Developer never launches if it didn't, and the image config's password wins on a
# database that already exists. Run: ./test-entrypoint.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# $1 = exit status the stubbed database startup returns
# $2 = "existing" to pretend Free has been initialized, "xe" for old XE data
# $3 = an explicit ORACLE_SID, otherwise exercise the entrypoint's FREE fallback
run() {
    local stub status="$1" existing="${2:-fresh}" sid="${3:-}" password="${STUB_PASSWORD-secret}"
    stub=$(mktemp -d)
    : >"${stub}/calls"

    # One stub serves the four things the entrypoint asks sudo for, naming
    # whichever it was: `container-entrypoint.sh`, `resetPassword`, the
    # `healthcheck.sh` that decides whether a database is already reachable, and
    # the `lsnrctl stop` that clears a leftover listener.
    cat >"${stub}/sudo" <<'STUB'
#!/bin/sh
printf 'call' >>"${STUB_CALLS}"
printf ' <%s>' "$@" >>"${STUB_CALLS}"
printf '\n' >>"${STUB_CALLS}"
[ "$1" = -iu ] && [ "$2" = oracle ] || exit 90
shift 2
case "$1" in
    env)
        [ "$2" = "ORACLE_PASSWORD=${STUB_PASSWORD}" ] &&
            [ "$3" = container-entrypoint.sh ] && [ "$4" = --nowait ] || exit 90
        echo db
        exit "${STUB_DB_STATUS:-0}"
        ;;
    resetPassword)
        [ "$2" = "${STUB_PASSWORD}" ] || exit 90
        echo reset
        exit "${STUB_RESET_STATUS:-0}"
        ;;
    healthcheck.sh)
        # Match upstream's readiness-marker behavior. The listener pre-check
        # must pass a nonempty second healthcheck argument to bypass markers.
        if [ "${STUB_MARKERS:-0}" = 1 ] && [ -z "${3:-}" ]; then
            exit 2
        fi
        exit "${STUB_HEALTHY:-1}"
        ;;
    lsnrctl)
        [ "$2" = stop ] || exit 90
        echo "${STUB_LSNRCTL_OUT:-TNS-12541: TNS:no listener}"
        exit "${STUB_LSNRCTL_STATUS:-1}"
        ;;
esac
exit 90
STUB
    printf '#!/bin/sh\necho gui\n' >"${stub}/sqldeveloper.sh"
    cat >"${stub}/setup-sqldeveloper-connection" <<'STUB'
#!/bin/sh
[ "${ORACLE_PASSWORD}" = "${STUB_PASSWORD}" ] || exit 90
echo setup
exit "${STUB_SETUP_STATUS:-0}"
STUB
    chmod +x "${stub}/sudo" "${stub}/sqldeveloper.sh" "${stub}/setup-sqldeveloper-connection"

    case "$existing" in
    existing) mkdir -p "${stub}/oracle/oradata/dbconfig/${sid:-FREE}" ;;
    xe) mkdir -p "${stub}/oracle/oradata/dbconfig/XE" ;;
    esac

    (
        cd "${stub}" || exit 1
        unset ORACLE_SID ORACLE_DATABASE
        if [ -n "${sid}" ]; then
            export ORACLE_SID="${sid}"
        fi
        PATH="${stub}:${PATH}" \
            STUB_CALLS="${stub}/calls" \
            STUB_PASSWORD="${password}" \
            STUB_DB_STATUS="${status}" \
            STUB_RESET_STATUS="${STUB_RESET_STATUS:-0}" \
            STUB_SETUP_STATUS="${STUB_SETUP_STATUS:-0}" \
            STUB_HEALTHY="${STUB_HEALTHY:-1}" \
            STUB_MARKERS="${STUB_MARKERS:-0}" \
            STUB_LSNRCTL_OUT="${STUB_LSNRCTL_OUT:-}" \
            STUB_LSNRCTL_STATUS="${STUB_LSNRCTL_STATUS:-1}" \
            ORACLE_BASE="${stub}/oracle" \
            ORACLE_PASSWORD="${password}" \
            bash "${here}/docker-entrypoint.sh" 2>&1
    )
    printf 'status=%s\n' "$?"
    cat "${stub}/calls"
    if [ "$existing" = xe ] && [ ! -d "${stub}/oracle/oradata/dbconfig/XE" ]; then
        echo xe-data-removed
    fi
    rm -rf "${stub}"
}
# The steps the stubs reported, in order, so a test can assert on the sequence.
steps() { printf '%s\n' "$1" | grep -Ex 'db|reset|setup|gui' | tr '\n' ' '; }

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Client aliases must use real Free services and explicit JDBC hostnames. Also
# check that the Dockerfile exposes the same readable file through TNS_ADMIN.
if ! grep -qx 'FREEPDB1 =' "${here}/tnsnames.ora" ||
    ! grep -Fq '(SERVICE_NAME = FREEPDB1)' "${here}/tnsnames.ora"; then
    fail "the client TNS file must define the FREEPDB1 service alias"
fi
if ! grep -qx 'FREE =' "${here}/tnsnames.ora" ||
    ! grep -Fq '(SERVICE_NAME = FREE)' "${here}/tnsnames.ora"; then
    fail "the client TNS file must define the FREE CDB service alias"
fi
[ "$(grep -Fc '(HOST = localhost)(PORT = 1521)' "${here}/tnsnames.ora")" = 2 ] ||
    fail "both client aliases must connect to localhost:1521"
if grep -Eq '\(SID[[:space:]]*=' "${here}/tnsnames.ora"; then
    fail "the client aliases must use service names, not SIDs"
fi
awk '
    {
        sub(/#.*/, "")
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "(") depth++
            if (c == ")" && --depth < 0) exit 1
        }
    }
    END { if (depth != 0) exit 1 }
' "${here}/tnsnames.ora" ||
    fail "the client TNS descriptors must have balanced parentheses"
grep -Fxq 'COPY --chmod=644 tnsnames.ora /opt/sqldeveloper/network/admin/tnsnames.ora' "${here}/Dockerfile" ||
    fail "the image must install a readable client TNS file"
grep -Fxq 'ENV TNS_ADMIN=/opt/sqldeveloper/network/admin' "${here}/Dockerfile" ||
    fail "SQL Developer must discover the installed client TNS directory"

fresh=$(run 0)
[ "$(steps "${fresh}")" = "db setup gui " ] ||
    fail "a fresh database must start, then hand the container to SQL Developer"
grep -qx 'status=0' <<<"${fresh}" ||
    fail "a successful startup must exit successfully"
grep -Fq 'Service   FREEPDB1   (or FREE for the CDB)' <<<"${fresh}" ||
    fail "default connection details must name FREEPDB1 and FREE"
grep -Fxq 'call <-iu> <oracle> <healthcheck.sh> <FREE> <container status ignore>' <<<"${fresh}" ||
    fail "the listener pre-check must check FREE and ignore readiness markers"

[ "$(steps "$(run 1)")" = "db " ] ||
    fail "SQL Developer must not launch when the database fails to start"

[ "$(steps "$(run 0 existing)")" = "db reset setup gui " ] ||
    fail "an existing database must have the configured password re-applied"

reset_failed=$(STUB_RESET_STATUS=1 run 0 existing)
[ "$(steps "${reset_failed}")" = "db reset " ] ||
    fail "SQL Developer must not launch if resetting the password fails"
grep -qx 'status=1' <<<"${reset_failed}" ||
    fail "a failed password reset must fail the startup"

# Quoting must preserve spaces and shell metacharacters across sudo/env.
password=$(STUB_PASSWORD='secret with spaces $;*' run 0 existing)
[ "$(steps "${password}")" = "db reset setup gui " ] ||
    fail "the configured password must reach startup and resetPassword unchanged"
grep -Fxq '  Password  secret with spaces $;*' <<<"${password}" ||
    fail "the connection banner must print the configured password for manual connections"

explicit=$(run 0 existing FREE)
[ "$(steps "${explicit}")" = "db reset setup gui " ] ||
    fail "an explicitly inherited FREE SID must find the existing configuration"

xe=$(run 0 xe)
[ "$(steps "${xe}")" = "" ] ||
    fail "old XE data must be rejected before starting the database or GUI"
grep -qx 'status=1' <<<"${xe}" ||
    fail "old XE data must fail the startup"
grep -Fq 'Oracle XE data detected' <<<"${xe}" ||
    fail "old XE data must produce migration instructions"
if grep -Eq '^call|^xe-data-removed$' <<<"${xe}"; then
    fail "rejecting old XE data must not touch Oracle commands or remove its configuration"
fi

foreign=$(STUB_LSNRCTL_OUT='TNS-01189: The listener could not authenticate the user' run 0)
[ "$(steps "${foreign}")" = "" ] ||
    fail "a listener on port 1521 that is not ours must stop the start before the database"
grep -qx 'status=1' <<<"${foreign}" ||
    fail "a listener on port 1521 that is not ours must fail, not skip silently"

[ "$(steps "$(STUB_LSNRCTL_STATUS=0 run 0)")" = "db setup gui " ] ||
    fail "a listener a previous run left behind must be stopped, then the database started"

# TNS-01189 would abort the start if the listener were touched at all, so reaching
# the GUI is what proves a reachable database was left alone.
[ "$(steps "$(STUB_HEALTHY=0 STUB_LSNRCTL_OUT='TNS-01189: no' run 0)")" = "db setup gui " ] ||
    fail "a database that is already reachable must keep the listener it is registered with"

markers=$(STUB_MARKERS=1 STUB_HEALTHY=0 STUB_LSNRCTL_OUT='TNS-01189: no' run 0)
[ "$(steps "${markers}")" = "db setup gui " ] ||
    fail "stale readiness markers must not make us stop a reachable database's listener"

empty=$(STUB_PASSWORD='' run 0)
[ "$(steps "${empty}")" = "" ] ||
    fail "an empty configured password must stop startup before Oracle or the GUI"
grep -qx 'status=1' <<<"${empty}" ||
    fail "an empty configured password must fail the startup"

setup_failed=$(STUB_SETUP_STATUS=1 run 0)
[ "$(steps "${setup_failed}")" = "db setup gui " ] ||
    fail "connection setup failure must not block an otherwise usable GUI"
grep -qx 'status=0' <<<"${setup_failed}" ||
    fail "connection setup is optional and must not fail database startup"

SQLDEVELOPER_AUTO_CONNECTION=false bash "${here}/setup-sqldeveloper-connection.sh" ||
    fail "automatic saved credentials must support opting out without invoking Java"

echo ok
