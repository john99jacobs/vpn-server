provider "aws" {
  region = var.aws_region
}

# Create the VPC
resource "aws_vpc" "vpn_vpc" {
  cidr_block = var.vpc_cidr
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
    from_port   = 1194
    to_port     = 1194
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
    Name = "vpn-sg"
  }
}

# Key Pair for SSH access
resource "aws_key_pair" "vpn_key" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)
}

# Spot Instance for Jump Box
resource "aws_spot_instance_request" "jump_box" {
  ami           = var.amazon_linux_ami
  instance_type = var.jump_box_instance_type
  subnet_id     = aws_subnet.public_subnet.id
  key_name      = aws_key_pair.vpn_key.key_name
  security_groups = [aws_security_group.jump_sg.name]

  spot_price = var.jump_box_spot_price  # Spot price per hour
  instance_interruption_behavior = "terminate"

  tags = {
    Name = "jump-box"
  }

  lifecycle {
    create_before_destroy = true  # Ensure replacement on termination
  }
}

# VPN Server (Normal Instance)
resource "aws_instance" "vpn_server" {
  ami           = var.amazon_linux_ami
  instance_type = var.vpn_server_instance_type
  subnet_id     = aws_subnet.private_subnet.id
  key_name      = aws_key_pair.vpn_key.key_name
  security_groups = [aws_security_group.vpn_sg.name]

  # Bootstrap script to install and configure OpenVPN
  user_data = <<-EOF
    #!/bin/bash
    apt update -y
    apt install -y openvpn easy-rsa

    # Set up Easy-RSA and generate keys
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
  value = aws_spot_instance_request.jump_box.public_ip
}

output "vpn_server_private_ip" {
  value = aws_instance.vpn_server.private_ip
}