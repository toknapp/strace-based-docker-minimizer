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
    if [ "$TYPE" = "f" ]; then
        if [ -f "$TMP/in/$TARGET" ]; then
            echo >&2 "including file: $TARGET $(du -h "$TMP/in/$TARGET" | cut -f1)"
            mkdir -p "$TMP/out/$(dirname "$TARGET")"
            cp -p "$TMP/in/$TARGET" "$TMP/out/$TARGET"
        elif [ -d "$TMP/in/$TARGET" ]; then
            echo >&2 "making directory: $TARGET"
            mkdir -p "$TMP/out/$TARGET"
        elif [ -h "$TMP/in/$TARGET" ]; then
            LINK=$TARGET
            TARGET=$(readlink "$TMP/in/$TARGET")
            echo >&2 "symlink: $LINK -> $TARGET"

            mkdir -p "$TMP/out/$(dirname "$TARGET")"
            mkdir -p "$TMP/out/$(dirname "$LINK")"
            cp "$TMP/in/$TARGET" "$TMP/out/$TARGET" 1>&2
            cp -d "$TMP/in/$LINK" "$TMP/out/$LINK" 1>&2
        elif [ ! -e "$TMP/in/$TARGET" ]; then
            echo >&2 "skipping file: $TARGET"
        else
            echo >&2 "don't know what to do with: $TARGET"
            exit 2
        fi
    elif [ "$TYPE" = "d" ]; then
        echo >&2 "including dir: $TARGET $(du -sh "$TMP/in/$TARGET" | cut -f1)"
        mkdir -p "$TMP/out/$(dirname "$TARGET")"
        cp -pr "$TMP/in/$TARGET" "$TMP/out/$(dirname "$TARGET")" 1>&2
    else
        echo >&2 "skipping unknown type: $TYPE"
    fi
}

cat "$FILTER" | while IPS=\t read TYPE TARGET; do extract; done
tar -cf "$OUTPUT" -C "$TMP/out" .
