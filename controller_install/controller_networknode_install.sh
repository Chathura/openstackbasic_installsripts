#!/bin/sh

#
# This script installs the Openstack Controller node and the Network Node on 
# one server.
#
# BEFORE RUN THIS SCRIPT, YOU NEED TO DO THE FOLLOWINGS.
#
# 1. Setup the interfaces of the server first.
# 2. Need more than one disk attached to the server. Then add the disk to 
# cinder-volumes volume group.
#
# Create the volume [May differ according to your disk]
#     fdisk /dev/sdb
#     pvcreate /dev/sdb1
#     vgcreate cinder-volumes /dev/sdb1
# 
# 3. Set permissions in the database for other compute nodes.
#    
#    Use "add_computenode.sh" script.    
#
# Chathura M. Sarathchandra Magurawalage
# email: csarata@essex.ac.uk
#        77.chathura@gmail.com

((

#Controller IP
CONTROLLER_IP_INT=10.10.10.1
CONTROLLER_IP_EXT=192.168.2.225

##################DO NOT ALTER#################################################
#Provider router name
PROV_ROUTER_NAME="provider-router"

# Name of External Network 
EXT_NET_NAME="ext_net"
###############################################################################

# Function to get ID
get_id () {
        echo `$@ | awk '/ id / { print $4 }'`
}

#Check for root permissions
 $(/usr/bin/id -u) -ne 0 ]]; then
    echo "Not running as root: Need root permissions"
    exit
fi

while getopts i:e:hv option
do 
    case "${option}"
    in
        i) CONTROLLER_IP_INT=${OPTARG};;
	e) CONTROLLER_IP_EXT=${OPTARG};;
	v) set -x;;
        h) cat <<EOF 
Usage: $0 [-i controller_ip_internal] [-e controller_ip_external]

Add -v for verbose mode, -h to display this message.
EOF
exit 0
;;
	\?) echo "Use -h for help"
	    exit 1;;
    esac
done

#Ubuntu 12.04 LTS, use cloud archives for Folsom.

apt-get install ubuntu-cloud-keyring

echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/folsom main " >> /etc/apt/sources.list.d/cloud-archive.list

apt-get update && apt-get -y upgrade

#Setup interfaces [Edit this configuration accordingly]

echo "
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet static
        address $CONTROLLER_IP_INT
        netmask 255.255.255.0
        network 10.10.10.0
        broadcast 10.10.10.255

# Enable eth0.2
auto eth0.2
iface eth0.2 inet dhcp

# Enable eth0.10
#auto eth0.10
#iface eth0.10 inet manual
#     up ifconfig eth0.10 up

#Public bridge for the VMs
auto br0
iface br0 inet manual
up ifconfig $IFACE 0.0.0.0 up
up ip link set $IFACE promisc on
down ifconfig $IFACE down" > /etc/network/interfaces

#edit /etc/sysctl.conf file
echo "net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf

service networking restart

#install and configure NTP
apt-get install -y ntp rsplib-tools

#configure /etc/ntp.conf [needs modifying]
echo "server 127.127.1.0
fudge 127.127.1.0 stratum 10" >> /etc/ntp.conf

#Restart ntp
service ntp restart

#Install mysql database service.
apt-get install mysql-server python-mysqldb

#Allow connection from the network
sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf

#restart the service
service mysql restart

#Create database, users, rights
mysql -u root -ppassword <<EOF
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' \
IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'$CONTROLLER_IP_EXT' \
IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'$CONTROLLER_IP_EXT' \
IDENTIFIED BY 'password';
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' \
IDENTIFIED BY 'password';
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' \
IDENTIFIED BY 'password';
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' \
IDENTIFIED BY 'password';
CREATE DATABASE quantum;
GRANT ALL PRIVILEGES ON quantum.* TO 'quantum'@'localhost' \
IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON quantum.* TO 'quantum'@'$CONTROLLER_IP_EXT' \
IDENTIFIED BY 'password';
FLUSH PRIVILEGES;
EOF

#[RabbitMQ]
#Install RabbitMQ
apt-get install -y rabbitmq-server

#Change the default password of guest to 'password'
rabbitmqctl change_password guest password

#[Keystore]
#Install Keystone
apt-get install keystone -y python-keystone python-keystoneclient

# edit /etc/keystone/keystone.conf
cp ./keystone/keystone.conf /etc/keystone/

#Restart Keystone and create the tables in the database :
service keystone restart
keystone-manage db_sync

#Load environment variables

 #create novarc file
