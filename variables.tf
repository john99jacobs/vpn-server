
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
# Session Manager (see ./wg-client). Set this to a specific CIDR only as a
# break-glass measure, and unset it again afterwards.
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
