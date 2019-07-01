#!/bin/bash

set -o nounset -o pipefail -o errexit

DOCKER=${DOCKER-docker}
FROM=
FILTER=
while getopts "f:v:" OPT; do
    case $OPT in
        f) FROM=$OPTARG ;;
        v) FILTER=$OPTARG ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

ENTRYPOINT=$($DOCKER inspect "$FROM" | jq --compact-output ".[0].Config.Entrypoint")
WORKDIR=$($DOCKER inspect "$FROM" | jq --raw-output ".[0].Config.WorkingDir")

"$SCRIPTS_DIR/export-image.sh" "$FROM" \
    | "$SCRIPTS_DIR/filter-tarball.sh" -v "$FILTER" \
    | $DOCKER import --change="WORKDIR ${WORKDIR:-/}" --change="ENTRYPOINT $ENTRYPOINT" -