echo "export OS_TENANT_NAME=demo
export OS_USERNAME=admin
export OS_PASSWORD=password
export OS_AUTH_URL=\"http://localhost:5000/v2.0/\"
export SERVICE_ENDPOINT=\"http://localhost:35357/v2.0\"
export SERVICE_TOKEN=password" > ~/novarc

  #export variables

source novarc
echo "source novarc" >> .bashrc

# Fill keystone database
./keystone/keystone-data.sh

./keystone/keystone-endpoints.sh -K $CONTROLLER_IP_EXT

#[Glance]
#Install Glance

apt-get install -y glance glance-api python-glanceclient glance-common

#Copy glance configuration files
cp ./glance/glance-api.conf /etc/glance/
cp ./glance/glance-registry.conf /etc/glance/

#Restart Glance services
service glance-api restart && service glance-registry restart

#Create glance tables into the database
glance-manage db_sync

#Download and import Ubuntu 12.04 LTS UEC Image
glance image-create \
--location http://uec-images.ubuntu.com/releases/12.04/release/ubuntu-12.04-server-cloudimg-amd64-disk1.img \
--is-public true --disk-format qcow2 --container-format bare --name "Ubuntu"

#Show image in the index
glance image-list


#[Nova]
#Install Nova
apt-get -y install nova-api nova-cert nova-common \
    nova-scheduler python-nova python-novaclient nova-consoleauth novnc \
    nova-novncproxy

#Copy nova configuration files
cp ./nova/api-paste.ini /etc/nova/api-paste.ini
cp ./nova/nova.conf /etc/nova/nova.conf

#Create nova tables into the database
nova-manage db sync

#Restart Nova services
service nova-api restart
service nova-cert restart
service nova-consoleauth restart
service nova-scheduler restart
service nova-novncproxy restart

#[Cinder]

#Install cinder
apt-get install -y cinder-api cinder-scheduler cinder-volume iscsitarget \
    open-iscsi iscsitarget-dkms python-cinderclient linux-headers-`uname -r`

#Copy tgt configuration file
cp ./cinder/targets.conf /etc/tgt/

#Configure and start the iSCSI services
sed -i 's/false/true/g' /etc/default/iscsitarget
service iscsitarget restart
service open-iscsi restart

#Copy configuration files
cp ./cinder/cinder.conf /etc/cinder/
cp ./cinder/api-paste.ini /etc/cinder/

#Create the volume [May differ according to your disk]
#fdisk /dev/sdb
#pvcreate /dev/sdb1
#vgcreate cinder-volumes /dev/sdb1

#Create cinder tables into the database
cinder-manage db sync

service cinder-api restart
service cinder-scheduler restart
service cinder-volume restart

#[Quantum]

#install quantum
apt-get -y install quantum-server

#copy quantum config files
cp ./quantum/quantum.conf /etc/quantum/quantum.conf
cp ./quantum/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

#start service
service quantum-server restart

#[Dashboard (Horizon)]

#Install dashboard
apt-get install -y apache2 libapache2-mod-wsgi openstack-dashboard \
    memcached python-memcache

#[Network node installation]
cp ./network/sysctl.conf /etc/sysctl.conf

#Install open-vswitch
apt-get install quantum-plugin-openvswitch-agent \
quantum-dhcp-agent quantum-l3-agent

service openvswitch-switch start

ovs-vsctl add-br br-int
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex br0
ip link set up br-ex

# quantum

#Configure quantum services

cp ./network/l3_agent.ini /etc/quantum/l3_agent.ini
cp ./network/api-paste.ini /etc/quantum/api-paste.ini
cp ./network/quantum.conf /etc/quantum/quantum.conf
cp ./network/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
cp ./network/dhcp_agent.ini /etc/quantum/dhcp_agent.ini

service quantum-plugin-openvswitch-agent start
service quantum-dhcp-agent restart
service quantum-l3-agent restart

./network/quantum-networking.sh

# Copy the external network ID
EXT_NET_ID=$(get_id quantum net-show $EXT_NET_NAME)

sed -i -e '/gateway_external_network_id =/ s/= .*/= $EXT_NET_ID/' /etc/quantum/l3_agent.ini 

# Copy the provider router ID
ROUTER_ID=$(get_id quantum router-show $PROV_ROUTER_NAME)

sed -i -e '/router_id =/ s/= .*/= $ROUTER_ID/' /etc/quantum/l3_agent.ini

# Restart L3 Agent :
service quantum-l3-agent restart

echo "Controller & Network node has been successfully configured"

)) 2>&1 | tee $0.log
