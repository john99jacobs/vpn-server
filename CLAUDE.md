# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based OpenVPN server infrastructure defined in Terraform. Deploys a VPC with a single OpenVPN server in `us-east-2`.

## Key Files

- `main.tf` — All infrastructure: VPC, subnet, security group, EC2 instance, and an inline `user_data` bootstrap script that installs/configures OpenVPN with Easy-RSA
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
```

## Architecture (current state)

Single VPC (`10.0.0.0/16`) with one public subnet. One EC2 instance:
- **VPN server** (Ubuntu) — OpenVPN on UDP/1194, bootstrapped via inline `user_data` script

Traffic flows directly: Client → VPN server (public IP). Security group allows UDP/1194 (VPN) and TCP/22 (SSH) by CIDR. SSH is open to `0.0.0.0/0` by default — lock down via `allowed_ssh_cidr` in `terraform.tfvars`.

## Branches

- `main` — Current working branch (simplified single-server setup)
- `public-vpn-server` — Previous iteration with jump box and NLB
- `private-vpn-server` — VPN server in private subnet with NAT gateway

## Known Issues / Planned Improvements

- AMI IDs are hardcoded and region-specific — should use `data` sources for lookup
- Terraform state is local only — no remote backend configured
- `user_data` bootstrap script is inline (~70 lines) — consider extracting to a `.sh` file
- SSH open to `0.0.0.0/0` by default — lock down or replace with SSM
- Hardcoded email in `user_data` bootstrap script

## Terraform Conventions

- No modules — everything is in a single `main.tf`
- No remote state backend
- Provider: `hashicorp/aws` only
- Resources use descriptive names prefixed by function (e.g., `vpn_vpc`, `vpn_sg`)
