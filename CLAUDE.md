# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based OpenVPN server infrastructure defined in Terraform. Deploys a VPC with an OpenVPN server, jump box, and NLB in `us-east-2`.

## Key Files

- `main.tf` — All infrastructure: VPC, subnets, security groups, EC2 instances (jump box + VPN server), NLB, and an inline `user_data` bootstrap script that installs/configures OpenVPN with Easy-RSA
- `variables.tf` — Input variables with defaults (region, AMIs, CIDRs, instance types)
- `terraform.tfvars` — Local overrides (gitignored, contains sensitive values)
- `client-template.ovpn` — Template OpenVPN client config; requires manual cert/key pasting

## Commands

```bash
terraform init          # Initialize providers (already done, .terraform/ exists)
terraform plan          # Preview changes
terraform apply         # Deploy infrastructure
terraform destroy       # Tear down all resources
terraform fmt           # Format .tf files
terraform validate      # Validate configuration syntax
```

## Architecture (current state)

Single VPC (`10.0.0.0/16`) with one public subnet. Two EC2 instances:
1. **Jump box** (Amazon Linux) — SSH bastion with its own security group
2. **VPN server** (Ubuntu) — OpenVPN on UDP/1194, bootstrapped via inline `user_data` script

An NLB fronts the VPN server with two target groups (UDP/1194 for VPN, UDP/53 for DNS). Traffic flows: Client → NLB → VPN server SG (allows from NLB SG) → VPN server.

## Branches

- `public-vpn-server` — VPN server in public subnet (current working branch)
- `private-vpn-server` — VPN server in private subnet with NAT gateway
- `main` — Base branch

## Known Issues / Planned Improvements

- NLB adds cost (~$16/mo) with no HA benefit for a single server — candidate for removal
- Jump box is redundant when VPN server is in the same public subnet — replace with SSM
- DNS target group (port 53) is unnecessary — VPN server doesn't run a DNS server
- AMI IDs are hardcoded and region-specific — should use `data` sources for lookup
- Terraform state is local only — no remote backend configured
- `user_data` bootstrap script is inline (~70 lines) — consider extracting to a `.sh` file
- Client config requires manual cert pasting — could auto-generate complete `.ovpn` files

## Terraform Conventions

- No modules — everything is in a single `main.tf`
- No remote state backend
- Provider: `hashicorp/aws` only
- Resources use descriptive names prefixed by function (e.g., `vpn_vpc`, `vpn_sg`, `jump_sg`)
