#---------------
# 1. run without sudo
# 2. you need nfs-server for uyuni-infra
#---------------

#!/bin/bash

IP=
NFS_IP=
# if asustor is nfs server, nfs_path will be like, "/volume1/****"
NFS_PATH=/kube_storage
PV_SIZE=

cd ~

# disable firewall
sudo systemctl stop ufw
sudo systemctl disable ufw

# install basic packages
sudo apt update
sudo apt install -y nfs-common whois

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

# nvidia-container-toolkit configuration
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

sudo systemctl restart docker
sleep 30

# ssh configuration
ssh-keygen -t rsa
ssh-copy-id -i ~/.ssh/id_rsa ${USER}@${IP}

# k8s installation via kubespray
sudo apt install -y python3-pip
git clone -b release-2.20 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
pip install -r requirements.txt

echo "export PATH=${HOME}/.local/bin:${PATH}" | sudo tee ${HOME}/.bashrc > /dev/null
source ${HOME}/.bashrc

cp -rfp inventory/sample inventory/mycluster
declare -a IPS=(${IP})
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}

sed -i "s/docker_version: '20.10'/docker_version: 'latest'/g" roles/container-engine/docker/defaults/main.yml
sed -i "s/docker_containerd_version: 1.6.4/docker_containerd_version: latest/g" roles/download/defaults/main.yml
sed -i "s/container_manager: containerd/container_manager: docker/g" inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
sed -i "s/container_manager: containerd/container_manager: docker/g" roles/kubespray-defaults/defaults/main.yaml
sed -i "s/# container_manager: containerd/container_manager: docker/g" inventory/mycluster/group_vars/all/etcd.yml
sed -i "s/host_architecture }}]/host_architecture }} signed-by=\/etc\/apt\/keyrings\/docker.gpg]/g" roles/container-engine/docker/vars/ubuntu.yml
sed -i "s/# cri_dockerd_enabled: false/cri_dockerd_enabled: false/g" inventory/mycluster/group_vars/all/docker.yml
sed -i "s/# docker_cgroup_driver: systemd/docker_cgroup_driver: systemd/g" inventory/mycluster/group_vars/all/docker.yml
sed -i "s/etcd_deployment_type: host/etcd_deployment_type: docker/g" inventory/mycluster/group_vars/all/etcd.yml
sed -i "s/# docker_storage_options: -s overlay2/docker_storage_options: -s overlay2/g" inventory/mycluster/group_vars/all/docker.yml
sed -i "s/# docker_storage_options: -s overlay2/docker_storage_options: -s overlay2/g" roles/kubespray-defaults/defaults/main.yaml

# enable kubectl & kubeadm auto-completion
echo "source <(kubectl completion bash)" >> ${HOME}/.bashrc
echo "source <(kubeadm completion bash)" >> ${HOME}/.bashrc
echo "source <(kubectl completion bash)" | sudo tee -a /root/.bashrc
echo "source <(kubeadm completion bash)" | sudo tee -a /root/.bashrc
source ${HOME}/.bashrc

# automatically disable swap partition
ansible-playbook -i inventory/mycluster/hosts.yaml  --become --become-user=root cluster.yml -K
sleep 120
cd ~

# enable kubectl in admin account and root
mkdir -p ${HOME}/.kube
sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
sudo chown ${USER}:${USER} ${HOME}/.kube/config

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
sed -i -r -e "/env:/a\            \- name: keycloak.ssl-required\\n              value: none" applications/uyuni-suite/uyuni-suite/templates/deployment-core.yaml
helmfile --environment default -l type=base sync
helmfile --environment default -l type=app sync
cd ~
