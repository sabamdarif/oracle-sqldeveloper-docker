#!/usr/bin/env bash
set -e

export JAVA_HOME=/opt/java
export PATH="/opt/java/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/java/lib/jli:/opt/java/lib/server:/opt/java/lib:${LD_LIBRARY_PATH:-}"

cd /opt/sqldeveloper

exec bash ./sqldeveloper.sh "$@"
