#!/bin/bash
set -e

# Strip Windows carriage returns from script files and re-exec once.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$_CRLF_FIXED" ]; then
    export _CRLF_FIXED=1
    sed -i 's/\r$//' "$0" "$SCRIPT_DIR/config.sh" 2>/dev/null
    exec bash "$0" "$@"
fi

# Load configuration.
source "$SCRIPT_DIR/config.sh"

# Ensure sshpass is installed.
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

# Enable dynamic extension install.
az config set extension.use_dynamic_install=yes_without_prompt

# Register required resource providers (skip if already registered).
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

# Create NSG.
echo "Creating network security group..."
az network nsg create \
    --resource-group "$resourceGroup" \
    --name "$nsgName" \
    --location "$location"

# Get the caller's public IP and create an NSG rule to allow SSH.
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

# Create VNet and subnet.
echo "Creating virtual network and subnet..."
az network vnet create \
    --resource-group "$resourceGroup" \
    --name "$vnetName" \
    --address-prefix "$vnetAddressPrefix" \
    --subnet-name "$subnetName" \
    --subnet-prefix "$subnetPrefix" \
    --network-security-group "$nsgName"

# Create the Ubuntu VM if it doesn't already exist.
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

# Arc-enable the VM if not already connected.
# Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
subscriptionId=$(az account show --query id --output tsv | tr -d '[:space:]')
tenantId=$(az account show --query tenantId --output tsv | tr -d '[:space:]')

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

    # Generate an access token for the Connected Machine agent.
    accessToken=$(az account get-access-token --query accessToken --output tsv)

    # SSH into VM and configure for Arc.
    SSH_CMD="sshpass -p $password ssh -o StrictHostKeyChecking=no $user@$publicIp"

    echo "Setting hostname..."
    $SSH_CMD "sudo hostnamectl set-hostname $vmName"

    echo "Disabling Azure VM Guest Agent..."
    $SSH_CMD "sudo systemctl stop walinuxagent"
    $SSH_CMD "sudo systemctl disable walinuxagent"

    echo "Setting MSFT_ARC_TEST environment variable..."
    $SSH_CMD "echo MSFT_ARC_TEST=true | sudo tee -a /etc/environment > /dev/null"

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
