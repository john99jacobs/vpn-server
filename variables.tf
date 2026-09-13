
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "key_pair_name" {
  description = "Name of the SSH key pair"
  type        = string
  default     = "vpn-key"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# Deliberately null: there is no inbound SSH by default. Shell access is via
# Session Manager (see ./vpn-client and ./wg-client). Set this to a specific CIDR
# only as a break-glass measure, and unset it again afterwards.
variable "emergency_ssh_cidr" {
  description = "CIDR allowed inbound SSH. null means no SSH ingress at all."
  type        = string
  default     = null
}

variable "allowed_vpn_cidr" {
  description = "CIDR block for VPN access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "easyrsa_email" {
  description = "Email for Easy-RSA certificate authority"
  type        = string
}

variable "vpn_server_ami" {
  description = "AMI for the OpenVPN server. Pinned on purpose -- see the comment on aws_instance.vpn_server."
  type        = string
  default     = "ami-0933f4f9e0a0fc3a5" # Ubuntu 24.04 noble, us-east-2, in use since 2026-07-12
}

variable "vpn_server_instance_type" {
  description = "EC2 instance type for the VPN server"
  type        = string
  default     = "t3.micro"
}
