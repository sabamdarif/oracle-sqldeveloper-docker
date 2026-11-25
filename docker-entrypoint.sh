#!/usr/bin/env bash
# Start Oracle Free, then hand the container over to SQL Developer. Whoever enters
# -- `sqldev` from the image USER, or root with `--user root` -- the database has
# to be started by `oracle`, which is what the image's sudoers rule is for.
set -euo pipefail

: "${ORACLE_PASSWORD:?is empty; the image config bakes a password in, so this was overridden with nothing}"

ORACLE_BASE="${ORACLE_BASE:-/opt/oracle}"
ORACLE_SID="${ORACLE_SID:-FREE}"
DBCONFIG="${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"

# A base-image change cannot upgrade XE data files. Refuse before touching the
# listener or data, so an old oradata mount is not initialized as a Free database.
if [ -d "${ORACLE_BASE}/oradata/dbconfig/XE" ]; then
    cat >&2 <<'EOF'
CONTAINER: Oracle XE data detected; it cannot be reused by this Oracle Free image.
Back up/export your XE schemas (for example with Oracle Data Pump), start Oracle
Free with a fresh data directory, then import them. The XE data was not changed.
EOF
    exit 1
fi

# `sudo -i` gives oracle its own login environment and drops ours, which matters
# here: the JDK paths this image exports would otherwise shadow Oracle's own
# libraries.
as_oracle() { sudo -iu oracle "$@"; }

# This entrypoint runs no supervisor, so a previous run leaves its listener behind
# while its database dies with the session, and container-entrypoint.sh chains
# `lsnrctl start && startup`: the leftover makes the next start skip the database and
# report a bare "DATABASE STARTUP FAILED". Clearing it is safe only when this session
# has no database of its own to lose, which is what healthcheck.sh answers, and a
# listener that is not this container's refuses the request instead of stopping.
# Ignore container-readiness markers here: an interrupted initialization can
# leave them behind even when the database itself is open. The image HEALTHCHECK
# still checks those markers normally.
if ! as_oracle healthcheck.sh "${ORACLE_SID}" "container status ignore" >/dev/null 2>&1; then
    if ! stop_output=$(as_oracle lsnrctl stop 2>&1); then
        # TNS-01189 is a listener refusing our request: it answered on the TCP
        # endpoint and is not this container's, so it cannot be cleared from here.
        # The IPC endpoint reports TNS-12541 in both cases, which is why the
        # authentication failure is what gets matched and not the absence of one.
        if [[ "${stop_output}" == *TNS-01189* ]]; then
            printf '%s\n' "${stop_output}" >&2
            cat >&2 <<'EOF'

##############################################
CANNOT START: PORT 1521 IS ALREADY IN USE!
##############################################
A listener this container cannot control already answers on port 1521: a Docker
container, an Oracle installed on the host, or another chroot-distro container.
Stop it, or leave it running and start the GUI alone against its database:

  chroot-distro run --shared-display --entrypoint ./sqldeveloper.sh NAME

EOF
            exit 1
        fi
    else
        echo "CONTAINER: stopped the listener a previous run left behind."
    fi
fi

# container-entrypoint.sh only honours $ORACLE_PASSWORD on a database it
# initializes itself, so record which case this is before starting.
database_existed=false
if [ -d "${DBCONFIG}" ]; then
    database_existed=true
fi

# --nowait returns as soon as the database is open instead of tailing the alert
# log, which is what leaves the foreground for SQL Developer.
#
# No supervisor: Oracle's background processes daemonize and get reparented to
# SQL Developer, which does not reap them, so quitting the GUI can leave server
# processes behind for `chroot-distro kill`. That kills the database rather than
# shutting it down, and Oracle recovers from redo on the next start.
as_oracle env ORACLE_PASSWORD="${ORACLE_PASSWORD}" container-entrypoint.sh --nowait

# Keep the image config's password authoritative: /opt/oracle/oradata outlives a
# single start, so otherwise it would stay whatever the *first* start set.
if [ "${database_existed}" = true ]; then
    echo "CONTAINER: re-applying the configured SYS and SYSTEM password."
    as_oracle resetPassword "${ORACLE_PASSWORD}"
fi

cat <<EOF

#####################################################
Connect from SQL Developer with:
  Hostname  localhost
  Port      1521
  Service   ${ORACLE_DATABASE:-FREEPDB1}   (or ${ORACLE_SID} for the CDB)
  Username  system
  Password  ${ORACLE_PASSWORD}
#####################################################

EOF

# WORKDIR is /opt/sqldeveloper; the launcher expects to be started from there.
exec ./sqldeveloper.sh "$@"
