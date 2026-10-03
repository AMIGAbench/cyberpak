#!/bin/sh
# Calls make in the CyberPak build image (derived from apollocrossdev).
# Only the project itself is mounted; the mount of the original sources
# (FastC2P.o) that used to be needed is gone with the 020+ rework.
# The image is built on the first call; see tools/Dockerfile for the
# reason (NDK headers are root-only in the base image).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=cyberavi-x-build:latest

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[mk] building $IMAGE (once) ..." >&2
    docker build -q -t "$IMAGE" -f "$ROOT/tools/Dockerfile" "$ROOT/tools" >&2
fi

exec docker run --rm \
    -v "$ROOT":/src \
    -w /src -u "$(id -u):$(id -g)" \
    "$IMAGE" make "$@"
