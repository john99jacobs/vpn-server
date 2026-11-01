# Backlog

## Up Next
- [x] Replace hardcoded AMI IDs with `data` source lookups
- [x] Extract inline `user_data` script to a separate `.sh` file
- [x] Replace inbound SSH with SSM Session Manager (no open port, works while travelling)

## WireGuard evaluation (done)
- [x] Parallel WireGuard server, stateless, key and peer list in SSM
- [x] Elastic IP so client configs survive rebuilds
- [x] Prove instance replacement preserves endpoint and peers
- [x] Keep the peer list out of git so the repo is safe to publish publicly
- [x] Confirm UDP/51820 works from every network that matters
      (home, LTE, office, hotel)
- [x] Decide: promote WireGuard and retire OpenVPN
- [x] Fold `wireguard.tf` into `main.tf`, delete the OpenVPN server and CA machinery

## Multi-region WireGuard

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
- [ ] Budget ~$12/mo per extra region (t3.micro, public IPv4, 8 GB gp3 root
      volume). Expect the fresh-EIP blackhole issue to recur per region.

## Later
- [x] Add S3 backend for Terraform state
- [ ] IPv6 for the WireGuard tunnel (currently leaks v6 around the VPN)
- [ ] Add tags/naming convention for cost tracking
