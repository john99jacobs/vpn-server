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

## Tear Down

```bash
terraform destroy
```
