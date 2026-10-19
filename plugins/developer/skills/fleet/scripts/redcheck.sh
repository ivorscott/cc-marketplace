#!/usr/bin/env bash
# CI red check: deliberate shellcheck error (unterminated if), DO NOT MERGE
if [ "$1" = x ]; then
  echo hi
