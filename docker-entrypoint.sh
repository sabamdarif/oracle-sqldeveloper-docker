#!/usr/bin/env bash
# Start Oracle XE, then hand the container over to SQL Developer. Whoever enters
# -- `sqldev` from the image USER, or root with `--user root` -- the database has
# to be started by `oracle`, which is what the image's sudoers rule is for.
set -euo pipefail

: "${ORACLE_PASSWORD:?is empty; the image config bakes a password in, so this was overridden with nothing}"

ORACLE_BASE="${ORACLE_BASE:-/opt/oracle}"
ORACLE_SID="${ORACLE_SID:-XE}"
DBCONFIG="${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"

# `sudo -i` gives oracle its own login environment and drops ours, which matters
# here: the JDK paths this image exports would otherwise shadow Oracle's own
# libraries.
as_oracle() { sudo -iu oracle "$@"; }

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
  Service   ${ORACLE_DATABASE:-XEPDB1}   (or ${ORACLE_SID} for the CDB)
  Username  system
  Password  ${ORACLE_PASSWORD}
#####################################################

EOF

# WORKDIR is /opt/sqldeveloper; the launcher expects to be started from there.
exec ./sqldeveloper.sh "$@"
