#!/bin/bash
# WireGuard server bootstrap. Rendered by templatefile(), so a braced shell
# expansion must be escaped with a doubled dollar sign. Shell variables here all
# use the unbraced $VAR form, which passes through the template untouched.
#
# This host is stateless by design: the only secret it holds is fetched from SSM
# at boot and never written anywhere but /etc/wireguard/wg0.conf (mode 600).
# It can be destroyed and recreated at will without invalidating any client.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard unzip curl

# Ubuntu 24.04 ships no awscli package (noble dropped v1 and never packaged v2),
# so install v2 from the official archive. Arch-aware so this still works if the
# instance type moves to arm64.
case "$(uname -m)" in
  x86_64)  AWS_ARCH=x86_64 ;;
  aarch64) AWS_ARCH=aarch64 ;;
  *)       echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$AWS_ARCH.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
rm -rf /tmp/awscliv2.zip /tmp/aws
aws --version

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
sysctl --system

install -d -m 700 /etc/wireguard

# Renders wg0.conf from SSM and applies it. Used both on first boot and by the
# timer below, so there is exactly one path that builds the config.
cat > /usr/local/bin/wg-sync-peers <<'INNER'
#!/bin/bash
set -euo pipefail

REGION="${aws_region}"
KEY_PARAM="${server_key_param}"
PEER_PARAM="${peer_param}"
WG_ADDRESS="${wg_address}"
WG_PORT="${wg_port}"

WAN_IF=$(ip route show default | awk '{print $5; exit}')
[ -n "$WAN_IF" ] || { echo "could not determine default interface" >&2; exit 1; }

PRIV=$(aws ssm get-parameter --region "$REGION" --name "$KEY_PARAM" \
  --with-decryption --query Parameter.Value --output text)
PEERS=$(aws ssm get-parameter --region "$REGION" --name "$PEER_PARAM" \
  --query Parameter.Value --output text)

NAT_UP="iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -A FORWARD -i %i -o $WAN_IF -j ACCEPT; iptables -A FORWARD -i $WAN_IF -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT"
NAT_DOWN="iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -D FORWARD -i %i -o $WAN_IF -j ACCEPT; iptables -D FORWARD -i $WAN_IF -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
  echo "# Managed by wg-sync-peers. Local edits are overwritten."
  echo "[Interface]"
  echo "Address = $WG_ADDRESS"
  echo "ListenPort = $WG_PORT"
  echo "PrivateKey = $PRIV"
  echo "PostUp = $NAT_UP"
  echo "PostDown = $NAT_DOWN"
  echo
  echo "$PEERS"
} > "$TMP"
install -m 600 "$TMP" /etc/wireguard/wg0.conf

# syncconf applies peer changes without dropping existing sessions; a cold
# interface needs the full bring-up instead.
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl enable --now wg-quick@wg0
fi
INNER
chmod 755 /usr/local/bin/wg-sync-peers

cat > /etc/systemd/system/wg-sync-peers.service <<'INNER'
[Unit]
Description=Sync WireGuard peers from SSM
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-sync-peers
INNER

# Peers are added by writing the SSM parameter, so the server polls rather than
# needing to be reachable for a push. Adding a client takes effect within ~2min
# and does not disturb connected peers.
cat > /etc/systemd/system/wg-sync-peers.timer <<'INNER'
[Unit]
Description=Periodically sync WireGuard peers from SSM

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
INNER

/usr/local/bin/wg-sync-peers
systemctl daemon-reload
systemctl enable --now wg-sync-peers.timer

ufw allow ${wg_port}/udp
ufw allow 22/tcp
ufw --force enable
