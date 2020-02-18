#!/usr/bin/env bash

# Make Bash's error handling strict(er).
set -o nounset -o pipefail -o errexit

# Declare default settings.
DOCKER=${DOCKER-docker}
DOCKER_RUN_OPTS=${DOCKER_RUN_OPTS-}
TRIGGER_CMD=${TRIGGER_CMD-}
DELAY_TRIGGER_SECONDS=${DELAY_TRIGGER_SECONDS-10}
WITH_RUNNING_CONTAINER=${WITH_RUNNING_CONTAINER-1}
TRACE_DIR_IN_CONTAINER=${TRACE_DIR_IN_CONTAINER-/tmp/traces}
DOCKER_FILE=${DOCKER_FILE-Dockerfile}
DOCKER_CONTEXT=${DOCKER_CONTEXT-.}
OUTPUT=${OUTPUT-.dockerinclude}
INSTALL_STRACE_CMD=

# Read command line.
while getopts "f:c:d:i:p:s:t:rRo:-" OPT; do
    case $OPT in
        f) DOCKER_FILE=$OPTARG ;;
        c) DOCKER_CONTEXT=$OPTARG ;;
        d) DOCKER_RUN_OPTS="$DOCKER_RUN_OPTS $OPTARG" ;;
        i) INSTALL_STRACE_CMD="$OPTARG" ;;
        p) PACKAGE_MANAGER="$OPTARG" ;;
        s) DELAY_TRIGGER_SECONDS=$OPTARG ;;
        t) TRIGGER_CMD="$OPTARG" ;;
        r) WITH_RUNNING_CONTAINER=1 ;;
        R) WITH_RUNNING_CONTAINER=0 ;;
        o) OUTPUT=$OPTARG ;;
        -) break ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))

# Make temporary dir, contains:
# - Docker context for strace-enabled "Docker-image-under-test"
# - Host dir of mounted volume with strace output
TMP=$(realpath $(mktemp -d tmp.XXXXXXXXXXX))

# Set up removal of temp dir, even in error cases.
trap "rm -rf $TMP" EXIT

# Build the "Docker-image-under-test", without any strace additions just
# yet, and record the image ID,
$DOCKER build --no-cache --iidfile="$TMP/base.image" -f "$DOCKER_FILE" \
    "$DOCKER_CONTEXT" >&2

# Use the "Docker-image-under-test" image as base image for another
# strace-enabled Docker image.
BASE_IMAGE_ID=$(cat "$TMP/base.image")

# Determine how to install strace, as given by the -p or -i CLI arg.
# `apk` is used by Alpine Linux, and `apt` by Debian and Ubuntu.
if [ -z "$INSTALL_STRACE_CMD" ]; then
    case ${PACKAGE_MANAGER-} in
        apk) INSTALL_STRACE_CMD="apk add --update strace binutils" ;;
        apt|apt-get) INSTALL_STRACE_CMD="apt-get update && apt-get install -y strace binutils";;
        *) echo "PACKAGE_MANAGER variable not set" >&2; exit 2 ;;
    esac
fi

# Prepare a Dockerfile for the strace-enabled Docker image,
cat <<EOF > $TMP/Dockerfile.strace-installing-layer
FROM $BASE_IMAGE_ID
RUN $INSTALL_STRACE_CMD
EOF

# Build the strace-enabled Docker image, and record the image ID.
$DOCKER build --iidfile="$TMP/strace-installing.image" -f "$TMP/Dockerfile.strace-installing-layer" "$TMP" >&2

STRACE_INSTALLING_IMAGE_ID=$(cat "$TMP/strace-installing.image")

# Extract command of the entry point of the "Docker-image-under-test" image.
EXEC=$($DOCKER inspect "$BASE_IMAGE_ID" | jq -r ".[0].Config.Entrypoint[0]")

# Determine actual ELF executable of the entry point command of the
# "Docker-image-under-test".
EXEC=$($DOCKER run --rm \
    --entrypoint="/bin/sh" \
    "$STRACE_INSTALLING_IMAGE_ID" \
    -c 'which "'$EXEC'"'
)

# Determine the requested program interpreter from the ELF executable of the
# entry point command of the "Docker-image-under-test". In the context of ELF on
# Linux, the most often used "interpreter" is /lib64/ld-linux-x86-64.so.2 ,
# which is responsible for loading dynamically linked shared libraries. But
# exceptions exist, that's why we are not hard-coding the interpreter, but look
# it up in the ELF program headers.
# `readelf` got installed with the `binutils` Linux package, that's why we are
# running STRACE_INSTALLING_IMAGE here.
# See https://lwn.net/Articles/631631/ , section "Dynamically linked programs"
ELF_INTERPRETER=$($DOCKER run --rm \
    --entrypoint="readelf" \
    "$STRACE_INSTALLING_IMAGE_ID" \
    --program-headers "$EXEC" \
    | grep -o '\[Requesting program interpreter:\s\+[^]]\+\]' \
    | sed -E 's/\[Requesting program interpreter:[[:space:]]*(.*)]/\1/'
)

