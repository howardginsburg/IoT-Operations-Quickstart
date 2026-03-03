#!/bin/bash
# =============================================================================
# IoT Operations Quickstart - Step 3: Deploy Azure IoT Operations
# =============================================================================
# This script deploys Azure IoT Operations to the Arc-enabled K3s cluster
# created by deploy-vm.sh and deploy-kubernetes.sh. It performs the following:
#   1. Installs the azure-iot-ops CLI extension.
#   2. Creates a storage account (with hierarchical namespace) and blob
#      container for the schema registry.
#   3. Creates a schema registry and assigns the required RBAC role.
#   4. Initializes the cluster for IoT Operations (az iot ops init).
#   5. Deploys the IoT Operations instance (az iot ops create).
#   6. Verifies the deployment health (az iot ops check).
#
# Prerequisites:
#   - deploy-vm.sh and deploy-kubernetes.sh must have been run successfully.
#   - Azure CLI installed and logged in (az login).
#   - Edit config.sh with your desired settings before running.
#
# Reference: https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-deploy-iot-test-operations
#
# Usage: bash deploy-iot-ops.sh
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

# Storage account names only allow lowercase letters and numbers (3-24 chars).
# Strip any unsupported characters from the name derived from config.sh.
storageAccountName=$(echo "$storageAccountName" | tr -cd 'a-z0-9')

echo "================================================="
echo "IoT Operations Quickstart - Deploy IoT Operations"
echo "================================================="
echo "Resource Group:    $resourceGroup"
echo "Cluster Name:      $clusterName"
echo "Instance Name:     $instanceName"
echo "Schema Registry:   $schemaRegistryName"
echo "Storage Account:   $storageAccountName"
echo "================================================="

# Ensure Azure CLI is at least version 2.67.0 (required by azure-iot-ops 2.3.0).
requiredVersion="2.67.0"
currentVersion=$(az version --query '"azure-cli"' --output tsv | tr -d '[:space:]')
echo "Current Azure CLI version: $currentVersion (required: >= $requiredVersion)"

if [ "$(printf '%s\n' "$requiredVersion" "$currentVersion" | sort -V | head -n1)" != "$requiredVersion" ]; then
    echo "Upgrading Azure CLI..."
    # Remove any existing install, add the Microsoft apt repository, and
    # install the latest Azure CLI from the official packages.
    sudo apt-get remove -y azure-cli 2>/dev/null || true
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl apt-transport-https lsb-release gnupg
    sudo mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
    AZ_DIST=$(lsb_release -cs)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $AZ_DIST main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
    sudo apt-get update -qq
    sudo apt-get install -y -qq azure-cli
    echo "Azure CLI upgraded to $(az version --query '"azure-cli"' --output tsv)"

    # Re-login is required after reinstalling Azure CLI.
    echo ""
    echo "================================================="
    echo "ACTION REQUIRED: Azure CLI was upgraded."
    echo "You must log in again."
    echo "================================================="
    echo ""
    az login --use-device-code
else
    echo "Azure CLI version is sufficient."
fi

# Ensure we have an active Azure CLI session.
if ! az account show &>/dev/null; then
    echo "No active Azure CLI session. Logging in..."
    az login --use-device-code
fi

# Retrieve the active subscription ID from the CLI session.
subscriptionId=$(az account show --query id --output tsv | tr -d '[:space:]')
echo "Using subscription: $subscriptionId"

# Install or upgrade the azure-iot-ops CLI extension to version 2.3.0.
# This version is required for deploying IoT Operations v1.2.
echo "Installing Azure IoT Operations CLI extension..."
az extension add --upgrade --name azure-iot-ops --version 2.3.0 -y

# ---------------------------------------------------------------------------
# Create a storage account for the schema registry.
# The schema registry requires an Azure Data Lake Storage Gen2 account
# (hierarchical namespace enabled). This storage holds message schemas used
# by IoT Operations data flows.
# ---------------------------------------------------------------------------
if az storage account show --name "$storageAccountName" --resource-group "$resourceGroup" &>/dev/null; then
    echo "Storage account $storageAccountName already exists. Skipping."
