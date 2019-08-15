#!/bin/bash

set -o nounset -o pipefail -o errexit

DOCKER=${DOCKER-docker}
DOCKER_RUN_OPTS=${DOCKER_RUN_OPTS-}
TRIGGER_CMD=${TRIGGER_CMD-}
WITH_RUNNING_CONTAINER=${WITH_RUNNING_CONTAINER-1}
TRACE_FILE_IN_CONTAINER=${TRACE_FILE_IN_CONTAINER-/tmp/trace}
while getopts "fd:i:p:t:rR" OPT; do
    case $OPT in
        d) DOCKER_OPTS="$DOCKER_OPTS $OPTARG" ;;
        s) STRACE_OPTS="$STRACE_OPTS $OPTARG" ;;
        i) INSTALL_STRACE_CMD="$OPTARG" ;;
        p) PACKAGE_MANAGER="$OPTARG" ;;
        t) TRIGGER_CMD="$OPTARG" ;;
        r) WITH_RUNNING_CONTAINER=1 ;;
        R) WITH_RUNNING_CONTAINER=0 ;;
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
STRACE='["strace", "-qq", "-z", "-D", "-o", "'$TRACE_FILE_IN_CONTAINER'", "-ff", "-f", "-e", "%file", "'$INTERPRETER'", "'$EXEC'"]'

ENTRYPOINT=$($DOCKER inspect "$INPUT" \
    | jq --compact-output "[$STRACE, .[0].Config.Entrypoint[1:]] | flatten"
)

cat <<EOF >> $TMP/Dockerfile
ENTRYPOINT $ENTRYPOINT
EOF

$DOCKER build --iidfile="$TMP/extended.image" "$TMP" >&2

TRACE_OUTPUT=$TMP/trace

if [ -z "$TRIGGER_CMD" ]; then
    set +o errexit
    $DOCKER run --rm --cap-add=SYS_PTRACE \
        --volume="$(dirname "$TRACE_OUTPUT"):$(dirname "$TRACE_FILE_IN_CONTAINER")" \
        $DOCKER_RUN_OPTS \
        $(<"$TMP/extended.image") $@ >&2
    EXIT=$?
    set -o errexit
else
    run_trigger() {
        set +o errexit
        $TRIGGER_CMD >&2
        EXIT=$?
        set -o errexit
    }

    if [ "$WITH_RUNNING_CONTAINER" = "1" ]; then
        $DOCKER run --rm --cap-add=SYS_PTRACE --detach \
            --volume="$(dirname "$TRACE_OUTPUT"):$(dirname "$TRACE_FILE_IN_CONTAINER")" \
            --cidfile="$TMP/container" \
            $DOCKER_RUN_OPTS \
            $(<"$TMP/extended.image") $@ >/dev/null

        DOCKER_IMAGE=$(<"$TMP/extended.image") \
            DOCKER_CONTAINER=$(<"$TMP/container") \
            TRACE_FILE_IN_CONTAINER="$TRACE_FILE_IN_CONTAINER" \
            TRACE_OUTPUT="$TRACE_OUTPUT" \
            run_trigger

        $DOCKER inspect $(<"$TMP/container") >/dev/null && $DOCKER stop $(<"$TMP/container") >/dev/null
    else
        DOCKER_IMAGE=$(<"$TMP/extended.image") \
            TRACE_OUTPUT="$TRACE_OUTPUT" \
            TRACE_FILE_IN_CONTAINER="$TRACE_FILE_IN_CONTAINER" \
            run_trigger
    fi
fi

cat "$TRACE_OUTPUT".*

exit $EXIT
