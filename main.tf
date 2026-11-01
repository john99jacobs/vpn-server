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

# Key Pair for SSH access
resource "aws_key_pair" "vpn_key" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)
}

# ---------------------------------------------------------------------------
# WireGuard server. Stateless by design: its only secret lives in SSM and is
# fetched at boot, and the peer list is a separate SSM parameter owned by
# ./wg-client. Replacing the instance costs nothing and invalidates no client,
# which is what lets it track the AMI data source and rebuild freely.
# ---------------------------------------------------------------------------

locals {
  wg_key_param  = "/vpn/wg/server-private-key"
  wg_pub_param  = "/vpn/wg/server-public-key"
  wg_peer_param = "/vpn/wg/peers"
}

# Written out of band by `./init-wg-server-key` (run once, before the
# first apply), so the private key never enters Terraform state. Terraform only
# needs the public half, to build client configs. A ParameterNotFound error here
# means that step was skipped.
data "aws_ssm_parameter" "wg_server_public_key" {
  name = local.wg_pub_param
}

# Terraform creates this parameter so a fresh deploy works, but does not own its
# contents: ./wg-client reads and writes it directly. Peer public keys are not
# secret, but they are a list of someone's devices, and this repo is public --
# so the access list lives in Parameter Store rather than in git. The audit trail
# is CloudTrail (which IAM identity called PutParameter) plus parameter version
# history, both of which attribute changes more reliably than a git author field.
resource "aws_ssm_parameter" "wg_peers" {
  name        = local.wg_peer_param
  description = "WireGuard peer list; managed by ./wg-client, not by Terraform"
  type        = "String"
  value       = "# no peers yet"
  tags        = { Name = "wg-peers" }

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------------------
# Stable endpoint. An EIP outlives the instance, so client configs keep working
# across rebuilds. Releasing it (a destroy, or -replace=aws_eip.wg) breaks every
# client config until ./wg-client refresh rewrites them and devices re-import.
# ---------------------------------------------------------------------------

resource "aws_eip" "wg" {
  domain = "vpc"
  tags   = { Name = "wg-eip" }
}

resource "aws_eip_association" "wg" {
  instance_id   = aws_instance.wg_server.id
  allocation_id = aws_eip.wg.id
}

resource "aws_security_group" "wg_sg" {
  name        = "wg-sg"
  description = "WireGuard server"
  vpc_id      = aws_vpc.vpn_vpc.id

  ingress {
    description = "WireGuard"
    from_port   = var.wg_port
    to_port     = var.wg_port
    protocol    = "udp"
    cidr_blocks = [var.allowed_vpn_cidr]
  }

  # Normally absent. Shell access is via Session Manager, which needs no inbound
  # port and does not care what network you are on -- the point being that a
  # fixed home CIDR is useless when travelling. Set emergency_ssh_cidr only to
  # break glass if SSM itself is broken.
  dynamic "ingress" {
    for_each = var.emergency_ssh_cidr == null ? [] : [var.emergency_ssh_cidr]
    content {
      description = "Break-glass SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wg-sg" }
}

# ---------------------------------------------------------------------------
# Instance profile: lets the host read its own key from SSM at boot, and brings
# Session Manager along, which is the prerequisite for dropping inbound SSH.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "wg_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wg" {
  name               = "wg-server"
  assume_role_policy = data.aws_iam_policy_document.wg_assume.json
  tags               = { Name = "wg-server" }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "wg_ssm_read" {
  statement {
    sid     = "ReadOwnWireGuardParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.wg_key_param}",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.wg_pub_param}",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.wg_peer_param}",
    ]
  }

  # Needed to decrypt the SecureString, scoped so the role cannot use the key
  # for anything but Parameter Store.
  statement {
    sid       = "DecryptSecureStringViaSSM"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "wg_ssm_read" {
  name   = "wg-ssm-read"
  role   = aws_iam_role.wg.id
  policy = data.aws_iam_policy_document.wg_ssm_read.json
}

resource "aws_iam_role_policy_attachment" "wg_ssm_core" {
  role       = aws_iam_role.wg.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "wg" {
  name = "wg-server"
  role = aws_iam_role.wg.name
}

# ---------------------------------------------------------------------------
# The server itself. Tracks the AMI data source on purpose: it is stateless, so
# a new Ubuntu image forcing a rebuild is the OS-upgrade mechanism, not a risk.
# ---------------------------------------------------------------------------

resource "aws_instance" "wg_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.wg_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = aws_key_pair.vpn_key.key_name
  vpc_security_group_ids = [aws_security_group.wg_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.wg.name

  user_data = templatefile("${path.module}/bootstrap-wg.sh", {
    aws_region       = var.aws_region
    server_key_param = local.wg_key_param
    server_pub_param = local.wg_pub_param
    peer_param       = local.wg_peer_param
    wg_address       = var.wg_server_address
    wg_port          = var.wg_port
  })

  # Rebuild on user_data change rather than leaving the running host stale.
  # Safe here precisely because the host holds nothing that matters.
  user_data_replace_on_change = true

  tags = { Name = "wg-server" }
}

# Outputs
output "aws_region" {
  value = var.aws_region
}

output "wg_server_public_ip" {
  description = "Stable WireGuard endpoint (EIP, survives instance replacement)"
  value       = aws_eip.wg.public_ip
}

# nonsensitive() because the provider marks every SSM parameter value sensitive,
# but a public key is not a secret -- it has to go into every client config.
output "wg_server_public_key" {
  description = "WireGuard server public key, for client configs"
  value       = nonsensitive(data.aws_ssm_parameter.wg_server_public_key.value)
}

output "wg_port" {
  value = var.wg_port
}

output "wg_server_instance_id" {
  description = "Used by ./wg-client to reach the server over Session Manager"
  value       = aws_instance.wg_server.id
}
