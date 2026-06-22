#!/bin/sh
set -eu

body="$(awk '
    /^stop_sshd\(\) \{/ { in_stop = 1 }
    in_stop { print }
    in_stop && /^}/ { in_stop = 0 }
' entrypoint.sh)"

printf '%s\n' "$body" | awk '
    /wait "\$pid"/ { saw_wait = 1 }
    /process_running "\$pid"/ { saw_process_running = 1 }
    saw_process_running && /continue/ {
        saw_guarded_continue = 1
        saw_process_running = 0
    }
    END {
        if (!saw_wait) {
            print "expected stop_sshd to reap stopped sshd children" > "/dev/stderr"
            exit 1
        }
        if (!saw_guarded_continue) {
            print "expected stop_sshd to skip wait for still-running sshd PIDs" > "/dev/stderr"
            exit 1
        }
    }
'
