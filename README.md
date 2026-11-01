# vpn-server

Personal WireGuard server on AWS, defined in Terraform. One command to deploy, one command to add a device.

## Architecture

Single VPC with one public subnet in `us-east-2`, running one WireGuard server:

| | |
|---|---|
| Port | UDP/51820 |
| Endpoint | Elastic IP (stable across rebuilds) |
| Trust model | static keypairs, no CA |
| Access list | peer public keys in SSM |
| Client tool | `./wg-client` |
| Rebuildable? | yes, freely |

Estimated cost: **~$12-13/mo** on-demand (instance plus the public IPv4).

### Why it is disposable

WireGuard has no CA at all. Its only secret is a 32-byte server key held in SSM
Parameter Store and fetched at boot, and the peer list is a separate SSM
parameter. That makes the server genuinely disposable — OS upgrades are just an
`apply`, and nothing on the instance is irreplaceable.

This repo used to run an OpenVPN server alongside it; that was retired in
November 2026, and the last version with it is tagged `openvpn-final`.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- AWS credentials configured (`aws configure` or environment variables)
- An SSH key pair (the server uses this for admin access)
- `session-manager-plugin` for shell access: `brew install --cask session-manager-plugin`
- `wireguard-tools` (for `wg genkey`/`wg pubkey`) and, for QR codes, `qrencode`

## Quick Start

1. **Clone and configure:**

   ```bash
   git clone <repo-url> && cd vpn-server
   ```

   Optionally create a `terraform.tfvars` file (see `terraform.tfvars.example`);
   every variable has a default:

   ```hcl
   ssh_public_key_path = "~/.ssh/id_ed25519.pub"
   ```

2. **Create the WireGuard server key** (once per account and region, before the
   first apply):

   ```bash
   ./init-wg-server-key
   ```

   This writes `/vpn/wg/server-private-key` (SecureString) and
   `/vpn/wg/server-public-key` to SSM from a single keypair. Skip it and
   `terraform plan` fails with `ParameterNotFound`. If the two are ever set by
   hand and don't match, the server refuses to start WireGuard rather than
   silently failing every handshake.

3. **Deploy:**

   ```bash
   ./init-state-bucket                         # once per account; see Remote State
   terraform init -backend-config=backend.hcl
   terraform apply
   ```

4. **Add a device:**

   ```bash
   ./wg-client add mydevice
   ./wg-client qr mydevice      # for the iOS/Android app
   ```

   This generates `clients-wg/mydevice.conf` and registers the peer.

5. **Connect:** import the config (or scan the QR code) in the WireGuard app and
   activate the tunnel. Verify with `curl ifconfig.me` — it should return the
   Elastic IP (`terraform output -raw wg_server_public_ip`).

## Client Management

```bash
./wg-client add <name>      # generate a keypair + config, register the peer
./wg-client add <name> --pubkey <KEY>   # register a key the DEVICE generated
./wg-client qr <name>       # QR code for the iOS/Android app
./wg-client list            # registered peers
./wg-client status          # live handshakes from the server
./wg-client remove <name>   # deregister the peer
./wg-client refresh         # rewrite Endpoint in configs after an EIP change
```

Client private keys are generated locally and never leave the machine. Configs
land in `clients-wg/` (gitignored) — **delete each one once the device has
imported it**, so the only copy of a client key is on the device that uses it.

For devices you'd rather never hand a key to, create an empty tunnel in the
WireGuard app, let it generate its own keypair, and register just the public half
with `--pubkey`. Nothing secret is written here at all; the command prints the
settings to enter on the device. You lose the QR shortcut, since a QR has to
carry the private key to be useful.

The peer list lives in SSM Parameter Store at `/vpn/wg/peers`, not in this repo.
Peer public keys aren't secret — they can't be used to connect — but they are a
list of someone's devices, and this repo is public. `wg-client` owns that
parameter directly, so `add` and `remove` need no `terraform apply` and take
effect within ~2min. Changes are attributed by CloudTrail and retained in
parameter version history, which is a stronger audit trail than a git author
field.

**Known limitations:**

- **UDP only.** There is no TCP fallback, so networks permitting only TCP will
  block it. (The retired OpenVPN server was UDP-only too, so nothing was lost.)
  It has been confirmed working from home, LTE, office and hotel networks.
- **IPv4 only.** `AllowedIPs = 0.0.0.0/0` routes v4 through the tunnel; on a
  dual-stack network, IPv6 traffic still goes direct and bypasses the VPN.
