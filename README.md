# Deploy Ethereum nodes on AWS

This project provides a set of Ethereum nodes with an application load balancer in front of them for scaling requests.

# Architecture

Application Load balancer forwards requests to three Ethereum nodes.


# Requirements

- [Install terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
- [Create an AWS account](https://aws.amazon.com/premiumsupport/knowledge-center/create-and-activate-aws-account/)
- [Install the *awscli*](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and [define an AWS profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) pointing to an [AWS IAM role/user](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html) (administrator permissions).
- Define InfluxDB (used to collect metrics) password in AWS secret manager by running the below code:

    ````
    aws secretsmanager create-secret --region eu-west-1 \
    --name "influx/password" \
    --description "Influxdb password for user 'admin'." \
    --secret-string "YOUR_PASSWORD"

- [Create an S3 bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/create-bucket-overview.html) on your account to host the terraform state. Modify the *backend.tf* file to point to your bucket.
- Customize the variables in the *terraform.tfvars* file. The default variables will probably not be available.
- Customize the IP address ranges if required.

````
chain_data_backup_bucket = "eth-infra-nodes-backup"
infra_logs_bucket        = "eth-infra-nodes-logs"
eth_static_data_bucket   = "eth-infra-static-data"
chain_data_volume_size   = 1000
geth_public_key          = "geth_public_key_linux_9BA28146.key"
eth_node_instance_type   = "t3.2xlarge"
nodes_number             = 3
private_subnets_cidr     = ["192.168.0.48/28", "192.168.0.64/28", "192.168.0.80/28"]
public_subnets_cidr      = ["192.168.0.0/28", "192.168.0.16/28", "192.168.0.32/28"]
vpc_cidr                 = "192.168.0.0/24"
