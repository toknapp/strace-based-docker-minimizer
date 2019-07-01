#!/bin/bash

set -o nounset -o pipefail -o errexit

DOCKER_IMAGE=
while getopts "i:" OPT; do
    case $OPT in
        i) DOCKER_IMAGE=$OPTARG ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

if [ -n "$DOCKER_IMAGE" ]; then
    CONTAINER=$(docker run --detach --rm -p 8000:5000 "$DOCKER_IMAGE")
    trap "docker stop $CONTAINER >/dev/null" EXIT
fi

timeout 5s sh -c "while ! nc -z localhost 8000; do sleep 0.2; done"
sleep 1
curl -s localhost:8000 | grep 'hello world' >/dev/null
