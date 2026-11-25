#!/usr/bin/env bash
set -euo pipefail

case "${SQLDEVELOPER_AUTO_CONNECTION:-true}" in
false | 0) exit 0 ;;
esac

exec "${JAVA_HOME:-/opt/java}/bin/java" \
    -Xmx64m \
    -Duser.home="${HOME:?}" \
    -cp "/usr/local/lib/sqldeveloper-bootstrap:/opt/sqldeveloper/sqldeveloper/lib/*" \
    SeedSqlDeveloperConnection /opt/sqldeveloper
