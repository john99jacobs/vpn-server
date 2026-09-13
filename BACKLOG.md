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

## Post-beta: multi-region WireGuard (only if WireGuard is adopted)

Goal is a nearer exit while travelling, plus geo-unblocking. **Not** redundancy —
WireGuard has no endpoint failover, so a dead region means switching tunnels by
hand. If HA is ever wanted it needs a different design (health-checked DNS).

- [ ] Second region (an EU one alongside `us-east-2`)
- [ ] Distinct keypair per region, per device. Sharing a key saves nothing: the
      endpoint, server public key and tunnel address differ per region, so a
      device needs one config per region either way. The apps generate a keypair
      per tunnel by default, and `wg-client add --pubkey` keeps it that way.
- [ ] One tunnel per region, one active at a time. Two `[Peer]` blocks in a
      single config does **not** work — `AllowedIPs = 0.0.0.0/0` can only belong
      to one peer.
- [ ] Give each region its own `/24` (`10.8.0.0/24`, `10.8.1.0/24`, ...) so
      `wg show` stays unambiguous and inter-region routing stays possible.
- [ ] Region-suffix the IAM role and instance profile: they are account-global
      and would collide on `wg-server`. Everything else (VPC, subnet, IGW, route
      table, key pair, SG, EIP, instance, both SSM parameters) is regional and
      needs duplicating. Parameter Store being regional is convenient here — the
      per-region key and peer list need no renaming.
- [ ] Restructure as a per-region module. This is the case modules exist for; the
      "no modules" convention was written for one server in one region. Provider
      aliases work for two regions and stop scaling after that. (Check whether
      Terraform 1.14 can iterate provider configurations directly — that would be
      cleaner than either.)
- [ ] Make `wg-client` region-aware (`--region`, plus `--all-regions` to register
      a distinct key in each).
- [ ] Budget ~$11-12/mo per extra region (instance + IPv4). Expect the fresh-EIP
      blackhole issue to recur per region.

- [x] Keep the peer list out of git so the repo is safe to publish publicly

## Later
- [ ] Add S3 backend for Terraform state
- [x] Encrypt the CA backup
- [ ] Store a CA backup copy off-laptop (passphrase-encrypted)
- [ ] IPv6 for the WireGuard tunnel (currently leaks v6 around the VPN)
- [ ] Remove hardcoded email from bootstrap script (use a variable)
- [ ] Add tags/naming convention for cost tracking
- [ ] Add support for multiple AWS regions