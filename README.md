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

| Variable                     | Description                            | Default                    |
|------------------------------|----------------------------------------|----------------------------|
| `user`                       | VM admin username                      | `azureuser`                |
| `password`                   | VM admin password                      | `P@ssw0rd1234!`            |
| `location`                   | Azure region                           | `eastus2`                  |
| `suffix`                     | Unique suffix for resource names       | `-`                        |
| `vmsize`                     | VM size                                | `Standard_D4s_v5`          |
| `storageAccountName`         | Storage account for schema registry    | `iotops<suffix>storage`    |
| `schemaRegistryName`         | Schema registry name                   | `iotops<suffix>sr`         |
| `deviceRegistryNamespace`    | Device Registry namespace              | `iotops<suffix>ns`         |
| `instanceName`               | IoT Operations instance name           | `iotops<suffix>instance`   |
| `keyVaultName`               | Azure Key Vault for secret management  | `iotops<suffix>kv`         |
| `secretsManagedIdentityName` | Managed identity for secret sync       | `iotops<suffix>secretsid`  |

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
- Set up secret management (Key Vault + Secret Store extension) for dataflow endpoints
- Verify the deployment with `az iot ops check` (run on the VM via SSH)

Reference: [Deploy Azure IoT Operations to a test cluster](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-deploy-iot-test-operations)

### 4. Deploy the MQTT connector template (portal)

To have MQTT messages automatically discovered as managed assets, deploy the MQTT connector template:

1. In the **Azure portal**, go to your IoT Operations instance
2. Select **Connector templates** → **Create a connector template**
3. Select **MQTT** as the type
4. Accept defaults through the wizard → **Create**

