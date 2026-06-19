# Debian SSH ngrok Template

Public image source for the Enclava PaaS `debian-ssh-ngrok` hosted
deployment template.

- Runs as Linux user `user` with UID/GID `10001`.
- Grants `user` passwordless sudo for package installation inside the running
  instance. The PaaS template must request CAP's managed SSH sudo workload
  profile so setuid sudo and a writable root filesystem are available.
- Uses CAP's encrypted app state directory at `/state/app/home-user` and
  exposes it at `/home/user` through an image-level symlink, keeping SSH state,
  authorized keys, host keys, and user files on the LUKS-backed state volume.
- Reads CAP config from the encrypted config handoff, currently
  `/state/.enclava/config` for this template.
- Exposes HTTP health on `8080` for CAP readiness; `/healthz` is only present
  when both local SSH and the ngrok TCP tunnel are live.
- Runs SSH internally on `2222` because CAP drops low-port bind capability.
- Starts `ngrok tcp 127.0.0.1:2222` using `NGROK_AUTHTOKEN`.
- Publishes the discovered ngrok endpoint on `/ngrok-url.txt`, `/ssh.txt`,
  and `/ngrok.json` through the health HTTP server.

Use the local `ngork-secret.txt` value as the confidential `NGROK_AUTHTOKEN`
template config value. Do not commit it.
