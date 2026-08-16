#!/usr/bin/env bash
set -e

export JAVA_HOME=/opt/java
export PATH="/opt/java/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/java/lib:/opt/java/lib/server:${LD_LIBRARY_PATH:-}"

cd /opt/sqldeveloper

exec bash ./sqldeveloper.sh "$@"
