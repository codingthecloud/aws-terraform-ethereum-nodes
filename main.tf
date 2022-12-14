provider "aws" {
  region = "eu-west-1"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["amazon"]
}

resource "aws_instance" "ethereum_node" {
  depends_on = [
    aws_s3_bucket.eth_static_data_bucket,
    aws_s3_object.geth_pgp_public_key,
    aws_s3_object.object_healthcheck,
    aws_instance.influxdb_node,
    aws_ssm_parameter.influxdb_node_private_ip,
    aws_ssm_parameter.cloudwatch_agent_configuration
  ]
  count         = var.nodes_number
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.eth_node_instance_type
  subnet_id     = aws_subnet.eth_public_subnet[count.index].id
  tags = {
    Name = "ethereum-node-${count.index}"
  }
  user_data = templatefile("ec2_user_data_eth_node.sh", {
    eth_static_data_bucket = aws_s3_bucket.eth_static_data_bucket.bucket,
    health_check_package   = aws_s3_object.object_healthcheck.id
    }
  )
  iam_instance_profile   = aws_iam_instance_profile.eth_node_profile.name
  vpc_security_group_ids = [aws_security_group.ethereum_node_sg.id]
}

resource "aws_volume_attachment" "ebs_attach_chain_data" {
  count       = var.nodes_number
  device_name = "/dev/sdf" # when using Nitro instances the volume name is changed by the instance to nvme1n1
  volume_id   = aws_ebs_volume.chain_data[count.index].id
  instance_id = aws_instance.ethereum_node[count.index].id
}

data "aws_ebs_default_kms_key" "current" {}

data "aws_kms_key" "current" {
  key_id = data.aws_ebs_default_kms_key.current.key_arn
}

resource "aws_ebs_volume" "chain_data" {
  count             = var.nodes_number
  size              = var.chain_data_volume_size
  availability_zone = data.aws_availability_zones.available_az.names[count.index]
  tags = {
    Name = "ethereum-chain-data-${count.index}"
    Role = "eth-node"
  }
  encrypted  = true
  kms_key_id = data.aws_kms_key.current.arn
  type       = "gp3"
}

resource "aws_backup_plan" "ethereum_chain_data" {
  name = "ethereum-chain-data-volumes-plan"

  rule {
    rule_name         = "ethereum-chain-data-volumes-plan"
    target_vault_name = aws_backup_vault.ethereum_chain_data.name
    schedule          = "cron(0 */3 * * ? *)"

    lifecycle {
      delete_after = 2
    }
  }
}
resource "aws_iam_role" "aws_backup_service_role" {
  name               = "AWSBackupServiceRole"
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["sts:AssumeRole"],
      "Effect": "allow",
      "Principal": {
        "Service": ["backup.amazonaws.com"]
      }
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "aws_backup_service_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.aws_backup_service_role.name
}

# resource "aws_backup_selection" "eth_nodes_volumes_selection" {
#   iam_role_arn = aws_iam_role.aws_backup_service_role.arn
#   name         = "eth-nodes-volumes-selection"
#   plan_id      = aws_backup_plan.ethereum_chain_data.id

#   selection_tag {
#     type  = "STRINGEQUALS"
#     key   = "Role"
#     value = "eth-node"
#   }
# }

resource "aws_backup_vault" "ethereum_chain_data" {
  name = "ethereum-chain-data"
}

resource "aws_iam_instance_profile" "eth_node_profile" {
  name = "eth-node-profile"
  role = aws_iam_role.eth_node_instance_role.name
}

resource "aws_iam_role" "eth_node_instance_role" {
  path                = "/"
  managed_policy_arns = [data.aws_iam_policy.access_nodes_through_ssm.arn, data.aws_iam_policy.cloudwatch_agent_policy.arn]
  name_prefix         = "EthNodeInstanceRole"
  inline_policy {
    name = "eth-node-s3-access"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "s3:ListBucket",
            "s3:PutObject",
            "s3:GetBucketLocation",
            "s3:GetObject"
          ]
          Effect = "Allow"
          Resource = [
            aws_s3_bucket.chain_data_backup_bucket.arn,
            "${aws_s3_bucket.chain_data_backup_bucket.arn}/*",
            aws_s3_bucket.eth_static_data_bucket.arn,
            "${aws_s3_bucket.eth_static_data_bucket.arn}/*"
          ]
        },
        {
          Action = [
            "ssm:GetParameter",
            "ssm:GetParameters"
          ]
          Effect = "Allow"
          Resource = [
            aws_ssm_parameter.influxdb_node_private_ip.arn
          ]
        },
        {
          Action = [
            "secretsmanager:DescribeSecret",
            "secretsmanager:GetSecretValue"
          ]
          Effect = "Allow"
          Resource = [
            "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:influx/*"
          ]
        }
      ]
    })
  }
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

