provider "aws" {
  region = var.aws_region
}

# Look up the latest Canonical Ubuntu 24.04 (Noble) AMI instead of hardcoding an ID
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
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

# Create a Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpn_vpc.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet"
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

# Security Group for VPN Server
resource "aws_security_group" "vpn_sg" {
  vpc_id = aws_vpc.vpn_vpc.id

  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = [var.allowed_vpn_cidr]
  }

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
    Name = "vpn-sg"
  }
}

# Key Pair for SSH access
resource "aws_key_pair" "vpn_key" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)
}

# VPN Server Instance
resource "aws_instance" "vpn_server" {
  # Pinned, NOT data.aws_ami.ubuntu.id. This instance holds the OpenVPN CA and
  # ta.key, so replacing it invalidates every issued client cert. Bump
  # vpn_server_ami only when you intend a rebuild, and back up /root/openvpn-ca
  # first. The WireGuard server tracks the AMI data source instead -- it is
  # stateless, so it can be replaced freely.
  ami                    = var.vpn_server_ami
  instance_type          = var.vpn_server_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.vpn_key.key_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]

  # Bootstrap script to install and configure OpenVPN.
  # Note: bootstrap.sh is rendered by templatefile(), so any literal ${...} or
  # %{...} the shell needs must be escaped as $${...} / %%{...}.
  user_data = templatefile("${path.module}/bootstrap.sh", {
    easyrsa_email = var.easyrsa_email
  })

  tags = {
    Name = "vpn-server"
  }
}

# Outputs
output "vpn_server_public_ip" {
  value = aws_instance.vpn_server.public_ip
}

output "vpn_server_private_ip" {
  value = aws_instance.vpn_server.private_ip
}
