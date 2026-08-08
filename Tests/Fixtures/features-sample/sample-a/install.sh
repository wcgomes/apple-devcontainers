#!/bin/sh
set -e
echo "installing sample-a greeting=${GREETING:-hello}"
mkdir -p /usr/local/etc/adev-features
echo "sample-a:${GREETING:-hello}" >> /usr/local/etc/adev-features/installed.txt
