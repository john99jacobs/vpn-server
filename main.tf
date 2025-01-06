provider "aws" {
  region = var.aws_region
}

# Create the VPC
resource "aws_vpc" "vpn_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "vpn-vpc"
  }
}

# Create a Public Subnet for the Jump Box
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpn_vpc.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet"
  }
}

# Create a Private Subnet for the VPN Server
resource "aws_subnet" "private_subnet" {
  vpc_id     = aws_vpc.vpn_vpc.id
  cidr_block = var.private_subnet_cidr
  tags = {
    Name = "private-subnet"
  }
}

# Attach Internet Gateway to the VPC
resource "aws_internet_gateway" "vpn_igw" {
  vpc_id = aws_vpc.vpn_vpc.id
  tags = {
    Name = "vpn-igw"
  }
}

# Allocate an Elastic IP for the NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "nat-eip"
  }
}

# Create a NAT Gateway in the Public Subnet
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  tags = {
    Name = "nat-gateway"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpn_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vpn_igw.id
  }
  tags = {
    Name = "public-route-table"
  }
}

# Associate Route Table with Public Subnet
resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Route Table for Private Subnet
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.vpn_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
  tags = {
    Name = "private-route-table"
  }
}

# Associate Route Table with Private Subnet
resource "aws_route_table_association" "private_subnet_association" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_route_table.id
}

# Security Group for Jump Box
resource "aws_security_group" "jump_sg" {
  vpc_id = aws_vpc.vpn_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jump-sg"
  }
}

# Security Group for VPN Server
resource "aws_security_group" "vpn_sg" {
  vpc_id = aws_vpc.vpn_vpc.id

  ingress {
    from_port       = 1194
    to_port         = 1194
    protocol        = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 53
    to_port         = 53
    protocol        = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vpn-sg"
  }
}

# Security Group for NLB
resource "aws_security_group" "nlb_sg" {
  vpc_id = aws_vpc.vpn_vpc.id

  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = [var.allowed_vpn_cidr]
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.allowed_vpn_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nlb-sg"
  }
}

# Key Pair for SSH access
resource "aws_key_pair" "vpn_key" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)
}

# Jump Box Instance
resource "aws_instance" "jump_box" {
  ami                    = var.amazon_linux_ami
  instance_type          = var.jump_box_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.vpn_key.key_name
  vpc_security_group_ids = [aws_security_group.jump_sg.id]

  tags = {
    Name = "jump-box"
  }
}

# VPN Server Instance
resource "aws_instance" "vpn_server" {
  ami                    = var.ubuntu_ami
  instance_type          = var.vpn_server_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.vpn_key.key_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]
  depends_on             = [aws_nat_gateway.nat_gateway]

  # Bootstrap script to install and configure OpenVPN
  user_data = <<-EOF
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
    export EASYRSA_REQ_EMAIL=EASYRSA_EMAIL_PLACEHOLDER    
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

    # Create client keys and certs
    ./easyrsa build-client-full 'client1' nopass
    ./easyrsa build-client-full 'client2' nopass

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
  EOF

  tags = {
    Name = "vpn-server"
  }
}

# Outputs
output "jump_box_public_ip" {
  value = aws_instance.jump_box.public_ip
}

output "vpn_server_public_ip" {
  value = aws_instance.vpn_server.public_ip
}

# Network Load Balancer for VPN Traffic
resource "aws_lb" "vpn_nlb" {
  name               = "vpn-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public_subnet.id]
  security_groups    = [aws_security_group.nlb_sg.id]

  tags = {
    Name = "vpn-nlb"
  }
}

# Target Group for VPN Server
resource "aws_lb_target_group" "vpn_target_group" {
  name        = "vpn-target-group"
  protocol    = "UDP"
  port        = 1194
  vpc_id      = aws_vpc.vpn_vpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "22"
  }

  tags = {
    Name = "vpn-target-group"
  }
}

# Listener for Network Load Balancer
resource "aws_lb_listener" "vpn_listener" {
  load_balancer_arn = aws_lb.vpn_nlb.arn
  port              = 1194
  protocol          = "UDP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vpn_target_group.arn
  }
}

# Target Group for VPN Server DNS
resource "aws_lb_target_group" "vpn_dns_target_group" {
  name        = "vpn-dns-target-group"
  protocol    = "UDP"
  port        = 53
  vpc_id      = aws_vpc.vpn_vpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "22"
  }

  tags = {
    Name = "vpn-dns-target-group"
  }
}

# Listener for Network Load Balancer DNS
resource "aws_lb_listener" "vpn_dns_listener" {
  load_balancer_arn = aws_lb.vpn_nlb.arn
  port              = 53
  protocol          = "UDP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vpn_dns_target_group.arn
  }
}

# Add VPN Server to the Target Group
resource "aws_lb_target_group_attachment" "vpn_target_attachment" {
  target_group_arn = aws_lb_target_group.vpn_target_group.arn
  target_id        = aws_instance.vpn_server.id
  port             = 1194
}

# Add VPN Server to the Target Group DNS
resource "aws_lb_target_group_attachment" "vpn_dns_target_attachment" {
  target_group_arn = aws_lb_target_group.vpn_dns_target_group.arn
  target_id        = aws_instance.vpn_server.id
  port             = 53
}

output "nlb_dns_name" {
  value       = aws_lb.vpn_nlb.dns_name
  description = "The DNS name of the Network Load Balancer for the VPN server."
}
