
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

variable "amazon_linux_ami" {
  description = "AMI ID for Amazon Linux 2"
  type        = string
  default     = "ami-088d38b423bff245f"
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

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_vpn_cidr" {
  description = "CIDR block for VPN access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "jump_box_instance_type" {
  description = "EC2 instance type for the jump box"
  type        = string
  default     = "t2.micro"
}

variable "jump_box_spot_price" {
  description = "maximum spot price for the jump box spot instance"
  type        = string
  default     = "0.0035"
}

variable "vpn_server_instance_type" {
  description = "EC2 instance type for the VPN server"
  type        = string
  default     = "t3.micro"
}
