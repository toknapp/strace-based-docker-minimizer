#!/bin/bash

set -o nounset -o pipefail -o errexit

SCRIPTS_DIR=$(readlink -f "$0" | xargs dirname)
DOCKER=${DOCKER-docker}
DOCKER_FILE=${DOCKER_FILE-Dockerfile}
DOCKER_CONTEXT=${DOCKER_CONTEXT-.}
FILTER=${FILTER-.dockerinclude}
OUTPUT=${OUTPUT-.docker-image}
while getopts "f:c:v:o:" OPT; do
    case $OPT in
        f) DOCKER_FILE=$OPTARG ;;
        c) DOCKER_CONTEXT=$OPTARG ;;
        v) FILTER=$OPTARG ;;
        o) OUTPUT=$OPTARG ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

$DOCKER build --iidfile="$TMP/base.image" -f "$DOCKER_FILE" \
    "$DOCKER_CONTEXT" >&2
FROM=$(cat "$TMP/base.image")

ENTRYPOINT=$($DOCKER inspect "$FROM" | jq --compact-output ".[0].Config.Entrypoint")
WORKDIR=$($DOCKER inspect "$FROM" | jq --raw-output ".[0].Config.WorkingDir")

changes() {
    echo "WORKDIR ${WORKDIR:-/}"
    echo "ENTRYPOINT $ENTRYPOINT"
    $DOCKER inspect "$FROM" \
        | jq --raw-output ".[0].Config.Env[]" \
        | sed 's/\(.*\)/ENV \1/'
}

"$SCRIPTS_DIR/export-image.sh" "$FROM" \
    | "$SCRIPTS_DIR/filter-tarball.sh" -v "$FILTER" \
    | xargs -0 --arg-file=<(changes | sed 's/^/--change=/' | tr '\n' '\0') \
        $DOCKER import - > "$OUTPUT"
