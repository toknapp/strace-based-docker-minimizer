#!/bin/bash

set -o pipefail -o errexit

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

tee ~/tmp/trace | grep -v "^--- SIG.*---$" | grep -v "<unfinished ...>" | while read -r L; do
    SYSCALL=$(sed 's/^\(\w\+\)(.*$/\1/' <<< "$L")
    ARGS=$(sed 's/^\w\+(\(.*\)$/\1/' <<< "$L")

    grep -cq "stat$" <<< "$SYSCALL" && grep -cq "S_IFDIR" <<< "$ARGS" && continue

    case "$SYSCALL" in
        execve|open|access|readlink|stat|lstat) # first argument
            FN=$(sed 's/^"\([^"]*\)".*$/\1/' <<< "$ARGS") ;;
        openat) # second argument
            FN=$(sed 's/^[^,]*,\s\+"\([^"]*\)".*$/\1/' <<< "$ARGS") ;;
        getcwd|mkdir|statfs|chown|unlink|rename|chdir) # ignore
            continue;;
        *) echo 1>&2 "unhandled syscall $SYSCALL"; exit 2;;
    esac

    grep -cq '^/dev' <<< "$FN" && continue
    grep -cq '^/sys' <<< "$FN" && continue
    grep -cq '^/proc' <<< "$FN" && continue
    grep -cq '^/tmp' <<< "$FN" && continue

    grep -cq "__pycache__" <<< "$FN" && continue

    if grep -cq "/python.*/site-packages/.*\.dist-info$" <<< "$FN"; then
        echo "d	$FN"
    else
        echo "f	$FN"
    fi
done | sort -u
