# Backlog

## Up Next
- [x] `vpn-client create <name>` — SSH in, generate client cert, assemble and download complete `.ovpn`
- [x] `vpn-client revoke <name>` — revoke client cert and update CRL
- [x] `vpn-client list` — show active clients
- [x] Replace hardcoded AMI IDs with `data` source lookups
- [ ] Extract inline `user_data` script to a separate `.sh` file
- [ ] Lock down SSH (`allowed_ssh_cidr`) or replace with SSM Session Manager

## Later
- [ ] Add S3 backend for Terraform state
- [ ] Remove hardcoded email from bootstrap script (use a variable)
- [ ] Add tags/naming convention for cost tracking
- [ ] Add support for multiple AWS regions