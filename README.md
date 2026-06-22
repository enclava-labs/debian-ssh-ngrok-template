# Debian SSH ngrok Template

Public image source for the Enclava PaaS `debian-ssh-ngrok` hosted
deployment template.

- Runs as Linux user `user` with UID/GID `10001`.
- Grants `user` passwordless sudo for package installation inside the running
  instance. The PaaS template must request CAP's managed SSH sudo workload
  profile so setuid sudo and a writable root filesystem are available.
- Runs dropbear as the non-root SSH daemon. This avoids OpenSSH privilege
  separation behavior that requires `CAP_SYS_CHROOT` in confidential runtimes.
- Uses an image-owned `/home/user` directory for SSH state, authorized keys,
  host keys, and user files, so the template still starts when CAP mounts
  `/state` as root-owned runtime state.
- Reads CAP config from the encrypted config handoff, currently
  `/state/.enclava/config` for this template.
- Exposes HTTP health on `8080` for CAP readiness; `/healthz` is only present
  when both local SSH and the ngrok TCP tunnel are live.
- Runs SSH internally on `2222` because CAP drops low-port bind capability.
- Starts `ngrok tcp 127.0.0.1:2222` using `NGROK_AUTHTOKEN`.
  By default ngrok assigns a dynamic TCP host:port; set `NGROK_TCP_URL`
  to a reserved ngrok TCP Address when the SSH command must remain stable
  across ngrok or pod restarts.
- Publishes the discovered ngrok endpoint on `/ngrok-url.txt`, `/ssh.txt`,
  and `/ngrok.json` through the health HTTP server.

Use the local `ngork-secret.txt` value as the confidential `NGROK_AUTHTOKEN`
template config value. Do not commit it.
