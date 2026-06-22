#!/bin/sh
set -eu

wrapper_body="$(awk '
    /^run_restart_wrapper\(\) \{/ { in_wrapper = 1 }
    in_wrapper { print }
    in_wrapper && /^if \[ "\$DEBIAN_SSH_RESTART_WRAPPER"/ { in_wrapper = 0 }
' entrypoint.sh)"

printf '%s\n' "$wrapper_body" | awk '
    /stop_wrapper_child\(\) \{/ { in_stop = 1 }
    in_stop && /kill -KILL "\$pid"/ { saw_kill = 1 }
    saw_kill && /wrapper_child_running "\$pid"/ { saw_post_kill_check = 1 }
    saw_post_kill_check && /return 1/ { saw_stop_failure = 1 }
    in_stop && /^    }$/ { in_stop = 0 }

    /stop_wrapper_child "\$child_pid"/ {
        saw_child_stop = 1
        child_stop_line = NR
        if ($0 ~ /\|\|[[:space:]]+exit/) {
            saw_exit_after_failed_child_stop = 1
        }
    }
    saw_child_stop && NR <= child_stop_line + 6 && /exit/ {
        saw_exit_after_failed_child_stop = 1
    }

    /wait "\$child_pid"/ {
        saw_child_wait = 1
        if (!saw_exit_after_failed_child_stop) {
            wait_before_failure_handling = 1
        }
    }

    END {
        if (!saw_stop_failure) {
            print "expected stop_wrapper_child to return failure when child survives SIGKILL" > "/dev/stderr"
            exit 1
        }
        if (!saw_exit_after_failed_child_stop) {
            print "expected wrapper to exit instead of waiting on a child that survived SIGKILL" > "/dev/stderr"
            exit 1
        }
        if (!saw_child_wait) {
            print "expected wrapper to still reap children that stopped cleanly" > "/dev/stderr"
            exit 1
        }
        if (wait_before_failure_handling) {
            print "expected failure handling before wait on wrapper child" > "/dev/stderr"
            exit 1
        }
    }
'
