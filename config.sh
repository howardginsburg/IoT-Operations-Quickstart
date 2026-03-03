# =============================================================================
# IoT Operations Quickstart - Configuration
# =============================================================================
# This file contains all shared configuration variables used across the
# deployment scripts (deploy-vm.sh, deploy-kubernetes.sh, deploy-iot-ops.sh).
# Modify these values to customize your deployment before running any script.
# =============================================================================

# VM admin username used to SSH into the Ubuntu VM.
user="azureuser"

# VM admin password. Used for SSH authentication (password-based).
# Change this to a strong, unique password before deploying.
password="P@ssw0rd1234!"

# Azure region where all resources will be deployed.
location="eastus2"

# Unique suffix appended to all resource names to avoid naming collisions.
# Change this to a unique value for each new deployment (e.g., "42", "dev01").
suffix="dev"

# Azure VM size. Standard_D4s_v5 provides 4 vCPUs and 16 GB RAM,
# which meets the minimum requirements for IoT Operations.
vmsize="Standard_D4s_v5"

# ---------------------------------------------------------------------------
# Core Azure resource names (derived from suffix).
# These are used by deploy-vm.sh and deploy-kubernetes.sh.
# ---------------------------------------------------------------------------
resourceGroup="iotops${suffix}rg"
nsgName="iotops${suffix}nsg"
vnetName="iotops${suffix}vnet"
vmName="iotops${suffix}vm"
clusterName="${vmName}-cluster"

# ---------------------------------------------------------------------------
# IoT Operations resource names (derived from suffix).
# These are used by deploy-iot-ops.sh.
# ---------------------------------------------------------------------------
# Storage account for the schema registry (must have hierarchical namespace).
storageAccountName="iotops${suffix}storage"
# Schema registry used by IoT Operations to store message schemas.
schemaRegistryName="iotops${suffix}sr"
# Namespace within the schema registry for organizing schemas.
schemaRegistryNamespace="iotops${suffix}srn"
# Name of the Azure IoT Operations instance deployed to the cluster.
instanceName="iotops${suffix}instance"
# Azure Device Registry namespace for organizing assets and devices.
deviceRegistryNamespace="iotops${suffix}ns"

# Ubuntu VM image. Uses the latest Ubuntu 24.04 LTS server image from Canonical.
ubuntuimage="Canonical:ubuntu-24_04-lts:server:latest"

# ---------------------------------------------------------------------------
# Network configuration for the VM's virtual network and subnet.
# ---------------------------------------------------------------------------
vnetAddressPrefix="10.0.0.0/16"
subnetPrefix="10.0.0.0/24"
subnetName="default"