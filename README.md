# Debian SSH ngrok Template

Public image source for the Enclava PaaS `debian-ssh-ngrok` hosted
deployment template.

- Runs as Linux user `user` with UID/GID `10001`.
- Grants `user` passwordless sudo for package installation inside the running
  instance. The PaaS template must request CAP's managed SSH sudo workload
  profile so setuid sudo and a writable root filesystem are available.
- Uses CAP's encrypted config handoff runtime directory at
  `/state/.enclava/config/.runtime/home-user` and exposes it at `/home/user`
  through an image-level symlink, keeping SSH state, authorized keys, host keys,
  and user files on the LUKS-backed state volume without a separate app bind
  mount.
- Reads CAP config from the encrypted config handoff, currently
  `/state/.enclava/config` for this template.
- Exposes HTTP health on `8080` for CAP readiness; `/healthz` is only present
  when both local SSH and the ngrok TCP tunnel are live.
- Runs SSH internally on `2222` because CAP drops low-port bind capability.
- Starts `ngrok tcp 127.0.0.1:2222` using `NGROK_AUTHTOKEN` and the
  required reserved `NGROK_TCP_URL` address so the SSH command remains stable
  across ngrok or pod restarts.
- Requires `DEBIAN_SSH_AUTHORIZED_KEYS`, one SSH public key per line. The image
  does not contain any externally usable baked-in authorized key.
- Publishes the discovered ngrok endpoint on `/ngrok-url.txt`, `/ssh.txt`,
  and `/ngrok.json` through the health HTTP server.

Reserve an ngrok TCP address and write `NGROK_TCP_URL`, for example
`6.tcp.eu.ngrok.io:17958`, before startup. The workload normalizes optional
`tcp://` prefixes, persists the reserved address for restarts, passes it to
`ngrok tcp --url`, publishes the resulting `ssh -p <port> user@<host>` command
on `/ssh.txt`, and refuses readiness if ngrok publishes a different endpoint.

Dynamic ngrok endpoints are not supported by this hosted template image.
`NGROK_TCP_URL` is required so PaaS can store and enforce the stable SSH
endpoint expectation across workload, browser, and CLI reads.

Use the local ngrok agent token file as the confidential `NGROK_AUTHTOKEN`
template config value, and pass user SSH public keys through
`DEBIAN_SSH_AUTHORIZED_KEYS`. In the shared platform checkout used by the PaaS
release verifier, that file is `../ngrok-secret.txt` from the PaaS repository
or `../../ngrok-secret.txt` from this standalone template repository. Do not
commit secrets or private keys.

## Production Publishing

This standalone repository validates the public template source and Docker
entrypoint behavior only. It must not publish or sign the production
`ghcr.io/enclava-labs/debian-ssh-ngrok-template` image, because PaaS release
verification pins the accepted keyless signer identity to the PaaS workflow:

```text
https://github.com/enclava-labs/enclava-paas/.github/workflows/debian-ssh-ngrok-template-image.yml@refs/heads/main
```

Build and promote production template images through the PaaS repository's
`.github/workflows/debian-ssh-ngrok-template-image.yml` workflow. Download its
`debian-ssh-ngrok-template-image` artifact, verify it from the PaaS repository
with `scripts/verify-debian-ssh-ngrok-image-ref.sh --cosign`, then configure
that signed digest as `DEBIAN_SSH_NGROK_IMAGE` before running the strict stable
SSH release gate.
