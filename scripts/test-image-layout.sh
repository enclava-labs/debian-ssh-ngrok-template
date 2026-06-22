#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:layout-test}"

docker build -t "$IMAGE_TAG" .

docker run --rm --user 0 --entrypoint /bin/sh "$IMAGE_TAG" -eu -c '
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

if [ ! -d /home/user ]; then
    echo "expected /home/user to be a directory" >&2
    exit 1
fi

if [ -L /home/user ]; then
    echo "expected /home/user not to be a symlink" >&2
    exit 1
fi

home_owner="$(stat -c "%u:%g" /home/user)"
if [ "$home_owner" != "10001:10001" ]; then
    echo "expected /home/user to be owned by 10001:10001, found $home_owner" >&2
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

shadow_password="$(getent shadow user | cut -d: -f2)"
case "$shadow_password" in
    [*!]*)
        echo "expected user account to be valid for public-key SSH, found locked shadow entry" >&2
        exit 1
        ;;
esac

if [ "$(stat -c "%a" /etc/sudoers.d/user-nopasswd)" != "440" ]; then
    echo "expected /etc/sudoers.d/user-nopasswd mode 440" >&2
    exit 1
fi

if ! grep -qx "user ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/user-nopasswd; then
    echo "expected passwordless sudoers drop-in for user" >&2
    exit 1
fi
' sh