- Fresh Elastic IPs are occasionally blackholed upstream by ISPs. If a new
  endpoint is unreachable but answers from inside AWS,
  `terraform apply -replace=aws_eip.wg` gets a different address, then
  `./wg-client refresh`.
- Rebuilding the server changes its SSH host key while the EIP stays, so
  `ssh-keygen -R <ip>` is needed before reconnecting by IP. Session Manager
  (`aws ssm start-session`) avoids this entirely.

## Configuration

All variables have sensible defaults. Override in `terraform.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-2` | AWS region |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `key_pair_name` | `vpn-key` | Name of the EC2 key pair |
| `vpc_cidr` | `10.0.0.0/16` | CIDR block for the VPC |
| `public_subnet_cidr` | `10.0.1.0/24` | CIDR block for the public subnet |
| `emergency_ssh_cidr` | `null` | Break-glass inbound SSH; normally no SSH ingress at all |
| `allowed_vpn_cidr` | `0.0.0.0/0` | CIDR allowed for VPN access |
| `wg_port` | `51820` | UDP port for WireGuard |
| `wg_server_address` | `10.8.0.1/24` | Server address inside the tunnel subnet |
| `wg_instance_type` | `t3.micro` | EC2 instance type |

## Shell Access

There is **no inbound SSH**. The security group exposes only the WireGuard port.
Shell access goes over AWS Session Manager, which works from any network:

```bash
aws ssm start-session --target "$(terraform output -raw wg_server_instance_id)"
```

Or real SSH tunnelled over it, which is what `./wg-client` uses:

```bash
ssh -i ~/.ssh/id_ed25519 \
  -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region us-east-2" \
  ubuntu@"$(terraform output -raw wg_server_instance_id)"
```

This is deliberately not a home-IP allowlist: a fixed CIDR is useless when
travelling, and Session Manager authenticates with IAM instead of network
location, with every session logged to CloudTrail. As a side effect `known_hosts`
is keyed by instance ID, so rebuilding the server no longer collides with a
stored host key.

**Break glass.** If SSM itself is broken, uncomment `emergency_ssh_cidr` in
`terraform.tfvars`, apply, fix, then comment it out and apply again.

## Remote State

Terraform state lives in S3 (`vpn-server-tfstate-<account-id>`, key
`vpn-server/terraform.tfstate`), so any machine with credentials plans and
applies against the same state. The bucket is private, encrypted, TLS-only and
versioned. Locking uses S3's native lock file (`use_lockfile`), so two applies
can't run at once and no DynamoDB table is needed.

`./init-state-bucket [region]` creates the bucket and writes `backend.hcl`
(gitignored, because the bucket name includes the account ID). It is safe to
re-run.

**Migrating existing local state** (one time, on the machine that has
`terraform.tfstate`):

```bash
./init-state-bucket
terraform init -migrate-state -backend-config=backend.hcl   # answer "yes" to copy
terraform plan                                              # must say "No changes."
```

Once the plan is clean, local `terraform.tfstate*` files are no longer read. Keep
them as a backup for a while, but never run Terraform against them again: an
apply from stale state could recreate or destroy resources that already exist.

**Another machine:** run `./init-state-bucket` with that machine's credentials
(it reuses the bucket and writes `backend.hcl`), then
`terraform init -backend-config=backend.hcl`.

**Permissions for the state bucket** (in addition to whatever the plan itself
touches):

| Action | Resource |
|---|---|
| `s3:ListBucket` | `arn:aws:s3:::vpn-server-tfstate-<account-id>` |
| `s3:GetObject`, `s3:PutObject` | `…/vpn-server/terraform.tfstate` |
| `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `…/vpn-server/terraform.tfstate.tflock` |

Read-only access (`ListBucket` + `GetObject` on the state) is enough for
`terraform plan -lock=false`, which suits a machine that should plan but not
apply.

## Tear Down

```bash
terraform destroy
```

This is not a pause button:

- It **releases the Elastic IP**. A later apply gets a new address, so every
  client config breaks until each device's `Endpoint` is updated
  (`./wg-client refresh` rewrites any configs still in `clients-wg/`).
- It **deletes the peer list** (`/vpn/wg/peers`), so every device has to be
  registered again with `./wg-client add`.
- The server keypair survives: it was created by `./init-wg-server-key`, not by
  Terraform, so a redeploy keeps the same server public key.