Once deployed, create a device and configure topic discovery in the [Operations Experience UI](https://iotoperations.azure.com). See [Configure the connector for MQTT](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector) for details.

### 5. Create a device and configure topic discovery (portal)

In the [Operations Experience UI](https://iotoperations.azure.com):

1. Go to **Devices** → **Create new**
2. Enter a name (e.g. `internal-broker`)
3. Select **New** on the **Microsoft.Mqtt** tile
4. On the **Basic** tab:
   - **Endpoint name**: a unique identifier for this connection (e.g. `aio-broker-endpoint`). Only lowercase letters, numbers, dashes, and underscores are allowed.
   - **URL**: the cluster-internal address of the MQTT broker. Use `mqtt://aio-broker-loadbalancer.azure-iot-operations.svc.cluster.local:1883` — this is the LoadBalancer listener configured with no TLS and no auth. The connector runs inside the cluster, so it uses the internal cluster service address rather than the external VM IP.
   - **Auth mode**: `Anonymous` — since the internal broker listener uses the default authentication, and the connector runs as a trusted workload inside the cluster.
5. On the **Advanced** tab:
   - **Asset level**: the position in the topic path (1-based) that identifies the asset name. For example, with the topic `contoso/redmond/building40/line1/factory-sensor-01/telemetry`, setting asset level to `5` picks `factory-sensor-01` as the asset name (level 1=contoso, 2=redmond, 3=building40, 4=line1, 5=factory-sensor-01, 6=telemetry).
   - **Topic filter**: the MQTT topic pattern that determines which topics the connector monitors. Only the single-level wildcard `+` is supported (not the multi-level `#`). For example, `contoso/+/+/+/+/+` discovers all six-level topics under `contoso/`. A more specific filter like `contoso/redmond/building40/line1/+/telemetry` would only discover sensors under line1.
   - **Topic mapping prefix**: a plain string (no wildcards, no trailing slash) prepended to the incoming topic when the connector forwards messages to the unified namespace. For example, with a prefix of `unified`, messages arriving on `contoso/redmond/.../telemetry` are forwarded to `unified/contoso/redmond/.../telemetry`. Use a simple word like `unified` or `discovered`. This prevents a subscription loop when the connector subscribes to the same broker it forwards to. Do **not** include MQTT wildcards (`+`, `#`) or a trailing `/` — these cause an "Invalid topic mapping prefix" error.
6. Select **Apply** to save the endpoint. Then select **Next** to continue.
7. On the **Add custom property** tab, optionally add key-value metadata. These are stored in Azure Device Registry for organizational purposes and don't affect connector behavior. For example:
   - `environment` = `test`
   - `protocol` = `mqtt`
   - `source` = `internal-broker`
8. Select **Next** → review the summary → **Create**

### 6. Publish messages and discover assets

Publish a test message from an MQTT client:

```bash
mosquitto_pub -h <VM_PUBLIC_IP> -p 1883 -t "contoso/redmond/building40/line1/factory-sensor-01/telemetry" -m '{"temperature": 22.5}'
```

Back in the Operations Experience UI:

1. Go to **Discovery** — the discovered asset appears (e.g. `factory-sensor-01-kblj`)
2. Select the discovered asset to view its dataset and topic mapping
3. Optionally promote it to a managed asset by selecting **Import and create asset**

The connector subscribes to the internal broker, discovers new topics matching your filter, and registers them as discovered assets in Azure Device Registry. Each unique asset name (extracted at the configured asset level) creates a separate discovered asset with its associated topic mapping.

### 7. Promote discovered assets and create dataflows

Once assets are discovered, promote them to managed assets and route their data to cloud endpoints.

#### Promote a discovered asset

1. In the Operations Experience UI, go to **Discovery**
2. Select a discovered asset (e.g. `factory-sensor-01-kblj`)
3. Select **Import and create asset**
4. On the **Asset details** page:
   - The inbound endpoint is already selected from the device
   - Use the discovered asset name as the asset name (the name **must** match the discovered asset name)
   - Add a description and any custom properties
   - Select **Next**
5. On the **Datasets** page:
   - A dataset is pre-populated from the discovered topic. For example:
     - **Dataset name**: `contoso/redmond/building40/line1/factory-sensor-01/telemetry`
     - **Data source**: `contoso/redmond/building40/line1/factory-sensor-01/telemetry`
     - **Destination topic**: `unified/contoso/redmond/building40/line1/factory-sensor-01/telemetry`
   - You can add more datasets if needed to capture messages from other topics
   - Select **Next**
6. On the **Review** page, verify the details and select **Create**

After a few minutes, the asset appears on the **Assets** page as a managed `Microsoft.DeviceRegistry/assets` resource. Messages published to the source topic are now copied to the unified namespace destination topic by the connector.

#### Create a dataflow

Dataflows route telemetry from managed assets to cloud endpoints such as Event Hubs, Azure Data Lake, or Microsoft Fabric.

1. In the Operations Experience UI, go to **Dataflows** → **Create dataflow**
2. Configure the **source** — select the MQTT broker topic (e.g. `unified/contoso/redmond/building40/line1/factory-sensor-01/telemetry`)
3. Configure the **destination** — choose a cloud endpoint:
   - **Event Hubs** — for stream processing and real-time analytics
   - **Azure Data Lake / Fabric** — for batch analytics and storage
   - **Azure Data Explorer** — for time-series queries
4. Optionally add **transformations** to filter, enrich, or reshape the data
5. Select **Create** to deploy the dataflow

See [Create a dataflow](https://learn.microsoft.com/en-us/azure/iot-operations/connect-to-cloud/howto-create-dataflow) for details.

#### Discover additional assets

Publish messages on new topics matching your filter to automatically discover more assets:

```bash
mosquitto_pub -h <VM_PUBLIC_IP> -p 1883 -t "contoso/redmond/building40/line1/factory-sensor-02/telemetry" -m '{"humidity": 45.2}'
mosquitto_pub -h <VM_PUBLIC_IP> -p 1883 -t "contoso/redmond/building40/line2/press-sensor-01/telemetry" -m '{"pressure": 101.3}'
```

Each unique asset name (level 5 of the topic path) creates a new discovered asset automatically.

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
- [Create a dataflow](https://learn.microsoft.com/en-us/azure/iot-operations/connect-to-cloud/howto-create-dataflow)