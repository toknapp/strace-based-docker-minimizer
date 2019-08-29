#!/bin/bash

set -o nounset -o pipefail -o errexit

DOCKER=${DOCKER-docker}
DOCKER_RUN_OPTS=${DOCKER_RUN_OPTS-}
TRIGGER_CMD=${TRIGGER_CMD-}
WITH_RUNNING_CONTAINER=${WITH_RUNNING_CONTAINER-1}
TRACE_DIR_IN_CONTAINER=${TRACE_DIR_IN_CONTAINER-/tmp/traces}
DOCKER_FILE=${DOCKER_FILE-Dockerfile}
DOCKER_CONTEXT=${DOCKER_CONTEXT-.}
OUTPUT=${OUTPUT-.dockerinclude}
INSTALL_STRACE_CMD=
while getopts "f:c:d:i:p:t:rRo:-" OPT; do
    case $OPT in
        f) DOCKER_FILE=$OPTARG ;;
        c) DOCKER_CONTEXT=$OPTARG ;;
        d) DOCKER_RUN_OPTS="$DOCKER_RUN_OPTS $OPTARG" ;;
        i) INSTALL_STRACE_CMD="$OPTARG" ;;
        p) PACKAGE_MANAGER="$OPTARG" ;;
        t) TRIGGER_CMD="$OPTARG" ;;
        r) WITH_RUNNING_CONTAINER=1 ;;
        R) WITH_RUNNING_CONTAINER=0 ;;
        o) OUTPUT=$OPTARG ;;
        -) break ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

TMP=$(realpath $(mktemp -d tmp.XXXXXXXXXXX))
trap "rm -rf $TMP" EXIT

$DOCKER build --iidfile="$TMP/base.image" -f "$DOCKER_FILE" \
    "$DOCKER_CONTEXT" >&2
INPUT=$(cat "$TMP/base.image")

if [ -z "$INSTALL_STRACE_CMD" ]; then
    case ${PACKAGE_MANAGER-} in
        apk) INSTALL_STRACE_CMD="apk add --update strace binutils" ;;
        apt|apt-get) INSTALL_STRACE_CMD="apt-get update && apt-get install -y strace binutils";;
        *) echo "PACKAGE_MANAGER variable not set" >&2; exit 2 ;;
    esac
fi

cat <<EOF > $TMP/Dockerfile
FROM $INPUT
RUN $INSTALL_STRACE_CMD
EOF

$DOCKER build --iidfile="$TMP/extended.image" "$TMP" >&2

EXEC=$($DOCKER inspect "$INPUT" | jq -r ".[0].Config.Entrypoint[0]")
EXEC=$($DOCKER run --rm \
    --entrypoint="/bin/sh" \
    "$(<"$TMP/extended.image")" \
    -c 'which "'$EXEC'"'
)

INTERPRETER=$($DOCKER run --rm \
    --entrypoint="readelf" \
    $(<"$TMP/extended.image") \
    --program-headers "$EXEC" \
    | grep -o '\[Requesting program interpreter:\s\+[^]]\+\]' \
    | sed 's/\[Requesting program interpreter:[[:space:]]*\(.*\)]/\1/'
)

# prepare to run strace
cat <<EOF > "$TMP/strace-wrapper.sh"
#!/bin/sh
OUTPUT=$TRACE_DIR_IN_CONTAINER/trace.\$(tr -dc A-Za-z0-9 < /dev/urandom | head -c5)
exec strace -qq -z -D -o "\$OUTPUT" -ff -f -e file "$INTERPRETER" "\$@"
EOF
chmod +x "$TMP/strace-wrapper.sh"

ENTRYPOINT=$($DOCKER inspect "$INPUT" \
    | jq --compact-output "[[\"/bin/strace-wrapper.sh\"], .[0].Config.Entrypoint] | flatten"
)

cat <<EOF >> $TMP/Dockerfile
ADD strace-wrapper.sh /bin/strace-wrapper.sh
ENTRYPOINT $ENTRYPOINT
EOF

$DOCKER build --iidfile="$TMP/extended.image" "$TMP" >&2

TRACE_OUTPUT=$TMP/traces
mkdir -p "$TRACE_OUTPUT"

if [ -z "$TRIGGER_CMD" ]; then
    set +o errexit
    $DOCKER run --rm --cap-add=SYS_PTRACE \
        --volume="$TRACE_OUTPUT:$TRACE_DIR_IN_CONTAINER" \
        $DOCKER_RUN_OPTS \
        "$(<"$TMP/extended.image")" $@ >&2
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
            --volume="$TRACE_OUTPUT:$TRACE_DIR_IN_CONTAINER" \
            --cidfile="$TMP/container" \
            $DOCKER_RUN_OPTS \
            "$(<"$TMP/extended.image")" $@ >&2

        DOCKER_CONTAINER=$(<"$TMP/container") \
            run_trigger

        $DOCKER inspect "$(<"$TMP/container")" &>/dev/null \
            && $DOCKER stop "$(<"$TMP/container")" >/dev/null
    else
        DOCKER_IMAGE="$(<"$TMP/extended.image")" \
            TRACE_OUTPUT="$TRACE_OUTPUT" \
            TRACE_DIR_IN_CONTAINER="$TRACE_DIR_IN_CONTAINER" \
            run_trigger
    fi
fi

cat "$TRACE_OUTPUT/trace".* \
    | grep -v "^--- SIG.*---$" \
    | grep -v "<unfinished ...>" \
    | while read -r L; do
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

    echo "f	$FN"
done | sort -u > "$OUTPUT"

exit $EXIT
