# Backlog

## Up Next
- [x] `vpn-client create <name>` — SSH in, generate client cert, assemble and download complete `.ovpn`
- [x] `vpn-client revoke <name>` — revoke client cert and update CRL
- [x] `vpn-client list` — show active clients
- [x] Replace hardcoded AMI IDs with `data` source lookups
- [x] Extract inline `user_data` script to a separate `.sh` file
- [x] Replace inbound SSH with SSM Session Manager (no open port, works while travelling)

## WireGuard evaluation (in progress)
- [x] Parallel WireGuard server, stateless, key and peer list in SSM
- [x] Elastic IP so client configs survive rebuilds
- [x] Prove instance replacement preserves endpoint and peers
- [ ] **Beta test: confirm UDP/51820 works from every network that matters**
      (home, LTE, office, hotel) — the one thing OpenVPN does that WG can't
- [ ] Decide: promote WireGuard and retire OpenVPN, or keep OpenVPN
- [ ] If promoting: fold `wireguard.tf` into `main.tf`, delete the CA machinery

- [x] Keep the peer list out of git so the repo is safe to publish publicly

## Later
- [ ] Add S3 backend for Terraform state
- [x] Encrypt the CA backup
- [ ] Store a CA backup copy off-laptop (passphrase-encrypted)
- [ ] IPv6 for the WireGuard tunnel (currently leaks v6 around the VPN)
- [ ] Remove hardcoded email from bootstrap script (use a variable)
- [ ] Add tags/naming convention for cost tracking
- [ ] Add support for multiple AWS regions