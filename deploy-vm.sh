#!/bin/bash
# =============================================================================
# IoT Operations Quickstart - Step 1: VM Deployment
# =============================================================================
# This script provisions an Azure VM and Arc-enables it so it can host a
# Kubernetes cluster for Azure IoT Operations. It performs the following:
#   1. Registers required Azure resource providers for IoT Operations.
#   2. Creates a resource group, NSG, VNet, and Ubuntu 24.04 VM.
#   3. Arc-enables the VM using the Azure Connected Machine agent.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login).
#   - WSL if running from Windows.
#   - Edit config.sh with your desired settings before running.
#
# Usage: bash deploy-vm.sh
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

# Ensure sshpass is installed on the local machine. sshpass is used to
# automate SSH commands to the VM using password-based authentication.
if ! command -v sshpass &>/dev/null; then
    echo "Installing sshpass..."
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
fi

echo "================================================="
echo "IoT Operations Quickstart - VM Deployment"
echo "================================================="
echo "Resource Group: $resourceGroup"
echo "Location:       $location"
echo "VM Name:        $vmName"
echo "VM Size:        $vmsize"
echo "================================================="

# Allow Azure CLI to install extensions on-the-fly without prompting.
az config set extension.use_dynamic_install=yes_without_prompt

# Register the Azure resource providers needed by IoT Operations and Arc.
# Each provider is checked first to avoid unnecessary re-registration.
echo "Checking resource providers..."
providers=(
    'Microsoft.HybridCompute'
    'Microsoft.GuestConfiguration'
    'Microsoft.HybridConnectivity'
    'Microsoft.Kubernetes'
    'Microsoft.KubernetesConfiguration'
    'Microsoft.ExtendedLocation'
    'Microsoft.IoTOperations'
    'Microsoft.DeviceRegistry'
    'Microsoft.SecretSyncController'
)

for provider in "${providers[@]}"; do
    state=$(az provider show --namespace "$provider" --query "registrationState" --output tsv 2>/dev/null | tr -d '[:space:]')
    if [ "$state" == "Registered" ]; then
        echo "  $provider already registered."
    else
        echo "  Registering $provider..."
        az provider register --namespace "$provider" --wait
    fi
done

# Create resource group.
echo "Creating resource group $resourceGroup..."
az group create --name "$resourceGroup" --location "$location"

# Create a Network Security Group (NSG) to control inbound/outbound traffic.
echo "Creating network security group..."
az network nsg create \
    --resource-group "$resourceGroup" \
    --name "$nsgName" \
    --location "$location"

