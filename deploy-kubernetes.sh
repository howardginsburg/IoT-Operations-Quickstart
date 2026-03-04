#!/bin/bash
# =============================================================================
# IoT Operations Quickstart - Step 2: K3s Installation & Cluster Preparation
# =============================================================================
# This script installs K3s (lightweight Kubernetes) on the VM created by
# deploy-vm.sh and prepares the cluster for Azure IoT Operations. It:
#   1. Installs Azure CLI, K3s, and Helm on the VM.
#   2. Configures kubeconfig and kernel parameters for IoT Operations.
#   3. Arc-enables the K3s cluster with OIDC issuer and workload identity.
#   4. Enables custom locations on the cluster (required by IoT Operations).
#
# Prerequisites:
#   - deploy-vm.sh must have been run successfully first.
#   - You will be prompted for device code login to authenticate the VM's
#     Azure CLI session.
#
# Usage: bash deploy-kubernetes.sh
# =============================================================================
set -e

# Strip Windows carriage returns (\r) from this script and config.sh, then
# re-execute. This allows the scripts to work even when edited on Windows.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$_CRLF_FIXED" ]; then
    export _CRLF_FIXED=1
    sed -i 's/\r$//' "$0" "$SCRIPT_DIR/config.sh" 2>/dev/null
    exec bash "$0" "$@"
fi

# Load shared configuration variables (resource names, credentials, etc.).
source "$SCRIPT_DIR/config.sh"

# Ensure sshpass is installed on the local machine for automated SSH access.
if ! command -v sshpass &>/dev/null; then
    echo "Installing sshpass..."
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
fi

echo "================================================="
echo "IoT Operations Quickstart - K3s Installation"
echo "================================================="
echo "Resource Group: $resourceGroup"
echo "VM Name:        $vmName"
echo "================================================="

# Retrieve the VM's public IP address for SSH access.
publicIp=$(az vm show \
    --resource-group "$resourceGroup" \
    --name "$vmName" \
    --show-details \
    --query publicIps \
    --output tsv | tr -d '[:space:]')

# Build the SSH command prefix used for all remote operations on the VM.
SSH_CMD="sshpass -p $password ssh -o StrictHostKeyChecking=no $user@$publicIp"
# Retrieve the active subscription ID from the local CLI session.
subscriptionId=$(az account show --query id --output tsv | tr -d '[:space:]')

# ---------------------------------------------------------------------------
# Install Azure CLI on the VM.
# The VM needs its own Azure CLI to run 'az connectedk8s connect' locally,
# since the connectedk8s extension requires direct access to the kubeconfig.
# ---------------------------------------------------------------------------
if $SSH_CMD "command -v az" &>/dev/null; then
    echo "Azure CLI already installed on VM. Skipping."
else
    echo "Installing Azure CLI on the VM..."
    $SSH_CMD "curl -sL https://aka.ms/InstallAzureCLIDeb -o /tmp/install_azcli.sh"
    $SSH_CMD "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo 'Waiting for apt lock...'; sleep 5; done"
    $SSH_CMD "sudo bash /tmp/install_azcli.sh"
fi
# Install the connectedk8s extension, needed to Arc-enable the K3s cluster.
$SSH_CMD "az extension add --upgrade --name connectedk8s -y"

# Authenticate the Azure CLI on the VM using device code flow.
# This is required because the VM's CLI session needs its own identity to
# Arc-enable the cluster. The user must open the URL shown and enter the code.
echo ""
echo "================================================="
echo "ACTION REQUIRED: Device code login needed!"
echo "Follow the instructions below to authenticate"
echo "the Azure CLI on the VM."
echo "================================================="
echo ""
$SSH_CMD "az login --use-device-code"
# Set the subscription to match the one used on the local machine.
$SSH_CMD "az account set --subscription $subscriptionId"

# ---------------------------------------------------------------------------
# Install K3s - a lightweight, certified Kubernetes distribution.
# K3s is the recommended single-node Kubernetes for IoT Operations test
# deployments. It bundles kubectl and uses /etc/rancher/k3s/k3s.yaml as
# the default kubeconfig.
# ---------------------------------------------------------------------------
if $SSH_CMD "systemctl is-active k3s" &>/dev/null; then
    echo "K3s already installed. Skipping."
else
    echo "Installing K3s..."
    $SSH_CMD "curl -sfL https://get.k3s.io -o /tmp/install_k3s.sh"
    $SSH_CMD "sudo sh /tmp/install_k3s.sh --tls-san $publicIp"
fi

# Verify kubectl is available.
echo "Verifying kubectl..."
$SSH_CMD "kubectl version --client"

# Install Helm - the Kubernetes package manager.
# Helm is used by IoT Operations extensions during deployment.
if $SSH_CMD "command -v helm" &>/dev/null; then
    echo "Helm already installed. Skipping."
else
    echo "Installing Helm..."
    $SSH_CMD "curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh"
    $SSH_CMD "bash /tmp/get_helm.sh"
fi

# Configure kubeconfig for the admin user so kubectl and helm work without
# sudo. K3s places its kubeconfig at /etc/rancher/k3s/k3s.yaml by default;
# we copy it to ~/.kube/config with proper ownership and permissions.
echo "Configuring kubeconfig..."
$SSH_CMD "mkdir -p ~/.kube"
$SSH_CMD "sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
$SSH_CMD "sudo chown \$(id -u):\$(id -g) ~/.kube/config"
$SSH_CMD "chmod 0600 ~/.kube/config"
$SSH_CMD "grep -q 'KUBECONFIG' ~/.bashrc || echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc"
$SSH_CMD "export KUBECONFIG=~/.kube/config && kubectl config use-context default"
$SSH_CMD "sudo chmod 644 /etc/rancher/k3s/k3s.yaml"