# Create a wrapper script to attach strace to the entry point command of the
# "Docker-image-under-test".
# See http://man7.org/linux/man-pages/man1/strace.1.html for the meaning of the
# strace CLI options used here.
cat <<EOF > "$TMP/strace-wrapper.sh"
#!/bin/sh
OUTPUT=$TRACE_DIR_IN_CONTAINER/trace.\$(tr -dc A-Za-z0-9 < /dev/urandom | head -c5)
exec strace -qq -z -D -o "\$OUTPUT" -ff -f -e file "$ELF_INTERPRETER" "\$@"
EOF
chmod +x "$TMP/strace-wrapper.sh"

# Re-write the entry point of the "Docker-image-under-test" to include the
# strace wrapper script.
STRACE_PREPENDED_ENTRYPOINT=$($DOCKER inspect "$BASE_IMAGE_ID" \
    | jq --compact-output "[[\"/bin/strace-wrapper.sh\"], [\"$EXEC\"], .[0].Config.Entrypoint[1:]] | flatten"
)

# Create another Dockerfile which actually *runs* strace.
cp $TMP/Dockerfile.strace-installing-layer $TMP/Dockerfile.strace-running-layer
cat <<EOF >> $TMP/Dockerfile.strace-running-layer
ADD strace-wrapper.sh /bin/strace-wrapper.sh
ENTRYPOINT $STRACE_PREPENDED_ENTRYPOINT
EOF

# Build a Docker image which *runs* strace.
$DOCKER build --iidfile="$TMP/strace-running.image" -f "$TMP/Dockerfile.strace-running-layer" "$TMP" >&2

STRACE_RUNNING_IMAGE_ID=$(cat "$TMP/strace-running.image")

# Create host directory to mount as Docker volume to extract the strace output
# out of the Docker container.
TRACE_OUTPUT=$TMP/traces
mkdir -p "$TRACE_OUTPUT"

if [ -z "$TRIGGER_CMD" ]; then
    # Run strace-enabled Docker container without any auxilliary trigger
    # commands.
    set +o errexit
    $DOCKER run --rm --cap-add=SYS_PTRACE \
        --volume="$TRACE_OUTPUT:$TRACE_DIR_IN_CONTAINER" \
        $DOCKER_RUN_OPTS \
        "$STRACE_RUNNING_IMAGE_ID" $@ >&2
    EXIT=$?
    set -o errexit
else
    # Wrap the auxilliary trigger command into a shell function which lets us
    # record the exit status of the trigger command.
    run_trigger() {
        set +o errexit
        $TRIGGER_CMD >&2
        EXIT=$?
        set -o errexit
    }

    if [ "$WITH_RUNNING_CONTAINER" = "1" ]; then
        # Run strace-enabled Docker container together with an auxilliary
        # trigger command.
        $DOCKER run --rm --cap-add=SYS_PTRACE --detach \
            --volume="$TRACE_OUTPUT:$TRACE_DIR_IN_CONTAINER" \
            --cidfile="$TMP/strace-running.container" \
            $DOCKER_RUN_OPTS \
            "$STRACE_RUNNING_IMAGE_ID" $@ >&2

        STRACE_RUNNING_CONTAINER_ID=$(cat "$TMP/strace-running.container")

        # Delay the trigger command to give the container time to boot up.
        sleep $DELAY_TRIGGER_SECONDS

        # Run the auxilliary trigger command.
        DOCKER_CONTAINER="$STRACE_RUNNING_CONTAINER_ID" \
            run_trigger

        # Stop the Docker container.
        $DOCKER inspect "$STRACE_RUNNING_CONTAINER_ID" &>/dev/null \
            && $DOCKER stop "$STRACE_RUNNING_CONTAINER_ID" >/dev/null
    else
        # Just run the auxilliary trigger command, which in this case is
        # responsible for starting the Docker container.
        DOCKER_IMAGE="$STRACE_RUNNING_IMAGE_ID" \
            TRACE_OUTPUT="$TRACE_OUTPUT" \
            TRACE_DIR_IN_CONTAINER="$TRACE_DIR_IN_CONTAINER" \
            run_trigger
    fi
fi

# Convert the strace output into a .dockerinclude file.
cat "$TRACE_OUTPUT/trace".* \
    | grep -v "^--- SIG.*---$" \
    | grep -v "<unfinished ...>" \
    | while read -r L; do

    SYSCALL=$(sed -E 's/^([0-9a-zA-Z_]+).*$/\1/' <<< "$L")
    ARGS=$(sed -E 's/^[0-9a-zA-Z_]+\((.*)$/\1/' <<< "$L")

    grep -cq "stat$" <<< "$SYSCALL" && grep -cq "S_IFDIR" <<< "$ARGS" && continue

    case "$SYSCALL" in
        execve|open|access|readlink|stat|lstat) # first argument
            FN=$(sed -E 's/^"([^"]*)".*$/\1/' <<< "$ARGS") ;;
        openat) # second argument
            FN=$(sed -E 's/^[^,]+,[[:space:]]*"([^"]+)".*$/\1/' <<< "$ARGS") ;;
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
