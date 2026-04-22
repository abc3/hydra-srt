# HydraSRT Deployment Options

This directory is the home for provider-specific deployment options.

Current status:

- `Hetzner`: implemented as the first deployment path
- `AWS`: planned
- `GCP`: planned
- `Azure`: planned
- `Fly.io`: planned

The current files in this directory describe the first option only: a single-server deployment scaffold for HydraSRT on Hetzner Cloud.

This layout intentionally separates:

- infrastructure provisioning with OpenTofu
- host bootstrap with `cloud-init`
- runtime management with `systemd`
- application rollout with release tarballs

## Layout

- `opentofu/`: Hetzner server, volume, and firewall
- `cloud-init/`: Hetzner host first-boot preparation
- `systemd/`: release service unit used by the Hetzner path
- `scripts/bootstrap.sh`: host-side setup for the current Hetzner path
- `scripts/deploy_release.sh`: release deploy helper for the current Hetzner path
- `env/hydra_srt.env.example`: runtime environment template for the current Hetzner path

## Architecture

This section describes the currently implemented Hetzner option.

The deployment assumes:

- one Ubuntu 24.04 VM on Hetzner
- one attached volume mounted at `/var/lib/hydra_srt`
- release files under `/opt/hydra_srt/releases/<version>`
- `/opt/hydra_srt/current` symlink points at the active release
- SQLite database lives on the volume at `/var/lib/hydra_srt/db/hydra_srt.db`
- `systemd` starts the release with `/opt/hydra_srt/current/bin/server`

## Provisioning

This provisioning flow is Hetzner-specific.

1. Copy `opentofu/.env.example` to `opentofu/.env` and set `TF_VAR_hcloud_token`.
2. Copy `opentofu/terraform.tfvars.example` to `opentofu/terraform.tfvars`.
3. Adjust the server name, SSH keys, admin CIDRs, and any streaming ports you need.
4. Apply:

```bash
cd /Users/sts/dev/hydra/deployment
make tofu-init
make tofu-plan
make tofu-apply
```

After the VM comes up, copy this repository to the host and run:

```bash
cd /path/to/hydra
sudo ./deployment/scripts/bootstrap.sh
```

That installs the service unit, creates the runtime directories, and places the sample env file if it does not exist yet.
This step is required because `cloud-init` no longer installs the canonical `systemd` unit from the repo.

## First Host Setup

This host setup flow is Hetzner-specific.

Create the runtime env file on the server:

```bash
sudo cp /path/to/hydra/deployment/env/hydra_srt.env.example /etc/hydra_srt/hydra_srt.env
sudo editor /etc/hydra_srt/hydra_srt.env
```

At minimum, set:

- `SECRET_KEY_BASE`
- `API_AUTH_USERNAME`
- `API_AUTH_PASSWORD`
- `PHX_HOST`

Generate secrets with:

```bash
openssl rand -base64 48
openssl rand -base64 32
```

Use the longer value for `SECRET_KEY_BASE` and the shorter one for `RELEASE_COOKIE` or `API_AUTH_PASSWORD` if you want.

## Release Deploy Flow

This deploy flow is currently shared with the Hetzner path implemented here.

From your local machine:

```bash
cd /Users/sts/dev/hydra
./deployment/scripts/deploy_release.sh root@YOUR_SERVER_IP
```

Or:

```bash
cd /Users/sts/dev/hydra/deployment
make deploy-release HOST=root@YOUR_SERVER_IP
```

The script:

1. installs production dependencies needed for the build
2. builds a fresh `MIX_ENV=prod` release
3. packs it into a tarball
4. uploads it to the host
5. unpacks it into `/opt/hydra_srt/releases/<version>`
6. stops the running service
7. runs release migrations
8. switches the `current` symlink
9. starts `hydra_srt.service`
10. waits for `systemd` and `/health` to go healthy
11. rolls back to the previous release automatically if startup fails
12. prunes older release directories after a successful deploy

Pass an explicit release label if needed:

```bash
./deployment/scripts/deploy_release.sh root@YOUR_SERVER_IP 2026-04-22_01
```

By default the deploy keeps the current release plus the two most recent rollback candidates.
Override that from the local shell if you want:

```bash
DEPLOY_RELEASES_TO_KEEP=5 ./deployment/scripts/deploy_release.sh root@YOUR_SERVER_IP
```

## Notes

- This directory is intentionally named generically because more provider-specific options are expected to be added later.
- The initial firewall opens `22/tcp` to admin CIDRs and `4000/tcp` to the configured app CIDRs.
- Streaming listener ports are optional and configurable as explicit TCP and UDP port lists.
- This is a pragmatic first version. If deploy speed becomes critical, the next step is to move the build into GitHub Actions and ship a prebuilt artifact instead of building locally.
