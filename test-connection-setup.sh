#!/usr/bin/env bash
# Needs an unpacked SQL Developer 26.2 installation and a JDK 17 or newer.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${SQLDEVELOPER_HOME:?set this to an unpacked SQL Developer installation}"
java_bin="${JAVA_HOME:+${JAVA_HOME}/bin/}"
scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

"${java_bin}javac" -cp "${SQLDEVELOPER_HOME}/sqldeveloper/lib/*" \
    -d "${scratch}/classes" \
    "${here}/SeedSqlDeveloperConnection.java" "${here}/TestSeedSqlDeveloperConnection.java"
"${java_bin}java" -cp "${scratch}/classes:${SQLDEVELOPER_HOME}/sqldeveloper/lib/*:${SQLDEVELOPER_HOME}/jdbc/lib/*" \
    TestSeedSqlDeveloperConnection "${SQLDEVELOPER_HOME}" "${scratch}/profiles"
