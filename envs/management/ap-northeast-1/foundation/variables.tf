variable "account_id" {
  description = "Management account ID (guards against applying to the wrong account)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "name" {
  description = "Name prefix of the foundation resources."
  type        = string
}

variable "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
}

variable "private_subnets" {
  description = "Private subnets keyed by availability zone."
  type        = map(string)
}
