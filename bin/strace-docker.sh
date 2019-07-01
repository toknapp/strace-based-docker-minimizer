#!/bin/bash

set -o nounset -o pipefail -o errexit

DOCKER=${DOCKER-docker}
DOCKER_RUN_OPTS=${DOCKER_RUN_OPTS-}
TRIGGER_CMD=${TRIGGER_CMD-}
while getopts "fd:i:p:t:" OPT; do
    case $OPT in
        d) DOCKER_OPTS="$DOCKER_OPTS $OPTARG" ;;
        s) STRACE_OPTS="$STRACE_OPTS $OPTARG" ;;
        i) INSTALL_STRACE_CMD="$OPTARG" ;;
        p) PACKAGE_MANAGER="$OPTARG" ;;
        t) TRIGGER_CMD="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

INPUT=$1
shift 1

if [[ ! -v INSTALL_STRACE_CMD ]]; then
    case ${PACKAGE_MANAGER-} in
        apk) INSTALL_STRACE_CMD="apk add --update strace binutils" ;;
        apt|apt-get) INSTALL_STRACE_CMD="apt-get update && apt-get install -y strace binutils";;
        *) echo "PACKAGE_MANAGER variable not set" >&2; exit 2 ;;
    esac
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat <<EOF > $TMP/Dockerfile
FROM $INPUT
RUN $INSTALL_STRACE_CMD
EOF

$DOCKER build --iidfile="$TMP/extended.image" "$TMP" >&2

EXEC=$($DOCKER inspect "$INPUT" | jq -r ".[0].Config.Entrypoint[0]")
EXEC=$($DOCKER run --rm \
    --entrypoint="/bin/sh" \
    $(<"$TMP/extended.image") \
    -c 'which "'$EXEC'"'
)

INTERPRETER=$($DOCKER run --rm \
    --entrypoint="readelf" \
    $(<"$TMP/extended.image") \
    --program-headers "$EXEC" \
    | grep -o '\[Requesting program interpreter:\s\+[^]]\+\]' \
    | sed 's/\[Requesting program interpreter:\s\+\([^]]\+\)]/\1/'
)

# prepare to run strace
STRACE='["strace", "-qq", "-D", "-o", "/trace", "-f", "-e", "file", "'$INTERPRETER'", "'$EXEC'"]'

ENTRYPOINT=$($DOCKER inspect "$INPUT" \
    | jq --compact-output "[$STRACE, .[0].Config.Entrypoint[1:]] | flatten"
)

cat <<EOF >> $TMP/Dockerfile
ENTRYPOINT $ENTRYPOINT
EOF

$DOCKER build --iidfile="$TMP/extended.image" "$TMP" >&2

touch "$TMP/trace" && chmod 666 "$TMP/trace"

if [ -z "$TRIGGER_CMD" ]; then
    set +o errexit
    $DOCKER run --rm \
        --cap-add=SYS_PTRACE --volume="$TMP/trace":/trace \
        $DOCKER_RUN_OPTS \
        $(<"$TMP/extended.image") $@ >&2
    EXIT=$?
    set -o errexit
else
    $DOCKER run --rm \
        --cap-add=SYS_PTRACE --volume="$TMP/trace":/trace \
        --cidfile="$TMP/container" --detach \
        $DOCKER_RUN_OPTS \
        $(<"$TMP/extended.image") $@ >/dev/null

    set +o errexit
    $TRIGGER_CMD >&2
    EXIT=$?
    set -o errexit

    $DOCKER inspect $(<"$TMP/container") >/dev/null && $DOCKER stop $(<"$TMP/container")
fi

grep -v "\--- SIG" < "$TMP/trace"
exit $EXIT
