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
  when the SSH listener and ngrok TCP tunnel are live. The steady-state health
  check is passive and does not open recurring SSH sessions.
- Runs SSH internally on `2222` because CAP drops low-port bind capability.
- Starts `ngrok tcp 127.0.0.1:2222` using `NGROK_AUTHTOKEN` and the
  required reserved `NGROK_TCP_URL` address so the SSH command remains stable
  across ngrok or pod restarts.
- Requires `DEBIAN_SSH_AUTHORIZED_KEYS`, one SSH public key per line. The image
  does not contain any externally usable baked-in authorized key.
- Publishes the discovered ngrok endpoint on `/ngrok-url.txt`, `/ssh.txt`,
  and `/ngrok.json` through the health HTTP server.

Use the local `../ngrok-secret.txt` value as the confidential
`NGROK_AUTHTOKEN` template config value, and paste the user's SSH public key as
`DEBIAN_SSH_AUTHORIZED_KEYS`. Do not commit secrets or private keys.

Reserve an ngrok TCP address and write `NGROK_TCP_URL` before the other required
config keys, for example `6.tcp.eu.ngrok.io:17958`. The workload normalizes
optional `tcp://` prefixes, persists the reserved address for restarts, passes
it to `ngrok tcp --url`, publishes the resulting `ssh -p <port> user@<host>`
command on `/ssh.txt`, and refuses readiness if ngrok publishes a different
endpoint.

Dynamic ngrok endpoints are not supported by this hosted template image.
`NGROK_TCP_URL` is required so PaaS can store and enforce the stable SSH
endpoint expectation across workload, browser, and CLI reads.

## Publishing

The image workflow validates shell syntax and runs the full Docker entrypoint
suite, including image layout, config parsing, supervision, SSH readiness,
ngrok recovery, missing-config startup behavior, config directory loading, and
reserved `NGROK_TCP_URL` handling before publishing to GHCR. Non-PR runs sign
the pushed digest with cosign and upload the artifact named
`debian-ssh-ngrok-template-image`.

After a successful publish, download the artifact and use the single line in
`dist/debian-ssh-ngrok-template-image.txt` as the PaaS
`DEBIAN_SSH_NGROK_IMAGE` value. It must stay on the official repository and
digest-pinned, for example:

```env
DEBIAN_SSH_NGROK_IMAGE=ghcr.io/enclava-labs/debian-ssh-ngrok-template@sha256:<digest>
```

Staging and production PaaS config reject tag-only, placeholder, or different
repository image references for this template. Promote the signed digest there
before deploying PaaS and running the stable SSH canary.
Before promotion, verify the keyless signature against this workflow identity:

```sh
cosign verify \
  --certificate-identity https://github.com/enclava-labs/debian-ssh-ngrok-template/.github/workflows/image.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/enclava-labs/debian-ssh-ngrok-template@sha256:<digest>
```

The PaaS repository also includes
`scripts/verify-debian-ssh-ngrok-image-ref.sh` to validate the downloaded
artifact and emit the exact `DEBIAN_SSH_NGROK_IMAGE=...` config line.
