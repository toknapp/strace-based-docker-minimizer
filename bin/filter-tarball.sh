#!/bin/bash

set -o nounset -o pipefail -o errexit

FILTER=
INPUT=-
OUTPUT=-
while getopts "i:o:v:" OPT; do
    case $OPT in
        i) INPUT=$OPTARG ;;
        o) OUTPUT=$OPTARG ;;
        v) FILTER=$OPTARG ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/in"
tar --force-local -xf "$INPUT" -C "$TMP/in"

extract() {
    if [ -e "$TMP/in/$1" -a ! -d "$TMP/in/$1" ]; then
        echo >&2 "including: $1 $(du -h "$TMP/in/$1" | cut -f1)"
        mkdir -p "$TMP/out/$(dirname "$1")"
        cp "$TMP/in/$1" "$TMP/out/$1"
    elif [ -h "$TMP/in/$1" ]; then
        TARGET=$(readlink "$TMP/in/$1" | sed 's,^/,,')
        extract "$TARGET"

        echo >&2 "symlink: $1 -> $TARGET"

        mkdir -p "$TMP/out/$(dirname "$1")"
        ln -sr "$TMP/out/$TARGET" "$TMP/out/$1"
    else
        echo >&2 "skipping: $1"
    fi
}

grep '^/' "$FILTER" \
    | sed 's,^/,,' \
    | while read f; do extract "$f"; done
tar -cf "$OUTPUT" -C "$TMP/out" .
