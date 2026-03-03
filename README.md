# IoT Operations Quickstart

Automated deployment scripts for a single-node [Azure IoT Operations](https://learn.microsoft.com/en-us/azure/iot-operations/) test instance running on an Arc-enabled Azure VM with K3s.

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│ Azure Resource Group                                          │
│                                                               │
│ ┌──────────────────┐   ┌──────────────────────────────────┐   │
│ │ NSG              │   │ Azure VM (Ubuntu 24.04)          │   │
│ │  - SSH (22)      │-->│                                  │   │
│ │  - MQTT (1883)   │   │  Arc-enabled Server              │   │
│ ├──────────────────┤   │                                  │   │
│ │ VNet / Subnet    │   │  ┌────────────────────────────┐  │   │
│ └──────────────────┘   │  │ K3s Cluster (Arc-enabled)  │  │   │
│                        │  │                            │  │   │
│                        │  │  ┌──────────────────────┐  │  │   │
│                        │  │  │ Azure IoT Operations │  │  │   │
│                        │  │  │                      │  │  │   │
│                        │  │  │  MQTT Broker         │  │  │   │
│ ┌──────────────────┐   │  │  │  LB Listener :1883   │  │  │   │
│ │ Storage (HNS)    │   │  │  │                      │  │  │   │
│ │  └─ schemas      │-->│  │  └──────────────────────┘  │  │   │
│ ├──────────────────┤   │  │                            │  │   │
│ │ Schema Registry  │   │  └────────────────────────────┘  │   │
│ ├──────────────────┤   │                                  │   │
│ │ Device Registry  │   └──────────────────────────────────┘   │
│ │  Namespace       │                                          │
│ └──────────────────┘                                          │
└───────────────────────────────────────────────────────────────┘
                             ^
                             | Port 1883
                        MQTT Client
```

## Prerequisites

- **Linux terminal required** — these are bash scripts and must be run from a Linux environment (e.g., Ubuntu, WSL, Azure Cloud Shell)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in
- An Azure subscription with permissions to create resources and register providers

## Scripts

| Script             | Purpose                                                                 |
|---------------------|-------------------------------------------------------------------------|
| `config.sh`         | Shared configuration variables (resource names, VM size, credentials, etc.) |
| `deploy-vm.sh`      | Creates an Azure VM with Arc enablement                                 |
| `deploy-kubernetes.sh` | Installs K3s, Helm, and Arc-enables the cluster for IoT Operations   |
| `deploy-iot-ops.sh` | Deploys Azure IoT Operations to the Arc-enabled cluster                 |

## Configuration

Edit `config.sh` before running. Key settings:

| Variable                   | Description                          | Default                  |
|----------------------------|--------------------------------------|--------------------------|
| `user`                     | VM admin username                    | `azureuser`              |
| `password`                 | VM admin password                    | `P@ssw0rd1234!`          |
| `location`                 | Azure region                         | `eastus2`                |
| `suffix`                   | Unique suffix for resource names     | `-`                      |
| `vmsize`                   | VM size                              | `Standard_D4s_v5`        |
| `storageAccountName`       | Storage account for schema registry  | `iotops<suffix>storage`  |
| `schemaRegistryName`       | Schema registry name                 | `iotops<suffix>sr`       |
| `deviceRegistryNamespace`  | Device Registry namespace            | `iotops<suffix>ns`       |
| `instanceName`             | IoT Operations instance name         | `iotops<suffix>instance` |

Change `suffix` to a unique value for each new deployment to avoid naming conflicts.

## Usage

### 1. Deploy the VM

```bash
bash deploy-vm.sh
```

This will:
- Register required Azure resource providers
- Create a resource group, NSG (with SSH and MQTT ports open to your IP only), VNet, and Ubuntu 24.04 VM
- Arc-enable the VM

### 2. Install K3s and prepare the cluster

```bash
bash deploy-kubernetes.sh
```

This will:
- Install Azure CLI and K3s on the VM
- **Prompt for device code login** — follow the on-screen instructions to authenticate
- Install Helm and configure kubeconfig
- Arc-enable the K3s cluster with OIDC issuer and workload identity
- Configure custom locations
- Apply kernel tuning (inotify, file descriptors) for IoT Operations

### 3. Deploy IoT Operations

```bash
bash deploy-iot-ops.sh
```

This will:
- Install the `azure-iot-ops` CLI extension (v2.3.0)
- Create a storage account (hierarchical namespace enabled) and container for schemas
- Create a schema registry for IoT Operations
- Initialize the cluster with `az iot ops init`
- Create a Device Registry namespace
- Deploy the IoT Operations instance with `az iot ops create`
- Create a LoadBalancer listener on port 1883 (no TLS, no auth) for MQTT testing
- Enable resource sync rules (`az iot ops enable-rsync`) for connector and asset management
- Verify the deployment with `az iot ops check` (run on the VM via SSH)

Reference: [Deploy Azure IoT Operations to a test cluster](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-deploy-iot-test-operations)

### 4. Deploy the MQTT connector template (portal)

To have MQTT messages automatically discovered as managed assets, deploy the MQTT connector template:

1. In the **Azure portal**, go to your IoT Operations instance
2. Select **Connector templates** → **Create a connector template**
3. Select **MQTT** as the type
4. Accept defaults through the wizard → **Create**

Once deployed, create a device and configure topic discovery in the [Operations Experience UI](https://iotoperations.azure.com). See [Configure the connector for MQTT](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector) for details.

## Cleanup

Delete the resource group to remove all resources:

```bash
az group delete --name iotops<suffix>rg --yes --no-wait
```

## References

- [Prepare a cluster for IoT Operations](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-prepare-cluster?tabs=ubuntu)
- [K3s Quick Start](https://docs.k3s.io/quick-start)
- [Azure Arc-enabled servers on Azure VMs](https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)
- [Configure MQTT broker listeners](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener)
- [Configure the connector for MQTT](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector)