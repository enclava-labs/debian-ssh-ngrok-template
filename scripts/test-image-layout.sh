#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:layout-test}"
EXPECTED_HOME_TARGET="/state/.enclava/config/.runtime/home-lio"

docker build -t "$IMAGE_TAG" .

docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" -eu -c '
expected_home_target="$1"

if [ ! -d /state ]; then
    echo "expected /state to exist" >&2
    exit 1
fi

state_entry="$(find /state -mindepth 1 -maxdepth 1 -print -quit)"
if [ -n "$state_entry" ]; then
    echo "expected /state to be an empty mountpoint, found $state_entry" >&2
    exit 1
fi

state_owner="$(stat -c "%u:%g" /state)"
if [ "$state_owner" != "10001:10001" ]; then
    echo "expected /state to be owned by 10001:10001, found $state_owner" >&2
    exit 1
fi

home_target="$(readlink /home/lio)"
if [ "$home_target" != "$expected_home_target" ]; then
    echo "expected /home/lio -> $expected_home_target, found $home_target" >&2
    exit 1
fi
' sh "$EXPECTED_HOME_TARGET"
