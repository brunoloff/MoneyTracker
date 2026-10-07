#!/bin/sh
# Compatibility entry point for previously installed application shortcuts.
exec "$(dirname -- "$0")/run-native.sh" "$@"
