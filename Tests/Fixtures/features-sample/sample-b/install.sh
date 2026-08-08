#!/bin/sh
set -e
echo "installing sample-b mode=${MODE:-default}"
mkdir -p /usr/local/etc/adev-features
echo "sample-b:${MODE:-default}" >> /usr/local/etc/adev-features/installed.txt
