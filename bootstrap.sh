#!/bin/bash
apt update -y
apt install -y openvpn easy-rsa

# Set up Easy-RSA and generate keys
export EASYRSA_BATCH=1
export EASYRSA_DN=org
export EASYRSA_REQ_COUNTRY=US
export EASYRSA_REQ_PROVINCE=CA
export EASYRSA_REQ_CITY=SanFrancisco
export EASYRSA_REQ_ORG=Default-Org
export EASYRSA_REQ_EMAIL=${easyrsa_email}
make-cadir ~/openvpn-ca
cd ~/openvpn-ca
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-req server nopass
./easyrsa sign-req server server
./easyrsa gen-dh
openvpn --genkey --secret ta.key

# Copy keys to OpenVPN directory
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/

# Generate initial CRL for revocation support
./easyrsa gen-crl
cp pki/crl.pem /etc/openvpn/crl.pem
chmod 644 /etc/openvpn/crl.pem

# Create OpenVPN server config
cat <<EOT > /etc/openvpn/server.conf
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA256
tls-auth ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
user nobody
group nogroup
crl-verify crl.pem
verb 3
EOT

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure firewall and route tables
ufw route allow in on tun0 out on ens5
ufw allow 1194/udp
ufw allow 1194/tcp
ufw allow 22/tcp
ufw allow out on ens5 to any port 53
iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
apt install iptables-persistent
netfilter-persistent save
netfilter-persistent reload
ufw enable

# Restart and enable OpenVPN
systemctl start openvpn@server
systemctl enable openvpn@server
