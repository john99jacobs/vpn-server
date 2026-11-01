# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based WireGuard server infrastructure defined in Terraform. Deploys a VPC with a single WireGuard server in `us-east-2`.

## Key Files

- `main.tf` — All infrastructure: VPC, subnet, key pair, SSM peer list, EIP, security group, IAM instance profile, EC2 instance, outputs
- `bootstrap-wg.sh` — WireGuard bootstrap, rendered by `templatefile()` from `main.tf`; fetches its key from SSM, writes a peer-sync script and timer
- `wg-client` — Bash CLI for WireGuard peers
- `init-wg-server-key` — One-time: creates the WireGuard server keypair in SSM
- `clients-wg/` — Generated `.conf` files (gitignored, contain private keys)
- `clients/` — Legacy OpenVPN configs; kept gitignored so leftovers are never committed
- `variables.tf` — Input variables with defaults (region, CIDRs, WireGuard port/address, instance type)
- `terraform.tfvars` — Local overrides (gitignored)
- `init-state-bucket` — One-time: creates the S3 state bucket and writes `backend.hcl`
- `backend.hcl` — Backend bucket/region (gitignored; see `backend.hcl.example`)

## Commands

```bash
terraform init          # Initialize providers (already done, .terraform/ exists)
terraform plan          # Preview changes
terraform apply         # Deploy infrastructure
terraform destroy       # Tear down all resources
terraform fmt           # Format .tf files
terraform validate      # Validate configuration syntax

./init-wg-server-key         # One-time server keypair in SSM (before first apply)
./wg-client add <name>       # Keypair + config, register peer
./wg-client add <name> --pubkey <KEY>   # register a device-generated key
./wg-client remove <name>    # Deregister a peer
./wg-client list             # Registered peers
./wg-client status           # Live handshakes
./wg-client qr <name>        # QR code for mobile import
./wg-client refresh          # Rewrite Endpoint after an EIP change
```

`wg-client add`/`remove` write the SSM peer parameter directly — no
`terraform apply` needed; the server picks changes up within ~2min.

## Architecture (current state)

Single VPC (`10.0.0.0/16`), one public subnet, one EC2 instance:

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

**There is no inbound SSH.** The security group exposes only the WireGuard port.
The instance has an instance profile granting Session Manager, and
`./wg-client` reaches it with SSH tunnelled over SSM (`AWS-StartSSHSession`),
targeting the instance ID rather than an IP. Requires `session-manager-plugin`
locally. `var.emergency_ssh_cidr` (default `null`) adds a temporary SSH rule if
SSM is ever broken.

OpenVPN was retired in November 2026 (last version: tag `openvpn-final`).

### Working on this repo

- `terraform apply -auto-approve` is a bad idea here. Save a plan, confirm it
  never destroys or replaces `aws_eip.wg` (the endpoint in every client config)
  or `aws_ssm_parameter.wg_peers` (the peer list), then apply the saved plan.
  Replacing `aws_instance.wg_server` is fine: the EIP is reassociated, at the
  cost of a ~2-3 min outage.
- Editing `bootstrap-wg.sh` changes `user_data` and replaces the instance, which
  is fine and expected.
- `bootstrap-wg.sh` is a `templatefile()` template: a braced shell expansion
  must be escaped with a doubled dollar sign.

## Branches

- `main` — The deployed working branch. Work happens on feature branches and
  lands through PRs.

## Known Issues / Planned Improvements

- WireGuard is UDP-only and IPv4-only (see README for the full list)

## Terraform Conventions

- No modules — everything is in a single `main.tf`
- Remote state in S3 (partial backend config: `terraform init -backend-config=backend.hcl`;
  `backend.hcl` is gitignored and written by `./init-state-bucket`). Never run
  Terraform against a local `terraform.tfstate`.
- Provider: `hashicorp/aws` only
- Resources use descriptive names prefixed by function (e.g., `vpn_vpc`, `wg_sg`)
