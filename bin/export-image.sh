#!/bin/bash

set -o nounset -o pipefail -o errexit

INPUT=$1
DOCKER=${DOCKER-docker}

TMP=$(mktemp -d)
trap "[ -f $TMP/container ] && (cat $TMP/container | xargs $DOCKER rm); rm -rf $TMP" EXIT

$DOCKER run --cidfile="$TMP/container" --entrypoint=/bin/true "$INPUT"
$DOCKER export $(<"$TMP/container")
