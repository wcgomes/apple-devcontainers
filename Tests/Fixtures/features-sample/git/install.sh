#!/bin/sh
set -e
echo "installing git fixture"
mkdir -p /usr/local/etc/adev-features
echo "git:fixture" >> /usr/local/etc/adev-features/installed.txt
