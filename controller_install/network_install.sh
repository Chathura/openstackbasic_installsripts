#!/bin/sh

# THIS SCRIPT IS NOT COMPLETE YET
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
# 4 Change IP to the controller's mange network's IP in the following 
#   variables in the following files.
#
#   network/l3_agent.ini:
#   auth_url
#   metadata_ip
#
#   network/api-paste.ini:
#   auth_host
#
#   network/quantum.conf:
#   rabbit_host
#
#   network/ovs_quantum_plugin.ini
#   sql_connection
#   
# 5.Then the following variable's IP address to the network nodes data network
#   address.
#
#   network/ovs_quantum_plugin.ini
#   local_ip
#   
# 6. Alter the global variables in this script.
#
# Chathura M. Sarathchandra Magurawalage
# email: csarata@essex.ac.uk
#        77.chathura@gmail.com

((

##############################################################################
#Controller IP data network.
CONTROLLER_IP_INT=10.10.10.1

# Controller IP management network.
CONTROLLER_IP_EXT=192.168.2.225

# Network node IP management network.
NETWORKNODE_IP_EXT=192.168.2.153

# Network node IP data network.
#NETWORKNODE_IP_INT=10.10.10.2

EXT_NET_ID=1214322154655646556352658
ROUTER_ID=6546655656565656565656586
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

while getopts i:e:n:t:s:r:hv option
do 
    case "${option}"
    in
        i) CONTROLLER_IP_INT=${OPTARG};;
	e) CONTROLLER_IP_EXT=${OPTARG};;
	n) NETWORKNODE_IP_EXT=${OPTARG};;
#	t) NETWORKNODE_IP_INT=${OPTARG};;
	s) EXT_NET_ID=${OPTARG};;
	r) ROUTER_ID=${OPTARG};;
	v) set -x;;
        h) cat <<EOF 
Usage: $0 [-i controller_ip_internal] [-e controller_ip_external] [-i networknode_ip_internal] [-e networknode_ip_external]
          [-s external_network_id] [-r router_id]
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
        address $NETWORKNODE_IP_EXT
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
echo "net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf

service networking restart

#install and configure NTP
apt-get install -y ntp rsplib-tools

echo "server $CONTROLLER_IP_INT" >> /etc/ntp.conf

#Restart ntp
service ntp restart

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

echo "export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=password
export OS_AUTH_URL=\"http://$CONTROLLER_IP_EXT:5000/v2.0/\"
export SERVICE_ENDPOINT=\"http://$CONTROLLER_IP_EXT:35357/v2.0\"
export SERVICE_TOKEN=password" > ~/novarc

source novarc
echo "source novarc">> ~/.bashrc

./network/quantum-networking.sh

# Copy the external network ID
#EXT_NET_ID=$(get_id quantum net-show $EXT_NET_NAME)

sed -i -e '/gateway_external_network_id =/ s/= .*/= $EXT_NET_ID/' /etc/quantum/l3_agent.ini 

# Copy the provider router ID
#ROUTER_ID=$(get_id quantum router-show $PROV_ROUTER_NAME)

sed -i -e '/router_id =/ s/= .*/= $ROUTER_ID/' /etc/quantum/l3_agent.ini

# Restart L3 Agent :
service quantum-l3-agent restart

echo "Controller node has been successfully configured"

)) 2>&1 | tee $0.log
