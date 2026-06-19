#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:layout-test}"
EXPECTED_HOME_TARGET="/state/.enclava/config/.runtime/home-user"

docker build -t "$IMAGE_TAG" .

docker run --rm --user 0 --entrypoint /bin/sh "$IMAGE_TAG" -eu -c '
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

home_target="$(readlink /home/user)"
if [ "$home_target" != "$expected_home_target" ]; then
    echo "expected /home/user -> $expected_home_target, found $home_target" >&2
    exit 1
fi

user_entry="$(getent passwd user)"
case "$user_entry" in
    user:x:10001:10001:*)
        ;;
    *)
        echo "expected user passwd entry with uid/gid 10001, found $user_entry" >&2
        exit 1
        ;;
esac

if ! id -nG user | tr " " "\n" | grep -qx sudo; then
    echo "expected user to be in sudo group" >&2
    exit 1
fi

if [ "$(stat -c "%a" /etc/sudoers.d/user-nopasswd)" != "440" ]; then
    echo "expected /etc/sudoers.d/user-nopasswd mode 440" >&2
    exit 1
fi

if ! grep -qx "user ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/user-nopasswd; then
    echo "expected passwordless sudoers drop-in for user" >&2
    exit 1
fi
' sh "$EXPECTED_HOME_TARGET"
