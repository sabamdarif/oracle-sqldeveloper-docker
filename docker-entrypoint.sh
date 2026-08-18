#!/usr/bin/env bash
# Start Oracle XE, then hand the container over to SQL Developer.
set -e

# `sudo -i` gives the oracle user its own login environment (ORACLE_HOME, PATH,
# $HOME as the working directory) but drops ours, so the password is passed
# through explicitly. `--nowait` returns as soon as the database is open
# instead of tailing the alert log.
#
# ponytail: no supervisor. Oracle's background processes daemonize themselves
# and get reparented to SQL Developer, which does not reap them -- run with
# `docker run --init` if the leftover dedicated-server processes bother you.
# `docker stop` also kills the database instead of shutting it down cleanly;
# Oracle recovers from redo on the next start. Add a supervisor (s6, tini +
# script) only if either actually gets in the way.
sudo -iu oracle env ORACLE_PASSWORD="${ORACLE_PASSWORD}" \
    container-entrypoint.sh --nowait

# WORKDIR is /opt/sqldeveloper; the launcher expects to be started from there.
exec ./sqldeveloper.sh "$@"
