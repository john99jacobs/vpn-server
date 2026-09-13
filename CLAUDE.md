# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based OpenVPN server infrastructure defined in Terraform. Deploys a VPC with a single OpenVPN server in `us-east-2`.

## Key Files

- `main.tf` — OpenVPN infrastructure: VPC, subnet, security group, EC2 instance
- `bootstrap.sh` — OpenVPN bootstrap, rendered by `templatefile()` from `main.tf`
- `wireguard.tf` — WireGuard beta stack (EIP, SG, IAM instance profile, SSM peer list, instance)
- `bootstrap-wg.sh` — WireGuard bootstrap; fetches its key from SSM, writes a peer-sync script and timer
- `wg-client` — Bash CLI for WireGuard peers
- `clients-wg/` — Generated `.conf` files (gitignored, contain private keys)
- `variables.tf` — Input variables with defaults (region, AMI, CIDRs, instance type)
- `terraform.tfvars` — Local overrides (gitignored, contains sensitive values)
- `vpn-client` — Bash CLI to create, revoke, and list VPN client configs
- `client-template.ovpn` — Reference OpenVPN client config format
- `clients/` — Generated `.ovpn` files (gitignored, contains private keys)

## Commands

```bash
terraform init          # Initialize providers (already done, .terraform/ exists)
terraform plan          # Preview changes
terraform apply         # Deploy infrastructure
terraform destroy       # Tear down all resources
terraform fmt           # Format .tf files
terraform validate      # Validate configuration syntax

./vpn-client create <name>   # Generate client config (clients/<name>.ovpn)
./vpn-client revoke <name>   # Revoke client cert and delete local config
./vpn-client list            # List issued client certificates

./wg-client add <name>       # WireGuard: keypair + config, register peer
./wg-client remove <name>    # Deregister a peer
./wg-client list             # Registered peers
./wg-client status           # Live handshakes
./wg-client qr <name>        # QR code for mobile import
./wg-client refresh          # Rewrite Endpoint after an EIP change
```

`wg-client add`/`remove` write the SSM peer parameter directly — no
`terraform apply` needed; the server picks changes up within ~2min.

## Architecture (current state)

Single VPC (`10.0.0.0/16`), one public subnet, **two** EC2 instances running in
parallel while WireGuard is evaluated:

- **`vpn_server`** — OpenVPN on UDP/1194. **Stateful and not replaceable:**
  `/root/openvpn-ca` holds the CA key, Easy-RSA index and `ta.key`, which exist
  nowhere else. Replacing it invalidates all issued client certs, so its AMI is
  pinned via `var.vpn_server_ami` rather than tracking `data.aws_ami.ubuntu`.
  **Never let a plan replace this instance without backing up `/root/openvpn-ca`
  first.**
- **`wg_server`** — WireGuard on UDP/51820, behind an Elastic IP. Stateless: the
  only secret is a 32-byte key in SSM, fetched at boot. Tracks the AMI data
  source and sets `user_data_replace_on_change`, so it is meant to be replaced
  freely. The peer list is an SSM parameter (`/vpn/wg/peers`) owned by
  `./wg-client`, **not** by Terraform — `aws_ssm_parameter.wg_peers` has
  `ignore_changes = [value]`, so Terraform creates it but never overwrites it.
  Deliberately not tracked in git: the keys are not secret, but this repo is
  public and the list names personal devices. A systemd timer polls every 2min
  and applies changes with `wg syncconf`, so adding a peer needs no instance
  change, no apply, and disconnects nobody.

**There is no inbound SSH.** Both security groups expose only their VPN port.
Both instances have an instance profile granting Session Manager, and
`./vpn-client` / `./wg-client` reach them with SSH tunnelled over SSM
(`AWS-StartSSHSession`), targeting the instance ID rather than an IP. Requires
`session-manager-plugin` locally. `var.emergency_ssh_cidr` (default `null`) adds
a temporary SSH rule to both SGs if SSM is ever broken.

### Working on this repo

- `terraform apply -auto-approve` is a bad idea here. Save a plan, confirm it
  does not destroy `aws_instance.vpn_server`, then apply the saved plan.
- Editing `bootstrap.sh` changes `user_data` and would replace the OpenVPN
  instance. Editing `bootstrap-wg.sh` replaces the WireGuard instance, which is
  fine and expected.
- Both bootstrap scripts are `templatefile()` templates: a braced shell
  expansion must be escaped with a doubled dollar sign.

## Branches

- `main` — Current working branch (simplified single-server setup)
- `public-vpn-server` — Previous iteration with jump box and NLB
- `private-vpn-server` — VPN server in private subnet with NAT gateway

## Known Issues / Planned Improvements

- Terraform state is local only — no remote backend configured
- OpenVPN client certs expire **2028-10-14**; they will fail with a non-obvious error
- WireGuard beta is UDP-only and IPv4-only (see README for the full list)
- CA backup is manual and single-copy: `~/vpn-ca-backup/*.age` on the operator's
  workstation, encrypted to their SSH key — so losing that machine loses both halves

## Terraform Conventions

- No modules — everything is in a single `main.tf`
- No remote state backend
- Provider: `hashicorp/aws` only
- Resources use descriptive names prefixed by function (e.g., `vpn_vpc`, `vpn_sg`)