else
    echo "Creating storage account $storageAccountName..."
    az storage account create \
        --name "$storageAccountName" \
        --resource-group "$resourceGroup" \
        --location "$location" \
        --enable-hierarchical-namespace true \
        --min-tls-version TLS1_2 \
        --sku Standard_LRS
fi

# Create a blob container within the storage account to hold schema data.
containerName="schemas"
if az storage container show --name "$containerName" --account-name "$storageAccountName" --auth-mode login &>/dev/null; then
    echo "Storage container $containerName already exists. Skipping."
else
    echo "Creating storage container $containerName..."
    az storage container create \
        --name "$containerName" \
        --account-name "$storageAccountName" \
        --auth-mode login
fi

# ---------------------------------------------------------------------------
# Create the schema registry.
# The schema registry stores message schemas (e.g., JSON, Avro) that IoT
# Operations components use for data validation and transformation in data
# flows. It is backed by the storage account and container created above.
# ---------------------------------------------------------------------------
storageAccountResourceId=$(az storage account show \
    --name "$storageAccountName" \
    --resource-group "$resourceGroup" \
    --query id --output tsv | tr -d '[:space:]')

if az iot ops schema registry show --name "$schemaRegistryName" --resource-group "$resourceGroup" &>/dev/null; then
    echo "Schema registry $schemaRegistryName already exists. Skipping."
else
    echo "Creating schema registry $schemaRegistryName..."
    az iot ops schema registry create \
        --name "$schemaRegistryName" \
        --resource-group "$resourceGroup" \
        --registry-namespace "$schemaRegistryNamespace" \
        --sa-resource-id "$storageAccountResourceId" \
        --sa-container "$containerName"
fi

schemaRegistryResourceId=$(az iot ops schema registry show \
    --name "$schemaRegistryName" \
    --resource-group "$resourceGroup" \
    --query id --output tsv | tr -d '[:space:]')

# ---------------------------------------------------------------------------
# Assign the Storage Blob Data Contributor role to the schema registry's
# system-assigned managed identity. This role grants the registry read/write
# access to the blob container where schemas are stored.
#
# The 'az iot ops schema registry create' command attempts this assignment
# automatically, but it can time out in some environments (e.g., when
# AzureCliCredential takes too long). We ensure it explicitly here.
# ---------------------------------------------------------------------------
echo "Ensuring role assignment for schema registry managed identity..."
schemaRegistryPrincipalId=$(az iot ops schema registry show \
    --name "$schemaRegistryName" \
    --resource-group "$resourceGroup" \
    --query "identity.principalId" --output tsv | tr -d '[:space:]')

containerScope="${storageAccountResourceId}/blobServices/default/containers/${containerName}"

existing=$(az role assignment list \
    --assignee "$schemaRegistryPrincipalId" \
    --role "Storage Blob Data Contributor" \
    --scope "$containerScope" \
    --query "[].id" --output tsv 2>/dev/null | tr -d '[:space:]')

if [ -n "$existing" ]; then
    echo "  Role assignment already exists. Skipping."
else
    echo "  Assigning Storage Blob Data Contributor..."
    az role assignment create \
        --assignee-object-id "$schemaRegistryPrincipalId" \
        --assignee-principal-type ServicePrincipal \
        --role "Storage Blob Data Contributor" \
        --scope "$containerScope"
fi

# ---------------------------------------------------------------------------
# Initialize the cluster for IoT Operations.
# 'az iot ops init' installs prerequisite components on the Arc-enabled
# cluster including cert-manager and trust-manager. This command only needs
# to be run once per cluster.
# ---------------------------------------------------------------------------
echo "Initializing cluster for IoT Operations..."
az iot ops init \
    --cluster "$clusterName" \
    --resource-group "$resourceGroup"

