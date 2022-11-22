#!/bin/bash

############################
# Update instance packages #
############################

add-apt-repository -y ppa:ethereum/ethereum
apt-get update -y && apt-get upgrade -y && apt-get install -y \
    ethereum \
    awscli \
    xfsprogs \
    nvme-cli \
    jq \
    curl

##########################
# Creating user ethereum #
##########################

useradd -m ethereum
usermod -a -G ethereum ethereum

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
mkdir "$chain_data_path"
chown ethereum:ethereum "$chain_data_path" 

#########################
# Creating Geth service #
#########################

private_ip=$(ec2metadata --local-ipv4)

cat << FINISH > /etc/systemd/system/geth.service
[Unit]
Description=Geth

[Service]
Type=simple
User=ethereum
Restart=always
RestartSec=12
ExecStart=/usr/bin/geth --datadir "$chain_data_path" --mainnet --syncmode "snap" --authrpc.addr localhost --authrpc.port 8551 --authrpc.vhosts localhost --authrpc.jwtsecret /home/ethereum/jwt.hex --http --http.api eth,net,engine,admin --http.addr $private_ip --http.vhosts "*"

[Install]
WantedBy=default.target
FINISH

systemctl daemon-reload
systemctl enable geth.service
systemctl daemon-reload

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
