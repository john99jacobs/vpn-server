# vpn-server

Personal OpenVPN server on AWS, defined in Terraform. One command to deploy, one command to create client configs.

## Architecture

Single VPC with one public subnet in `us-east-2`. One `t3.micro` EC2 instance running OpenVPN, bootstrapped automatically via `user_data`. Traffic flows directly from client to server over UDP/1194.

Estimated cost: **~$13/mo** on-demand (free tier eligible for the first 12 months).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) installed
- AWS credentials configured (`aws configure` or environment variables)
- An SSH key pair (the server uses this for admin access)

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
   ./init-state-bucket                         # once per account; see Remote State
   terraform init -backend-config=backend.hcl
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

## Configuration

All variables have sensible defaults except `easyrsa_email`. Override in `terraform.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-2` | AWS region |
| `ubuntu_ami` | `ami-036841078a4b68e14` | Ubuntu AMI (region-specific) |
| `vpn_server_instance_type` | `t3.micro` | EC2 instance type |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `allowed_ssh_cidr` | `0.0.0.0/0` | CIDR allowed for SSH access |
| `allowed_vpn_cidr` | `0.0.0.0/0` | CIDR allowed for VPN access |
| `easyrsa_email` | *(required)* | Email for the certificate authority |

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
apply from stale state could try to replace the OpenVPN server.

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