# ---------------------------------------------------------------------------
# Create a Device Registry namespace.
# A namespace organizes assets and devices in Azure Device Registry. Each
# IoT Operations instance uses a single namespace. Its resource ID is
# required by 'az iot ops create'.
# ---------------------------------------------------------------------------
echo "Creating Device Registry namespace..."
az iot ops ns create \
    --name "$deviceRegistryNamespace" \
    --resource-group "$resourceGroup" \
    --location "$location"

nsResourceId=$(az iot ops ns show \
    --name "$deviceRegistryNamespace" \
    --resource-group "$resourceGroup" \
    --query "id" --output tsv | tr -d '[:space:]')

# ---------------------------------------------------------------------------
# Deploy Azure IoT Operations instance.
# 'az iot ops create' deploys the full IoT Operations suite (MQTT broker,
# data flows, OPC UA connector, etc.) to the Arc-enabled cluster.
#
# Broker settings below are configured for test/evaluation scenarios:
#   - 1 frontend replica/worker:  Minimal ingress capacity.
#   - 1 backend partition, 2 replicas: Basic HA with low resource usage.
#   - Low memory profile:  Suitable for the Standard_D4s_v5 VM size.
# ---------------------------------------------------------------------------
echo "Deploying IoT Operations (this may take several minutes)..."
az iot ops create \
    --cluster "$clusterName" \
    --resource-group "$resourceGroup" \
    --name "$instanceName" \
    --sr-resource-id "$schemaRegistryResourceId" \
    --ns-resource-id "$nsResourceId" \
    --broker-frontend-replicas 1 \
    --broker-frontend-workers 1 \
    --broker-backend-part 1 \
    --broker-backend-workers 1 \
    --broker-backend-rf 2 \
    --broker-mem-profile Low

# ---------------------------------------------------------------------------
# Create a LoadBalancer listener for external MQTT access.
# This listener exposes port 1883 with no TLS and no authentication,
# suitable for test/evaluation scenarios only. Do NOT use in production.
# Reference: https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener
# ---------------------------------------------------------------------------
echo "Creating LoadBalancer listener (port 1883, no TLS, no auth)..."
listenerConfig=$(cat <<'LISTENER_JSON'
{
    "serviceType": "LoadBalancer",
    "ports": [
        {
            "port": 1883,
            "protocol": "Mqtt"
        }
    ]
}
LISTENER_JSON
)

echo "$listenerConfig" > /tmp/loadbalancer-listener.json
az iot ops broker listener apply \
    --resource-group "$resourceGroup" \
    --instance "$instanceName" \
    --broker default \
    --name aio-broker-loadbalancer \
    --config-file /tmp/loadbalancer-listener.json
rm -f /tmp/loadbalancer-listener.json

# ---------------------------------------------------------------------------
# Enable resource sync rules.
# Resource sync rules allow the IoT Operations instance to synchronize
# device and asset definitions between Azure Device Registry and the
# cluster. This is required for the MQTT connector and other connectors
# to create and manage assets.
# Reference: https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector
# ---------------------------------------------------------------------------
echo "Enabling resource sync rules..."
az iot ops enable-rsync \
    --name "$instanceName" \
    --resource-group "$resourceGroup"

# ---------------------------------------------------------------------------
# Verify the deployment.
# 'az iot ops check' evaluates the IoT Operations services for health,
# configuration, and usability. This command requires kubectl access to the
# cluster, so it must be run from the VM via SSH. A warning about missing
# data flows is expected until you create your first data flow.
# ---------------------------------------------------------------------------
echo "Verifying IoT Operations deployment..."

# Ensure sshpass is installed for automated SSH access.
if ! command -v sshpass &>/dev/null; then
    echo "Installing sshpass..."
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
fi

publicIp=$(az vm show \
    --resource-group "$resourceGroup" \
    --name "$vmName" \
    --show-details \
    --query publicIps \
    --output tsv | tr -d '[:space:]')

SSH_CMD="sshpass -p $password ssh -o StrictHostKeyChecking=no $user@$publicIp"
$SSH_CMD "az iot ops check"

echo "================================================="
echo "IoT Operations deployment complete!"
echo "================================================="
