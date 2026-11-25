#!/usr/bin/env bash
set -euo pipefail

: "${ORACLE_PASSWORD:?is empty; the image config bakes a password in, so this was overridden with nothing}"

ORACLE_BASE="${ORACLE_BASE:-/opt/oracle}"
ORACLE_SID="${ORACLE_SID:-FREE}"
DBCONFIG="${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"

if [ -d "${ORACLE_BASE}/oradata/dbconfig/XE" ]; then
    cat >&2 <<'EOF'
CONTAINER: Oracle XE data detected; it cannot be reused by this Oracle Free image.
Back up/export your XE schemas (for example with Oracle Data Pump), start Oracle
Free with a fresh data directory, then import them. The XE data was not changed.
EOF
    exit 1
fi

# Oracle needs a login environment so the GUI's JDK paths do not shadow its libraries.
as_oracle() { sudo -iu oracle "$@"; }

if ! as_oracle healthcheck.sh "${ORACLE_SID}" "container status ignore" >/dev/null 2>&1; then
    if ! stop_output=$(as_oracle lsnrctl stop 2>&1); then
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

database_existed=false
if [ -d "${DBCONFIG}" ]; then
    database_existed=true
fi

as_oracle env ORACLE_PASSWORD="${ORACLE_PASSWORD}" container-entrypoint.sh --nowait

if [ "${database_existed}" = true ]; then
    echo "CONTAINER: re-applying the configured SYS and SYSTEM password."
    as_oracle resetPassword "${ORACLE_PASSWORD}"
fi

if ! setup-sqldeveloper-connection; then
    echo "CONTAINER: automatic connection setup failed; SQL Developer will still start." >&2
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

exec ./sqldeveloper.sh "$@"
