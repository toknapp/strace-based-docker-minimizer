#!/usr/bin/env bash

# Make Bash's error handling strict(er).
set -o nounset -o pipefail -o errexit

# Be compatible with both Linux and macOS
if command -v realpath 1>&- 2>&-; then
    CANONICALIZE_FILENAME="realpath"
else
    CANONICALIZE_FILENAME="readlink -f"
fi

# Get directory where this script is in to get at other scripts in there.
SCRIPTS_DIR=$($CANONICALIZE_FILENAME "$0" | xargs dirname)

# Declare default settings.
DOCKER=${DOCKER-docker}
DOCKER_FILE=${DOCKER_FILE-Dockerfile}
DOCKER_CONTEXT=${DOCKER_CONTEXT-.}
FILTER=${FILTER-.dockerinclude}
OUTPUT=${OUTPUT-.docker-image}

# Read command line.
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

# Make temporary dir, contains:
# - Host dir of mounted volume with in&output of "filter runner"
TMP=$($CANONICALIZE_FILENAME $(mktemp -d tmp.XXXXXXXXXXX))

# Set up removal of temp dir, even in error cases.
trap "rm -rf $TMP" EXIT

# Build the original Docker image, yet to be minimized, but without any modifications yet.
$DOCKER build --iidfile="$TMP/base.image" -f "$DOCKER_FILE" "$DOCKER_CONTEXT" >&2
FROM=$(cat "$TMP/base.image")

# Extract from the original Docker image what has to go into the Dockerfile of the minimized image.
ENTRYPOINT=$($DOCKER inspect "$FROM" | jq --compact-output ".[0].Config.Entrypoint")
WORKDIR=$($DOCKER inspect "$FROM" | jq --raw-output ".[0].Config.WorkingDir")

# Bundle all changes to be made to the Dockerfile of the minimized image via
# `docker import --change`
changes() {
    echo "WORKDIR ${WORKDIR:-/}"
    echo "ENTRYPOINT $ENTRYPOINT"
    $DOCKER inspect "$FROM" \
        | jq --raw-output ".[0].Config.Env[]" \
        | sed 's/\(.*\)/ENV \1/'
}

# Create host directory to mount as Docker volume in the "filter runner" to
# share in&output files between host and "filter runner" Docker container.
mkdir -p "$TMP/filter-runner/volume"

# Export the contents of the original Docker image into a tar file.
"$SCRIPTS_DIR/export-image.sh" "$FROM" > "$TMP/filter-runner/volume/exported-full-image.tar"

# Copy the filter file into the Docker volume.
cp "$FILTER" "$TMP/filter-runner/volume/.dockerinclude"

# Build and run the "filter runner" Docker container.
# This is a separate Docker container because extracting the exported Docker
# image onto a macOS file system might fail on some Linux special files.
# We get back yet another tar file, but only with the selected / filtered files.
$DOCKER build --iidfile="$TMP/filter-runner/filter-runner.image" -f "$SCRIPTS_DIR/filter-runner.dockerfile" "$SCRIPTS_DIR" >&2
FILTER_RUNNER_IMAGE_ID=$(cat "$TMP/filter-runner/filter-runner.image")
$DOCKER run --rm --volume="$TMP/filter-runner/volume:/filter-runner/volume" "$FILTER_RUNNER_IMAGE_ID" >&2

# Import the filtered image content as a "minimized" Docker image, while
# applying the previously recorded changes to it's Dockerfile.
changes | sed 's/^/--change=/' | tr '\n' '\0' \
    | xargs -0 $DOCKER import "$TMP/filter-runner/volume/content.tar.gz" > "$OUTPUT"
