#!/bin/bash

set -o pipefail -o errexit

grep -v "= -1" \
    | sed 's/^[^"]\+"\([^"]*\)".*$/\1/' | sort -u \
    | grep -v '^/dev' \
    | grep -v '^/sys' \
    | grep -v '^/proc' \
    | grep -v '^/tmp'
