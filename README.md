# vpn-server

Personal OpenVPN server on AWS, defined in Terraform. One command to deploy, one command to create client configs.

## Architecture

Single VPC with one public subnet in `us-east-2`, currently running **two** servers in parallel while WireGuard is evaluated:

| | OpenVPN | WireGuard (beta) |
|---|---|---|
| Port | UDP/1194 | UDP/51820 |
| Endpoint | auto-assigned public IP | Elastic IP (stable across rebuilds) |
| Trust model | Easy-RSA CA on the instance | static keypairs, no CA |
| Access list | certs signed by the CA | peer public keys in SSM |
| Client tool | `./vpn-client` | `./wg-client` |
| Rebuildable? | **no** — holds the CA | yes, freely |

Estimated cost while both run: **~$24/mo** on-demand. Destroying the WireGuard
side returns it to ~$13/mo.

### Why two

The OpenVPN instance is stateful: `/root/openvpn-ca` holds the CA key, the
Easy-RSA index and `ta.key`, none of which exist anywhere else. Replacing that
instance invalidates every issued client certificate, so it can't be treated as
disposable and its AMI is pinned deliberately.

WireGuard has no CA at all. Its only secret is a 32-byte server key held in SSM
Parameter Store and fetched at boot. That makes the server genuinely
disposable — OS upgrades are just an `apply`, and nothing on the instance is
irreplaceable.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- AWS credentials configured (`aws configure` or environment variables)
- An SSH key pair (the server uses this for admin access)
- `session-manager-plugin` for shell access: `brew install --cask session-manager-plugin`

## Quick Start

1. **Clone and configure:**

   ```bash
   git clone <repo-url> && cd vpn-server
   ```

   Create a `terraform.tfvars` file:

   ```hcl
   easyrsa_email    = "you@example.com"
   ssh_public_key_path = "~/.ssh/id_ed25519.pub"
   allowed_ssh_cidr = "YOUR_IP/32"     # lock down SSH access
   ```

2. **Deploy:**

   ```bash
   terraform init
   terraform apply
   ```

3. **Create a client config:**

   ```bash
   ./vpn-client create mydevice
   ```

   This generates `clients/mydevice.ovpn` with all certs embedded.

4. **Connect:**

   ```bash
   sudo openvpn --config clients/mydevice.ovpn
   ```

   Verify with `curl ifconfig.me` — it should return your VPN server's IP.

## Client Management

```bash
./vpn-client create <name>   # generate a client config (.ovpn)
./vpn-client revoke <name>   # revoke a client cert and delete local config
./vpn-client list            # list issued client certificates
```

Generated configs are saved to `clients/` (gitignored).

## WireGuard (beta)

```bash
./wg-client add <name>      # generate a keypair + config, register the peer
./wg-client qr <name>       # QR code for the iOS/Android app
./wg-client list            # registered peers
./wg-client status          # live handshakes from the server
./wg-client remove <name>   # deregister the peer
./wg-client refresh         # rewrite Endpoint in configs after an EIP change
```

Client private keys are generated locally and never leave the machine. Configs
land in `clients-wg/` (gitignored).

The peer list lives in SSM Parameter Store at `/vpn/wg/peers`, not in this repo.
Peer public keys aren't secret — they can't be used to connect — but they are a
list of someone's devices, and this repo is public. `wg-client` owns that
parameter directly, so `add` and `remove` need no `terraform apply` and take
effect within ~2min. Changes are attributed by CloudTrail and retained in
parameter version history, which is a stronger audit trail than a git author
field.

**Known beta limitations:**

- **UDP only.** No TCP/443 fallback, so networks permitting only TCP will block
  it. This is the one thing OpenVPN does that WireGuard can't, and the main
  question the beta exists to answer.
- **IPv4 only.** `AllowedIPs = 0.0.0.0/0` routes v4 through the tunnel; on a
  dual-stack network, IPv6 traffic still goes direct and bypasses the VPN.
- Fresh Elastic IPs are occasionally blackholed upstream by ISPs. If a new
  endpoint is unreachable but answers from inside AWS,
  `terraform apply -replace=aws_eip.wg` gets a different address, then
  `./wg-client refresh`.
- Rebuilding the server changes its SSH host key while the EIP stays, so
  `ssh-keygen -R <ip>` is needed before reconnecting. Session Manager
  (`aws ssm start-session`) avoids this entirely.

## Configuration

All variables have sensible defaults except `easyrsa_email`. Override in `terraform.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-2` | AWS region |
| `vpn_server_ami` | `ami-0933f4f9e0a0fc3a5` | OpenVPN server AMI, pinned on purpose |
| `vpn_server_instance_type` | `t3.micro` | EC2 instance type |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `emergency_ssh_cidr` | `null` | Break-glass inbound SSH; normally no SSH ingress at all |
| `allowed_vpn_cidr` | `0.0.0.0/0` | CIDR allowed for VPN access |
| `easyrsa_email` | *(required)* | Email for the certificate authority |

## Shell Access

There is **no inbound SSH**. Both security groups expose only their VPN port.
Shell access goes over AWS Session Manager, which works from any network:

```bash
aws ssm start-session --target "$(terraform output -raw vpn_server_instance_id)"
```

Or real SSH tunnelled over it, which is what `./vpn-client` and `./wg-client` use:

```bash
ssh -i ~/.ssh/id_ed25519 \
  -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region us-east-2" \
  ubuntu@"$(terraform output -raw vpn_server_instance_id)"
```

This is deliberately not a home-IP allowlist: a fixed CIDR is useless when
travelling, and Session Manager authenticates with IAM instead of network
location, with every session logged to CloudTrail. As a side effect `known_hosts`
is keyed by instance ID, so rebuilding a server no longer collides with a stored
host key.

**Break glass.** If SSM itself is broken, uncomment `emergency_ssh_cidr` in
`terraform.tfvars`, apply, fix, then comment it out and apply again.

## Tear Down

```bash
terraform destroy
```
