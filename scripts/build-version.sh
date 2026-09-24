#!/bin/sh
# Prints the release version for a CI run: MAJOR.MINOR.PATCH, where the patch number is the run
# number modulo 100 and every full hundred of runs moves the minor number up by one. With base 2.0,
# run 99 is 2.0.99 and run 100 is 2.1.0. Versions only ever grow with the run number, which is
# what Sparkle needs to offer each release as an update to the previous ones.
#
# usage: build-version.sh <MARKETING_VERSION, e.g. 2.0> <run number>
set -eu

base=$1
run=$2
case "$run" in ''|*[!0-9]*) echo "invalid run number: $run" >&2; exit 1 ;; esac
case "$base" in *.*) ;; *) echo "invalid base version: $base (expected MAJOR.MINOR)" >&2; exit 1 ;; esac
major=$(echo "$base" | cut -d. -f1)
minor=$(echo "$base" | cut -d. -f2)
case "$major$minor" in ''|*[!0-9]*) echo "invalid base version: $base" >&2; exit 1 ;; esac
echo "${major}.$((minor + run / 100)).$((run % 100))"