# Detect the caller's public IP address and create an NSG rule that allows
# SSH (port 22) only from that IP. This restricts access to the deployer.
callerIp=$(curl -s https://api.ipify.org)
echo "Allowing SSH from $callerIp..."
az network nsg rule create \
    --resource-group "$resourceGroup" \
    --nsg-name "$nsgName" \
    --name AllowSSH \
    --priority 100 \
    --direction Inbound \
    --access Allow \
    --protocol TCP \
    --destination-port-ranges 22 \
    --source-address-prefixes "$callerIp"

# Allow MQTT (port 1883) inbound from the deployer's IP for testing the
# IoT Operations MQTT broker LoadBalancer listener.
echo "Allowing MQTT from $callerIp..."
az network nsg rule create \
    --resource-group "$resourceGroup" \
    --nsg-name "$nsgName" \
    --name AllowMQTT \
    --priority 110 \
    --direction Inbound \
    --access Allow \
    --protocol TCP \
    --destination-port-ranges 1883 \
    --source-address-prefixes "$callerIp"

# Allow K3s API server (port 6443) inbound from the deployer's IP so
# kubectl can be used from the local machine against the remote cluster.
echo "Allowing K3s API (6443) from $callerIp..."
az network nsg rule create \
    --resource-group "$resourceGroup" \
    --nsg-name "$nsgName" \
    --name AllowK3sAPI \
    --priority 120 \
    --direction Inbound \
    --access Allow \
    --protocol TCP \
    --destination-port-ranges 6443 \
    --source-address-prefixes "$callerIp"

# Create a virtual network and default subnet, associated with the NSG.
echo "Creating virtual network and subnet..."
az network vnet create \
    --resource-group "$resourceGroup" \
    --name "$vnetName" \
    --address-prefix "$vnetAddressPrefix" \
    --subnet-name "$subnetName" \
    --subnet-prefix "$subnetPrefix" \
    --network-security-group "$nsgName"

# Create the Ubuntu 24.04 VM. Uses password authentication. The NSG is set
# to empty string because the subnet already has the NSG associated.
if az vm show --resource-group "$resourceGroup" --name "$vmName" &>/dev/null; then
    echo "VM $vmName already exists. Skipping creation."
else
    echo "Creating Ubuntu 24.04 VM..."
    az vm create \
        --resource-group "$resourceGroup" \
        --name "$vmName" \
        --image "$ubuntuimage" \
        --admin-username "$user" \
        --admin-password "$password" \
        --authentication-type password \
        --size "$vmsize" \
        --vnet-name "$vnetName" \
        --subnet "$subnetName" \
        --nsg "" \
        --public-ip-sku Standard
fi

# ---------------------------------------------------------------------------
# Arc-enable the VM.
# Since this is an Azure VM (not on-premises), extra steps are required to
# make it behave like an Arc-enabled server:
#   - Disable the Azure VM Guest Agent (walinuxagent) to prevent conflicts.
#   - Set MSFT_ARC_TEST=true to allow Arc agent on Azure VMs.
#   - Block IMDS (169.254.169.254) via firewall so Arc agent doesn't detect
#     it as an Azure VM.
# Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
# ---------------------------------------------------------------------------
tenantId=$(az account show --query tenantId --output tsv | tr -d '[:space:]')
subscriptionId=$(az account show --query id --output tsv | tr -d '[:space:]')

if az connectedmachine show --resource-group "$resourceGroup" --name "$vmName" &>/dev/null; then
    echo "VM $vmName is already Arc-enabled. Skipping onboarding."
else
    echo "Configuring VM and Arc-enabling $vmName..."

    # Get the public IP.
    publicIp=$(az vm show \
        --resource-group "$resourceGroup" \
        --name "$vmName" \
        --show-details \
        --query publicIps \
        --output tsv | tr -d '[:space:]')

    # Generate an access token from the local Azure CLI session. This token
    # is passed to the VM so the Connected Machine agent can register with
    # Azure without needing a separate interactive login.
    accessToken=$(az account get-access-token --query accessToken --output tsv | tr -d '[:space:]')

    # Build the SSH command prefix used for all remote operations on the VM.
    SSH_CMD="sshpass -p $password ssh -o StrictHostKeyChecking=no $user@$publicIp"

    echo "Setting hostname..."
    $SSH_CMD "sudo hostnamectl set-hostname $vmName"

    echo "Disabling Azure VM Guest Agent..."
    $SSH_CMD "sudo systemctl stop walinuxagent"
    $SSH_CMD "sudo systemctl disable walinuxagent"

    echo "Setting MSFT_ARC_TEST environment variable..."
    $SSH_CMD "echo MSFT_ARC_TEST=true | sudo tee -a /etc/environment > /dev/null"

    # Block access to the Azure Instance Metadata Service (IMDS) endpoint.
    # This prevents the Arc agent from detecting it's on an Azure VM, which
    # is required for Arc-enabling Azure VMs for testing.
    echo "Configuring firewall to block IMDS..."
    $SSH_CMD "sudo ufw default allow incoming"
    $SSH_CMD "sudo ufw default allow outgoing"
    $SSH_CMD "sudo ufw deny out from any to 169.254.169.254"
    $SSH_CMD "sudo ufw --force enable"

    echo "Installing Azure Connected Machine agent..."
    $SSH_CMD "wget -q https://aka.ms/azcmagent -O /tmp/install_linux_azcmagent.sh"
    $SSH_CMD "sudo bash /tmp/install_linux_azcmagent.sh"

    echo "Connecting to Azure Arc..."
    $SSH_CMD "sudo MSFT_ARC_TEST=true azcmagent connect --resource-group $resourceGroup --tenant-id $tenantId --location $location --subscription-id $subscriptionId --access-token $accessToken --resource-name $vmName"

    echo "Waiting for Arc connection to stabilize..."
    sleep 15

    # Verify Arc onboarding succeeded.
    if az connectedmachine show --resource-group "$resourceGroup" --name "$vmName" &>/dev/null; then
        arcStatus=$(az connectedmachine show --resource-group "$resourceGroup" --name "$vmName" --query "status" --output tsv)
        echo "Arc onboarding succeeded. Status: $arcStatus"
    else
        echo "ERROR: Arc onboarding failed. VM $vmName is not registered as an Arc resource."
        exit 1
    fi
fi

publicIp=$(az vm show \
    --resource-group "$resourceGroup" \
    --name "$vmName" \
    --show-details \
    --query publicIps \
    --output tsv | tr -d '[:space:]')

echo ""
echo "================================================="
echo "Deployment Complete!"
echo "================================================="
echo "Resource Group: $resourceGroup"
echo "VM Name:        $vmName"
echo "Public IP:      $publicIp"
echo "Username:       $user"
echo "Arc Resource:   $vmName"
echo "================================================="