data "aws_iam_policy" "access_nodes_through_ssm" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy" "cloudwatch_agent_policy" {
  arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_security_group" "ethereum_node_sg" {
  name        = "eth-node-sg"
  description = "Allow eth node traffic and SSM connection from VPC"
  vpc_id      = aws_vpc.eth_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  ingress {
    from_port   = 8545
    to_port     = 8545
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  ingress {
    from_port   = 30303
    to_port     = 30303
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30303
    to_port     = 30303
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  # improve this rule. Might not be needed.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    # Necessary if changing 'name' or 'name_prefix' properties.
    create_before_destroy = true
  }

}

data "aws_availability_zones" "available_az" {
  state = "available"
}

resource "aws_vpc" "eth_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"

  tags = {
    Name = "eth-vpc"
  }
}

resource "aws_subnet" "eth_public_subnet" {
  count                   = var.nodes_number
  vpc_id                  = aws_vpc.eth_vpc.id
  cidr_block              = var.public_subnets_cidr[count.index]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available_az.names[count.index]
  tags = {
    Name = "eth-subnet-public-${count.index}"
    Tier = "public"
  }
}

resource "aws_subnet" "eth_private_subnet" {
  count                   = var.nodes_number
  vpc_id                  = aws_vpc.eth_vpc.id
  cidr_block              = var.private_subnets_cidr[count.index]
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available_az.names[count.index]
  tags = {
    Name = "eth-subnet-private-${count.index}"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "eth_igw" {
  vpc_id = aws_vpc.eth_vpc.id
  tags = {
    Name = "eth-igw"
  }
}

resource "aws_route_table" "eth_public_crt" {
  vpc_id = aws_vpc.eth_vpc.id

  route {
    //associated subnet can reach everywhere
    cidr_block = "0.0.0.0/0"
    //CRT uses this IGW to reach internet
    gateway_id = aws_internet_gateway.eth_igw.id
  }
}

resource "aws_route_table_association" "eth_crt_public_subnet" {
  count          = var.nodes_number
  subnet_id      = aws_subnet.eth_public_subnet[count.index].id
  route_table_id = aws_route_table.eth_public_crt.id
}

resource "aws_s3_bucket" "chain_data_backup_bucket" {
  bucket = var.chain_data_backup_bucket
}

resource "aws_s3_bucket_server_side_encryption_configuration" "chain_data_bucket_encryption" {
  bucket = aws_s3_bucket.chain_data_backup_bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "chain_data_bucket_block_public" {
  bucket = aws_s3_bucket.chain_data_backup_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_security_group" "eth_lb_sg" {
  name        = "eth-lb-sg"
  description = "Allow eth RPC calls to nodes through LB"
  vpc_id      = aws_vpc.eth_vpc.id

  ingress {
    from_port   = 8545
    to_port     = 8545
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  egress {
    from_port   = 8545
    to_port     = 8545
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  egress {
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  lifecycle {
    # Necessary if changing 'name' or 'name_prefix' properties.
    create_before_destroy = true
  }

}

resource "aws_s3_bucket" "infra_logs" {
  bucket        = var.infra_logs_bucket
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "infra_logs_bucket_encryption" {
  bucket = aws_s3_bucket.infra_logs.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "infra_logs_bucket_block_public" {
  bucket = aws_s3_bucket.infra_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "allow_access_from_elb_account" {
  bucket = aws_s3_bucket.infra_logs.id
  policy = data.aws_iam_policy_document.allow_access_from_elb_account.json
}

data "aws_iam_policy_document" "allow_access_from_elb_account" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [var.aws_elb_account]
    }

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.infra_logs.arn}/*"
    ]
  }
}

resource "aws_lb" "eth_nodes_lb" {
  name               = "eth-nodes-lb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.eth_lb_sg.id]
  subnets            = [for subnet_id in aws_subnet.eth_private_subnet : subnet_id.id]

  enable_deletion_protection = false

  tags = {
    Environment = "eth-nodes-lb"
  }
  access_logs {
    bucket  = aws_s3_bucket.infra_logs.bucket
    prefix  = "alb-eth-nodes"
    enabled = true
  }

}

resource "aws_lb_target_group" "eth_nodes_tg" {
  name        = "eth-nodes-target-group"
  port        = 8545
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.eth_vpc.id

  health_check {
    enabled           = true
    healthy_threshold = 3  # trials
    interval          = 30 # seconds
    matcher           = "200"
    protocol          = "HTTP"
    port              = 50000
    timeout           = 5 # seconds
  }
}

resource "aws_lb_target_group_attachment" "ec2_instance_tg_attach" {
  count            = var.nodes_number
  target_group_arn = aws_lb_target_group.eth_nodes_tg.arn
  target_id        = aws_instance.ethereum_node[count.index].id
  port             = 8545
}

resource "aws_lb_listener" "eth_nodes_listener" {
  load_balancer_arn = aws_lb.eth_nodes_lb.arn
  port              = "8545"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eth_nodes_tg.arn
  }
}

resource "aws_s3_bucket" "eth_static_data_bucket" {
  bucket = var.eth_static_data_bucket
}

resource "aws_s3_bucket_server_side_encryption_configuration" "eth_static_data_bucket_encryption" {
  bucket = aws_s3_bucket.eth_static_data_bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "eth_static_data_bucket_block_public" {
  bucket = aws_s3_bucket.eth_static_data_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "object_healthcheck" {
  bucket = aws_s3_bucket.eth_static_data_bucket.bucket
  key    = "eth-node-lb-healthcheck-master.zip"
  source = "assets/eth-node-lb-healthcheck-master.zip"

  # The filemd5() function is available in Terraform 0.11.12 and later
  # For Terraform 0.11.11 and earlier, use the md5() function and the file() function:
  # etag = "${md5(file("path/to/file"))}"
  etag = filemd5("assets/eth-node-lb-healthcheck-master.zip")
}

resource "aws_s3_object" "geth_pgp_public_key" {
  bucket = aws_s3_bucket.eth_static_data_bucket.bucket
  key    = var.geth_public_key
  source = "assets/public-keys/${var.geth_public_key}"

  # The filemd5() function is available in Terraform 0.11.12 and later
  # For Terraform 0.11.11 and earlier, use the md5() function and the file() function:
  # etag = "${md5(file("path/to/file"))}"
  etag = filemd5("assets/public-keys/${var.geth_public_key}")
}

resource "aws_instance" "influxdb_node" {
  depends_on = [
    aws_nat_gateway.nat_gateway,
    aws_ssm_parameter.cloudwatch_agent_configuration
  ]
  count         = 1
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.eth_node_instance_type
  subnet_id     = aws_subnet.eth_private_subnet[count.index].id
  tags = {
    Name = "influxdb-node-${count.index}"
  }
  user_data              = file("ec2_user_data_influxdb.sh")
  iam_instance_profile   = aws_iam_instance_profile.influxdb_node_profile.name
  vpc_security_group_ids = [aws_security_group.influxdb_node_sg.id]
  root_block_device {
    volume_size = 200
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = data.aws_kms_key.current.arn
  }
}

resource "aws_eip" "nat_gateway_eip" {
  vpc = true
}

resource "aws_route_table" "nat_gateway" {
  count  = 1
  vpc_id = aws_vpc.eth_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway[count.index].id
  }
}

resource "aws_route_table_association" "nat_gateway" {
  count          = 1
  subnet_id      = aws_subnet.eth_private_subnet[count.index].id
  route_table_id = aws_route_table.nat_gateway[count.index].id
}

resource "aws_nat_gateway" "nat_gateway" {
  count         = 1
  allocation_id = aws_eip.nat_gateway_eip.id
  subnet_id     = aws_subnet.eth_public_subnet[count.index].id

  depends_on = [aws_internet_gateway.eth_igw]
}

resource "aws_security_group" "influxdb_node_sg" {
  name        = "influxdb-node-sg"
  description = "Allow influxdb node traffic and SSM connection from VPC"
  vpc_id      = aws_vpc.eth_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  ingress {
    from_port   = 8086
    to_port     = 8086
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    # Necessary if changing 'name' or 'name_prefix' properties.
    create_before_destroy = true
  }

}

resource "aws_iam_instance_profile" "influxdb_node_profile" {
  name = "influxdb-node-profile"
  role = aws_iam_role.influxdb_node_instance_role.name
}

resource "aws_iam_role" "influxdb_node_instance_role" {
  path                = "/"
  managed_policy_arns = [data.aws_iam_policy.access_nodes_through_ssm.arn, data.aws_iam_policy.cloudwatch_agent_policy.arn]
  name_prefix         = "InfluxdbNodeInstanceRole"
  inline_policy {
    name = "get-influx-admin-password"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "secretsmanager:GetSecretValue",
            "secretsmanager:CreateSecret",
            "secretsmanager:TagResource",
            "secretsmanager:DescribeSecret",
            "secretsmanager:PutSecretValue"
          ]
          Effect = "Allow"
          Resource = [
            "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:influx/*"
          ]
        },
      ]
    })
  }
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_ssm_parameter" "influxdb_node_private_ip" {
  name  = "/influx/private-ip"
  type  = "String"
  value = aws_instance.influxdb_node[0].private_ip
}


resource "aws_security_group" "grafana_sg" {
  name        = "grafana-sg"
  description = "Allow Grafana traffic"
  vpc_id      = aws_vpc.eth_vpc.id

  egress {
    from_port   = 8086
    to_port     = 8086
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eth_vpc.cidr_block]
  }

  lifecycle {
    # Necessary if changing 'name' or 'name_prefix' properties.
    create_before_destroy = true
  }

}

resource "aws_ssm_parameter" "cloudwatch_agent_configuration" {
  name        = "AmazonCloudWatch-Config.json"
  description = "CloudWatch configuration for ec2 instances"
  type        = "String"
  value       = file("assets/cloudwatch_agent_configuration.json")
} 