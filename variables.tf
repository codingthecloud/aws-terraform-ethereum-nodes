variable "chain_data_backup_bucket" {
  type = string
}
variable "chain_data_volume_size" {
  type = string
}
variable "eth_node_instance_type" {
  type = string
}

variable "infra_logs_bucket" {
  type = string
}

variable "nodes_number" {
  type = number
}

variable "public_subnets_cidr" {
  type = list(string)
}

variable "private_subnets_cidr" {
  type = list(string)
}

variable "eth_static_data_bucket" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "geth_public_key" {
  type = string
}