#!/bin/bash

############################
# Update instance packages #
############################

add-apt-repository -y ppa:ethereum/ethereum
apt-get update -y && apt-get upgrade -y && apt-get install -y \
    awscli \
    nodejs \
    npm \
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

##########################
# Creating user ethereum #
##########################

useradd -m ethereum
usermod -a -G ethereum ethereum
usermod --shell /bin/bash ethereum

#####################################################################
# Create key used by Prysm validator to interact with Geth executor #
#####################################################################

openssl rand -hex 32 | tr -d "\n" > /home/ethereum/jwt.hex
chown ethereum:ethereum /home/ethereum/jwt.hex

####################################
# Mount volume for blockchain data #
####################################

volume_name="nvme1n1"
volume_path="/dev/$volume_name"
if [ "$(file -s $volume_path)" = "$volume_path: data" ]; then
    echo "Formatting new disk"
    mkfs -t xfs "$volume_path"
else
	echo "Disk is already formatted"
fi
# mount destination
mount_point="/data"
chain_data_path="$mount_point/chain-data"
mkdir "$mount_point"
cp /etc/fstab /etc/fstab.orig

volume_id=''
while [ -z "$volume_id" ]; do
    volume_id=$(lsblk -ro +UUID | grep "$volume_name" | cut -f8 -d' ')
    echo "Waiting 5 seconds for UUID to become available"
    sleep 5
done
echo "Volume UUID is: $volume_id"
echo "UUID=$volume_id  $mount_point xfs  defaults,nofail  0  2" >> /etc/fstab

mount -a

if [ -d "$chain_data_path" ]; then
  echo "Geth data directory exists. Chain data will be restored."
else
  mkdir "$chain_data_path"
fi
chown ethereum:ethereum -R "$chain_data_path"

################
# Install Geth #
################

geth_public_key=geth_public_key_linux_9BA28146.key
# variable eth_static_data_bucket comes from terraform template resource
aws s3 cp "s3://${eth_static_data_bucket}/$geth_public_key" $geth_public_key
gpg --import ./$geth_public_key

geth_server="https://gethstore.blob.core.windows.net/builds/"
geth_release=geth-alltools-linux-amd64-1.10.26-e5eb32ac

geth_binary=$geth_release.tar.gz
wget $geth_server$geth_binary -O $geth_binary
tar -xvf $geth_binary

geth_asc=$geth_release.tar.gz.asc
wget $geth_server$geth_asc -O $geth_asc

gpg --verify $geth_asc

mv $geth_release/* /usr/bin

#########################
# Creating Geth service #
#########################

private_ip=$(ec2metadata --local-ipv4)
EC2_AVAIL_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
EC2_REGION="$(echo $EC2_AVAIL_ZONE | sed 's/[a-z]$//')"

# Retrieve token for accessing influxdb
token_exists=false
while ! $token_exists;do
  aws secretsmanager describe-secret --secret-id influx/geth-token --region "$EC2_REGION" && token_exists=true || token_exists=false
  sleep 10
  echo "Waiting for influxdb token to become available"
done

influxdb_token=$(aws secretsmanager get-secret-value --region "$EC2_REGION" --secret-id "influx/geth-token" --output text --query 'SecretString')
influxdb_private_ip=$(aws ssm get-parameter --region "$EC2_REGION" --name "/influx/private-ip" --output text --query 'Parameter.Value')
cat << FINISH > /etc/systemd/system/geth.service
[Unit]
Description=Geth

[Service]
Type=simple
User=ethereum
Restart=always
RestartSec=12
ExecStart=/usr/bin/geth --datadir "$chain_data_path" --mainnet --syncmode "snap" --authrpc.addr localhost --authrpc.port 8551 --authrpc.vhosts localhost --authrpc.jwtsecret /home/ethereum/jwt.hex --http --http.api eth,net,engine,admin --http.addr $private_ip --http.vhosts "*" --metrics --metrics.influxdbv2 --metrics.influxdb.bucket geth --metrics.influxdb.organization geth --metrics.influxdb.token "$influxdb_token" --metrics.influxdb.endpoint "http://$influxdb_private_ip:8086" --metrics.influxdb.tags "host=$private_ip"

[Install]
WantedBy=default.target
FINISH

systemctl daemon-reload
systemctl enable geth.service

service geth start

##########################
# Creating Prysm service #
##########################

mkdir /home/ethereum/prysm
curl https://raw.githubusercontent.com/prysmaticlabs/prysm/master/prysm.sh --output /home/ethereum/prysm/prysm.sh
chmod +x /home/ethereum/prysm/prysm.sh
chown -R ethereum:ethereum /home/ethereum/prysm

cat << FINISH > /etc/systemd/system/prysm.service
[Unit]
Description=Prysm

[Service]
Type=simple
User=ethereum
Restart=always
RestartSec=12
ExecStart=/home/ethereum/prysm/prysm.sh beacon-chain --accept-terms-of-use --execution-endpoint=http://localhost:8551 --jwt-secret=/home/ethereum/jwt.hex --checkpoint-sync-url=https://sync-mainnet.beaconcha.in --genesis-beacon-api-url=https://sync-mainnet.beaconcha.in

[Install]
WantedBy=default.target
FINISH

systemctl daemon-reload
systemctl enable prysm.service
systemctl daemon-reload

service prysm start


###############################
# Install Healthcheck service #
###############################

eth_static_data_bucket=${eth_static_data_bucket}
health_check_package=${health_check_package}

private_ip=$(ec2metadata --local-ipv4)
aws s3 cp "s3://$eth_static_data_bucket/$health_check_package" /home/ethereum/
unzip "/home/ethereum/$health_check_package" -d /home/ethereum/
rm -f /home/ethereum/eth-node-lb-healthcheck-master.zip
sed -i "s/TH_RPC_HOST=127.0.0.1/TH_RPC_HOST=$private_ip/g" /home/ethereum/eth-node-lb-healthcheck-master/.env
cd /home/ethereum/eth-node-lb-healthcheck-master/ || exit
npm audit fix
npm install
chown ethereum:ethereum -R /home/ethereum/eth-node-lb-healthcheck-master

cat << FINISH > /etc/systemd/system/eth-healthcheck.service
[Unit]
Description=Healthcheck for Ethereum nodes

[Service]
Type=simple
User=ethereum
Restart=always
RestartSec=12
ExecStart=node /home/ethereum/eth-node-lb-healthcheck-master/index.js

[Install]
WantedBy=default.target
FINISH

systemctl daemon-reload
systemctl enable eth-healthcheck.service

service eth-healthcheck start