# ---------------------------------------------------------------------------
# Kernel parameter tuning for IoT Operations.
# IoT Operations components use many inotify watches and file descriptors.
# Without these increases, pods may fail to start or watch for config changes.
# ---------------------------------------------------------------------------
echo "Increasing inotify limits..."
$SSH_CMD "grep -q 'fs.inotify.max_user_instances' /etc/sysctl.conf || echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf"
$SSH_CMD "grep -q 'fs.inotify.max_user_watches' /etc/sysctl.conf || echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf"

echo "Increasing file descriptor limit..."
$SSH_CMD "grep -q 'fs.file-max' /etc/sysctl.conf || echo fs.file-max = 100000 | sudo tee -a /etc/sysctl.conf"

# Apply the sysctl parameter changes immediately.
$SSH_CMD "sudo sysctl -p"

# ---------------------------------------------------------------------------
# Arc-enable the K3s cluster.
# This registers the K3s cluster with Azure Arc so it can be managed from
# the Azure portal and receive IoT Operations extensions. Key flags:
#   --enable-oidc-issuer:     Required for workload identity federation.
#   --enable-workload-identity: Allows pods to authenticate with Azure AD.
#   --disable-auto-upgrade:   Prevents unexpected agent upgrades.
# ---------------------------------------------------------------------------
echo "Arc-enabling the K3s cluster..."
clusterName="${vmName}-cluster"

if az connectedk8s show --name "$clusterName" --resource-group "$resourceGroup" &>/dev/null; then
    echo "Cluster $clusterName already Arc-enabled. Skipping."
else
    $SSH_CMD "export KUBECONFIG=~/.kube/config && az connectedk8s connect \
        --name $clusterName \
        --location $location \
        --resource-group $resourceGroup \
        --subscription $subscriptionId \
        --enable-oidc-issuer \
        --enable-workload-identity \
        --disable-auto-upgrade"
fi

# ---------------------------------------------------------------------------
# Configure the K3s API server to use the Arc OIDC issuer.
# This allows Kubernetes service account tokens to be validated by Azure AD,
# which is required for workload identity to function. The 24h max token
# expiration is the recommended setting for IoT Operations.
# ---------------------------------------------------------------------------
echo "Configuring K3s service account issuer..."
issuerUrl=$($SSH_CMD "az connectedk8s show \
    --resource-group $resourceGroup \
    --name $clusterName \
    --query oidcIssuerProfile.issuerUrl \
    --output tsv" | tr -d '[:space:]')

$SSH_CMD "sudo mkdir -p /etc/rancher/k3s"
$SSH_CMD "sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
tls-san:
 - $publicIp
kube-apiserver-arg:
 - service-account-issuer=$issuerUrl
 - service-account-max-token-expiration=24h
EOF"

# ---------------------------------------------------------------------------
# Enable custom locations on the Arc cluster.
# Custom locations allow Azure IoT Operations to project resources into the
# cluster's namespace. The object ID is the well-known service principal for
# the Custom Locations RP (bc313c14-388c-4e7d-a58e-70017303ee3b).
# ---------------------------------------------------------------------------
echo "Enabling custom locations..."
OBJECT_ID=$($SSH_CMD "az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv" | tr -d '[:space:]')

$SSH_CMD "export KUBECONFIG=~/.kube/config && az connectedk8s enable-features \
    -n $clusterName \
    -g $resourceGroup \
    --custom-locations-oid $OBJECT_ID \
    --features cluster-connect custom-locations"

# Delete existing serving certificates so K3s regenerates them with the
# updated TLS SANs (including the VM's public IP) on restart.
echo "Removing old K3s serving certificates..."
$SSH_CMD "sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key"

# Restart K3s to pick up the service account issuer and TLS SAN changes.
echo "Restarting K3s..."
$SSH_CMD "sudo systemctl restart k3s"

# Wait for K3s to fully restart before continuing.
echo "Waiting for K3s to stabilize..."
sleep 15

# Re-apply kubeconfig permissions. K3s overwrites k3s.yaml on restart,
# resetting ownership and permissions back to root-only.
$SSH_CMD "sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
$SSH_CMD "sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
$SSH_CMD "sudo chown \$(id -u):\$(id -g) ~/.kube/config"
$SSH_CMD "chmod 0600 ~/.kube/config"

# Verify the cluster is ready.
echo "Verifying cluster status..."
$SSH_CMD "kubectl get nodes"

# ---------------------------------------------------------------------------
# Copy the kubeconfig to the local machine.
# This allows running kubectl commands locally against the remote K3s cluster.
# The server address is updated from 127.0.0.1 to the VM's public IP so the
# local kubectl can reach the API server over the network.
# ---------------------------------------------------------------------------
echo "Copying kubeconfig to local machine..."
mkdir -p ~/.kube
SCP_CMD="sshpass -p $password scp -o StrictHostKeyChecking=no"
$SCP_CMD "$user@$publicIp:~/.kube/config" ~/.kube/config
# Replace the loopback address with the VM's public IP in the local kubeconfig.
sed -i "s|https://127.0.0.1:6443|https://$publicIp:6443|g" ~/.kube/config

echo "Verifying local kubectl access..."
kubectl get nodes

echo ""
echo "================================================="
echo "K3s Installation Complete!"
echo "================================================="
echo "Cluster Name:   $clusterName"
echo "VM Name:        $vmName"
echo "OIDC Issuer:    $issuerUrl"
echo "Local kubectl:  configured (~/.kube/config)"
echo "================================================="
