#!/usr/bin/env bash
set -e

cd /opt/sqldeveloper

exec bash ./sqldeveloper.sh "$@"
