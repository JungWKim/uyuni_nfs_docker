#---------------
# 1. run without sudo
# 2. you need nfs-server for uyuni-infra
#---------------

#!/bin/bash

LOCAL_FILE_COPY=no
IP=
NFS_IP=
# if asustor is nfs server, nfs_path will be like, "/volume1/****"
NFS_PATH=/kube_storage
PV_SIZE=
DOCKER_USER=
DOCKER_PW=

cd ~

# prevent auto upgrade
sudo sed -i 's/1/0/g' /etc/apt/apt.conf.d/20auto-upgrades

if [ -e /etc/needrestart/needrestart.conf ] ; then
	# disable outdated librareis pop up
	sudo sed -i "s/\#\$nrconf{restart} = 'i'/\$nrconf{restart} = 'a'/g" /etc/needrestart/needrestart.conf
	# disable kernel upgrade hint pop up
	sudo sed -i "s/\#\$nrconf{kernelhints} = -1/\$nrconf{kernelhints} = 0/g" /etc/needrestart/needrestart.conf 
fi

# install nvidia driver
sudo apt update
sudo apt install -y build-essential
sudo apt install -y linux-headers-generic
sudo apt install -y dkms

cat << EOF | sudo tee -a /etc/modprobe.d/blacklist.conf 
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF

echo options nouveau modeset=0 | sudo tee -a /etc/modprobe.d/nouveau-kms.conf
sudo update-initramfs -u

sudo rmmod nouveau

if [ ${LOCAL_FILE_COPY} == "yes" ] ; then
	scp root@192.168.1.59:/root/files/NVIDIA-Linux-x86_64-525.89.02.run .
else
        wget https://kr.download.nvidia.com/XFree86/Linux-x86_64/525.89.02/NVIDIA-Linux-x86_64-525.89.02.run
fi

sudo sh ~/NVIDIA-Linux-x86_64-525.89.02.run

nvidia-smi
nvidia-smi -L

# disable firewall
sudo systemctl stop ufw
sudo systemctl disable ufw

# install basic packages
sudo apt install -y net-tools nfs-common whois

# network configuration
sudo modprobe overlay \
    && sudo modprobe br_netfilter

cat <<EOF | sudo tee -a /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee -a /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

# install docker
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# login docker account
sudo docker login -u ${DOCKER_USER} --password-stdin ${DOCKER_PW}

# ssh configuration
ssh-keygen -t rsa

ssh-copy-id -i ~/.ssh/id_rsa ${USER}@${IP}

# k8s installation via kubespray
sudo apt install -y python3-pip
git clone -b release-2.19 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
pip install -r requirements.txt

echo "export PATH=${HOME}/.local/bin:${PATH}" | sudo tee ${HOME}/.bashrc > /dev/null
source ${HOME}/.bashrc

cp -rfp inventory/sample inventory/mycluster
declare -a IPS=(${IP})
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}

sed -i "s/docker_version: '20.10'/docker_version: 'latest'/g" roles/container-engine/docker/defaults/main.yml
sed -i "s/container_manager: containerd/container_manager: docker/g" inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
sed -i "s/docker_containerd_version: 1.4.12/docker_containerd_version: latest/g" roles/download/defaults/main.yml
sed -i "s/host_architecture }}]/host_architecture }} signed-by=\/etc\/apt\/keyrings\/docker.gpg]/g" roles/container-engine/docker/vars/ubuntu.yml
sed -i "s/# docker_cgroup_driver: systemd/docker_cgroup_driver: systemd/g" inventory/mycluster/group_vars/all/docker.yml

# automatically disable swap partition
ansible-playbook -i inventory/mycluster/hosts.yaml  --become --become-user=root cluster.yml -K
cd ~

# enable kubectl in admin account and root
mkdir -p ${HOME}/.kube
sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
sudo chown ${USER}:${USER} ${HOME}/.kube/config

# enable kubectl & kubeadm auto-completion
echo "source <(kubectl completion bash)" >> ${HOME}/.bashrc
echo "source <(kubeadm completion bash)" >> ${HOME}/.bashrc

echo "source <(kubectl completion bash)" | sudo tee -a /root/.bashrc
echo "source <(kubeadm completion bash)" | sudo tee -a /root/.bashrc

# install nvidia-container-toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
    && curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add - \
    && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update \
    && sudo apt-get install -y nvidia-container-toolkit

cat <<EOF | sudo tee /etc/docker/daemon.json
{
   "default-runtime": "nvidia",
   "runtimes": {
      "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
      }
   }
}
EOF

systemctl restart docker
sleep 180

# install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# install helmfile
wget https://github.com/helmfile/helmfile/releases/download/v0.150.0/helmfile_0.150.0_linux_amd64.tar.gz
tar -zxvf helmfile_0.150.0_linux_amd64.tar.gz
sudo mv helmfile /usr/bin/
rm LICENSE && rm README.md && rm helmfile_0.150.0_linux_amd64.tar.gz

# deploy uyuni infra - this process consumes 33G.
git clone -b develop https://github.com/xiilab/Uyuni_Deploy.git
cd ~/Uyuni_Deploy

sed -i "s/192.168.56.13/${NFS_IP}/g" environments/default/values.yaml
sed -i "s:/kube_storage:${NFS_PATH}:g" environments/default/values.yaml
sed -i "s/192.168.56.11/${IP}/g" environments/default/values.yaml
cp ~/.kube/config applications/uyuni-suite/uyuni-suite/config
sed -i "s/127.0.0.1/${IP}/g" applications/uyuni-suite/uyuni-suite/config
sed -i "s/5/${PV_SIZE}/g" applications/uyuni-suite/values.yaml.gotmpl
helm repo add bitnami https://charts.bitnami.com/bitnami
helmfile --environment default -l type=base sync
helmfile --environment default -l type=app sync
cd ~
