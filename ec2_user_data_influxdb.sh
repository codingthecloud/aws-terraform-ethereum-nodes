#!/bin/bash

############################
# Update instance packages #
############################

add-apt-repository -y ppa:ethereum/ethereum
apt-get update -y && apt-get upgrade -y && apt-get install -y \
    awscli \
    xfsprogs \
    nvme-cli \
    jq \
    unzip \
    curl

###########################
# Install cloudwatch agent#
###########################

wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c ssm:AmazonCloudWatch-Config.json -s

##################
# install influx #
##################

influxdb_host="https://dl.influxdata.com/influxdb/releases/"
influxdb_release="influxdb2-2.5.1-amd64"
wget "$influxdb_host$influxdb_release.deb"
sudo dpkg -i "$influxdb_release.deb"

wget https://dl.influxdata.com/influxdb/releases/influxdb2-client-2.5.0-linux-amd64.tar.gz
tar xvzf influxdb2-client-2.5.0-linux-amd64.tar.gz
cp influxdb2-client-2.5.0-linux-amd64/influx /usr/local/bin/

systemctl enable influxdb
systemctl start influxdb

EC2_AVAIL_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
EC2_REGION="$(echo $EC2_AVAIL_ZONE | sed 's/[a-z]$//')"

admin_pwd=$(aws secretsmanager get-secret-value --region "$EC2_REGION" --secret-id "influx/password" --output text --query 'SecretString')

influx setup -u admin -p "$admin_pwd" -o geth -b geth -f
bucket_id=$(influx bucket list -n geth --json | jq -r ".[0].id")
token=$(influx auth create --org geth --read-bucket "$bucket_id" --write-bucket "$bucket_id" --json | jq -r ".token")

aws secretsmanager describe-secret --secret-id influx/geth-token --region "$EC2_REGION" && token_exists=true || token_exists=false


if $token_exists ; 
then
  aws secretsmanager put-secret-value \
      --secret-id "influx/geth-token" \
      --secret-string "$token" \
      --region "$EC2_REGION"
else
  aws secretsmanager create-secret \
      --name "influx/geth-token" \
      --description "token used by the Geth clients." \
      --secret-string "$token" \
      --region "$EC2_REGION"
fi
