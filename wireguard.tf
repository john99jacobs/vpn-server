# ---------------------------------------------------------------------------
# WireGuard server (beta, runs in parallel with OpenVPN)
#
# Deliberately in its own file rather than main.tf, against the single-file
# convention: this is an experiment, and keeping it separable means backing it
# out is `git rm wireguard.tf` plus a destroy. If WireGuard is promoted, this
# folds into main.tf and the OpenVPN resources come out.
#
# Nothing here is stateful. The server's only secret lives in SSM and is fetched
# at boot, and the peer list is a separate SSM parameter owned by ./wg-client.
# Replacing the instance costs nothing and invalidates no client, which is the
# entire point.
# ---------------------------------------------------------------------------

variable "wg_port" {
  description = "UDP port for WireGuard"
  type        = number
  default     = 51820
}

variable "wg_server_address" {
  description = "Server address inside the VPN subnet, with prefix"
  type        = string
  default     = "10.8.0.1/24"
}

variable "wg_instance_type" {
  description = "EC2 instance type for the WireGuard server"
  type        = string
  default     = "t3.micro"
}

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
# across rebuilds. Not attached to the OpenVPN server: doing so would change
# its address and break the five .ovpn files already on devices.
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
