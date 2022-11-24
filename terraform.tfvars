chain_data_backup_bucket = "eth-infra-nodes-backup"
infra_logs_bucket        = "eth-infra-nodes-logs"
eth_static_data_bucket   = "eth-infra-static-data"
eth_node_instance_type   = "t3.2xlarge"
nodes_number             = 3
private_subnets_cidr     = ["192.168.0.48/28", "192.168.0.64/28", "192.168.0.80/28"]
public_subnets_cidr      = ["192.168.0.0/28", "192.168.0.16/28", "192.168.0.32/28"]
vpc_cidr                 = "192.168.0.0/24"