#!/bin/sh
set -eu

# This script runs inside the influxdb:1.8 container at init time.
# It uses environment variables provided to the container to create
# the initial database and users.

# Environment variables expected:
# INFLUXDB_DB, INFLUXDB_ADMIN_USER, INFLUXDB_ADMIN_PASSWORD,
# INFLUXDB_USER, INFLUXDB_USER_PASSWORD

if [ -z "${INFLUXDB_DB:-}" ]; then
  echo "[init] INFLUXDB_DB not set, skipping initialization"
  exit 0
fi

# Wait until InfluxDB is accepting connections
n=0
until influx -execute "SHOW DATABASES" >/dev/null 2>&1; do
  n=$((n+1))
  if [ $n -ge 30 ]; then
    echo "[init] timeout waiting for influxdb"
    exit 1
  fi
  sleep 1
done

# Create database
echo "[init] creating database ${INFLUXDB_DB}"
influx -execute "CREATE DATABASE \"${INFLUXDB_DB}\""

# Create admin user if provided
if [ -n "${INFLUXDB_ADMIN_USER:-}" ] && [ -n "${INFLUXDB_ADMIN_PASSWORD:-}" ]; then
  echo "[init] creating admin user ${INFLUXDB_ADMIN_USER}"
  influx -execute "CREATE USER \"${INFLUXDB_ADMIN_USER}\" WITH PASSWORD '${INFLUXDB_ADMIN_PASSWORD}' WITH ALL PRIVILEGES"
fi

# Create normal user if provided
if [ -n "${INFLUXDB_USER:-}" ] && [ -n "${INFLUXDB_USER_PASSWORD:-}" ]; then
  echo "[init] creating user ${INFLUXDB_USER}"
  influx -execute "CREATE USER \"${INFLUXDB_USER}\" WITH PASSWORD '${INFLUXDB_USER_PASSWORD}'"
  echo "[init] granting privileges to ${INFLUXDB_USER} on ${INFLUXDB_DB}"
  influx -execute "GRANT ALL ON \"${INFLUXDB_DB}\" TO \"${INFLUXDB_USER}\""
fi
