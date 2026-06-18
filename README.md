# Debian SSH ngrok Template

Public image source for the Enclava PaaS `debian-ssh-ngrok` hosted
deployment template.

- Runs as UID/GID `10001`, matching CAP's unprivileged workload container.
- Links `/home/lio` to `/state/app-data/home/lio` at startup, keeping SSH
  state, authorized keys, host keys, and user files on CAP's encrypted state.
- Exposes HTTP health on `8080` for CAP readiness.
- Runs SSH internally on `2222` because CAP drops low-port bind capability.
- Starts `ngrok tcp 127.0.0.1:2222` using `NGROK_AUTHTOKEN`.
- Publishes the discovered ngrok endpoint on `/ngrok-url.txt`, `/ssh.txt`,
  and `/ngrok.json` through the health HTTP server.

Use the local `ngork-secret.txt` value as the confidential `NGROK_AUTHTOKEN`
template config value. Do not commit it.
