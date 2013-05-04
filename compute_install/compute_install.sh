#!/bin/sh

# Configure the network interface before running the script
# Internet access is requred.
# Do not change the password "password" as it has been used system wide.
# To be able to get access to the databases in the controller, the compute 
# node needs explicit permissions. Hence run the add_computenode.sh script in 
# athena (controller)
#
# Chathura S. Magurawalage
# email: csarata@essex.ac.uk
#        77.chathura@gmail.com

((

#The ip of the controller (Do not change this unless the controller Ip has been changed)
CONTROLLER_IP=192.168.2.225

#The local Ip
LOCAL_IP=10.10.10.12

#Password
PASSWORD="password"

#Check for root permissions
# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root"
   exit 1
fi

while getopts l:c:p:hv option
do 
    case "${option}"
    in
        l) LOCAL_IP=${OPTARG};;
	c) CONTROLLEgR_IP=${OPTARG};;
	p) PASSWORD=${OPTARG};;
	v) set -x;;
        h) cat <<EOF 
Usage: $0 [-l local_data_ip] [-c controller_management_ip] [-p password]

Add -v for verbose mode, -h to display this message.
EOF
exit 0
;;
	\?) echo "Use -h for help"
	    exit 1;;
    esac
done


# Get archives for Openstack Folsom
apt-get install -y ubuntu-cloud-keyring

apt-key net-update
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 5EDB1B62EC4926EA

echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/folsom main " >> /etc/apt/sources.list.d/cloud-archive.list

apt-get update && apt-get -y upgrade

cp /etc/sysctl.conf /etc/sysctl.conf.backup
echo "net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf

service networking restart

echo "$CONTROLLER_IP    athena" >> /etc/hosts

#Install and configure ntp
apt-get install -y ntp

cp /etc/ntp.conf /etc/ntp.conf.backup
echo "server $CONTROLLER_IP" >> /etc/ntp.conf

service ntp restart

#[Hypervisor]
apt-get install -y libvirt-bin pm-utils qemu-kvm ubuntu-vm-builder bridge-utils

cp /etc/libvirt/qemu.conf /etc/libvirt/qemu.conf.backup
echo "cgroup_device_acl = [
    \"/dev/null\", \"/dev/full\", \"/dev/zero\",
    \"/dev/random\", \"/dev/urandom\",
    \"/dev/ptmx\", \"/dev/kvm\", \"/dev/kqemu\",
    \"/dev/rtc\", \"/dev/hpet\", \"/dev/net/tun\"]" >> /etc/libvirt/qemu.conf

#Disable KVM default virtual bridge
virsh net-destroy default
virsh net-undefine default

cp /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.backup
echo "listen_tls = 0
listen_tcp = 1
auth_tcp = \"none\"" >> /etc/libvirt/libvirtd.conf

cp /etc/init/libvirt-bin.conf /etc/init/libvirt-bin.conf.backup
sed -i -e '/env libvirtd_opts=/ s/=.*/=\"-d -l\"/' /etc/init/libvirt-bin.conf

cp /etc/default/libvirt-bin /etc/default/libvirt-bin.backup
sed -i -e '/libvirtd_opts=/ s/=.*/=\"-d -l\"/' /etc/default/libvirt-bin

service libvirt-bin restart

#[Nova]
apt-get -y install nova-compute-kvm

cp /etc/nova/api-paste.ini /etc/nova/api-paste.ini.backup
sed -i -e "/auth_host =/ s/= .*/= $CONTROLLER_IP/" /etc/nova/api-paste.ini
sed -i -e '/admin_tenant_name =/ s/= .*/= service/' /etc/nova/api-paste.ini
sed -i -e '/admin_user =/ s/= .*/= nova/' /etc/nova/api-paste.ini
sed -i -e "/admin_password =/ s/= .*/= $PASSWORD/" /etc/nova/api-paste.ini

cp /etc/nova/nova-compute.conf /etc/nova/nova-compute.conf.backup
echo "[DEFAULT]
libvirt_type=kvm
libvirt_ovs_bridge=br-int
libvirt_vif_type=ethernet
libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver
libvirt_use_virtio_for_bridges=True" > /etc/nova/nova-compute.conf

cp /etc/nova/nova.conf /etc/nova/nova.conf.backup
cp compute-node/nova.conf /etc/nova/

service nova-computer restart

#[Quantum]

#install open vswitch
apt-get install -y openvswitch-switch

service openvswitch-switch start

#configure virtual bridge

ovs-vsctl add-br br-int

#install quantum
apt-get install -y quantum-plugin-openvswitch-agent

cp /etc/quantum/quantum.conf /etc/quantum/quantum.conf.backup

echo "auth_strategy = keystone
fake_rabbit = False
rabbit_host = $CONTROLLER_IP
rabbit_password = $PASSWORD" >> /etc/quantum/quantum.conf

cp /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini.backup

cp /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini.backup
sed -i -e "/sql_connection =/ s/= .*/= mysql:\/\/quantum:$PASSWORD@$CONTROLLER_IP:3306\/quantum/" /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

cp /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini.backup
echo "tenant_network_type = gre
tunnel_id_ranges = 1:1000
integration_bridge = br-int
tunnel_bridge = br-tun
local_ip = $LOCAL_IP
enable_tunneling = True" >> /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

service quantum-plugin-openvswitch-agent restart

#Change relevent permissions
chown nova -R /var/lib/nova
usermod -a -G nova root
chgrp -R nova /var/lib/nova

)) 2>&1 | tee $0.log
