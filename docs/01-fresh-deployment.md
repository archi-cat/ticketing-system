# Fresh deployment runbook

End-to-end deployment from empty Azure subscription to running services.
The order is strict — each phase depends on prior phases being complete.

## Phase 0 — Subscription prerequisites (one-time)

These need to be done once per Azure subscription. After they're set,
future deployments don't need to repeat them.

### 0.1 Register AKS preview features

The AGC (Application Gateway for Containers) add-on and the Gateway API
managed installation are behind preview feature flags. Register them once
per subscription:

```powershell
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview

# Wait 5-15 minutes until both report "Registered"
az feature show --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview --query "properties.state"
az feature show --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview --query "properties.state"

# Propagate to the resource provider
az provider register --namespace Microsoft.ContainerService
```

Reference: https://learn.microsoft.com/en-us/azure/aks/managed-gateway-api

### 0.2 Create the Terraform state storage

The shared ACR module and the regional infrastructure module both write
their state here. See `terraform/bootstrap/README.md` for the exact
commands. Set up once per subscription.

### 0.3 Configure the OIDC federated identity for GitHub Actions

Create the Service Principal `sp-hello-world-github` with federated
credentials for this repo's main branch and PR workflows. See ADR-0001
for context.

## Phase 1 — Infrastructure deployment

### 1.1 Deploy the shared ACR

```powershell
gh workflow run infra-shared.yml
```

Wait for completion (~5 minutes).

### 1.2 Deploy the regional infrastructure

```powershell
gh workflow run infra-uksouth.yml
```

Wait for completion (~15-20 minutes). This creates the VNet, subnets,
private DNS zones, AKS cluster, PostgreSQL Flexible Server (Entra auth
enabled), Azure Managed Redis, Service Bus namespace, Key Vault, and
all the role assignments / federated credentials.

### 1.3 Enable AGC and Gateway API add-ons on AKS

Currently a manual step — the azurerm Terraform provider doesn't yet
surface the `ingressProfile` settings for these add-ons. Run after the
cluster exists, once per cluster:

```powershell
$RG = "rg-ticketing-uksouth"
$AKS = (az aks list -g $RG --query '[0].name' -o tsv)
$AKS_ID = az aks show -g $RG -n $AKS --query id -o tsv

@'
{
  "location": "uksouth",
  "properties": {
    "ingressProfile": {
      "applicationLoadBalancer": { "enabled": true },
      "gatewayAPI": { "installation": "Standard" }
    }
  }
}
'@ | Out-File -FilePath addon-body.json -Encoding utf8

az rest --method put `
    --uri "https://management.azure.com${AKS_ID}?api-version=2025-09-02-preview" `
    --headers "Content-Type=application/json" `
    --body "@addon-body.json"

Remove-Item addon-body.json
```

Wait 3-5 minutes for the add-ons to install. Verify:

```powershell
kubectl get crd | Select-String gateway
kubectl get pods -n kube-system | Select-String alb-controller
kubectl get gatewayclass azure-alb-external
```

All three should return content. If any return nothing, wait another
few minutes and re-check.

## Phase 2 — Database bootstrap

PostgreSQL is VNet-injected and not reachable from outside the VNet, so
these steps run from a temporary Linux VM inside the VNet.

### 2.1 Create a temporary VM in the VNet

```powershell
$RG = "rg-ticketing-uksouth"
$VNET = (az network vnet list -g $RG --query '[0].name' -o tsv)
$SUBNET_ID = az network vnet subnet show -g $RG --vnet-name $VNET --name snet-private-endpoints --query id -o tsv

az vm create `
    --resource-group $RG `
    --name vm-bootstrap-temp `
    --image Ubuntu2204 `
    --size Standard_B1s `
    --subnet $SUBNET_ID `
    --admin-username azureuser `
    --generate-ssh-keys `
    --public-ip-sku Standard

$VM_IP = az vm show -d -g $RG -n vm-bootstrap-temp --query publicIps -o tsv
```
Note: Add a temporary inbound rule that will allow SSH connections to the NSG(e.g. nsg-pe-uksouth) associated with the subnet(e.g. snet-private-endpoints) where the VM is deployed to.

### 2.2 SSH in and install tooling

```bash
ssh azureuser@$VM_IP
```

Inside the VM:

```bash
sudo apt update
sudo apt install -y postgresql-client jq git
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.local/bin/env

# Log in as YOURSELF (the Entra admin), not the VM's managed identity
az login --use-device-code
```

### 2.3 Apply migrations

```bash
git clone https://github.com/<your-username>/ticketing-system.git
cd ticketing-system/app/api

export POSTGRES_HOST=$(az postgres flexible-server list \
    --resource-group rg-ticketing-uksouth \
    --query '[0].fullyQualifiedDomainName' -o tsv)
export POSTGRES_PORT=5432
export POSTGRES_DATABASE=ticketing
export POSTGRES_USER=$(az ad signed-in-user show --query userPrincipalName -o tsv)
export POSTGRES_USE_WORKLOAD_IDENTITY=true
export LOG_FORMAT=console

uv sync
uv run alembic upgrade head
```

Expected output ends with `Running upgrade -> 20260427_1200, initial schema`.

### 2.4 Run the grant script

The script registers each application UAMI as an Entra-mapped role and
grants database-level permissions. From the same SSH session:

```bash
cd ~/ticketing-system
pwsh ./scripts/Grant-PostgresWorkloadIdentity.ps1 \
    -PostgresHost $POSTGRES_HOST \
    -Database ticketing \
    -ApiUamiName "uami-ticketing-uksouth-api" \
    -WorkerUamiName "uami-ticketing-uksouth-worker" \
    -SchedulerUamiName "uami-ticketing-uksouth-scheduler"
```

If `pwsh` isn't installed, install it first:

```bash
sudo snap install powershell --classic
```

The script prints `Done.` on success.

### 2.5 Seed sample data

```bash
pwsh ./scripts/Seed-SampleEvents.ps1 \
    -PostgresHost $POSTGRES_HOST \
    -Database ticketing \
    -PostgresUser $POSTGRES_USER
```

Output lists four seeded events.

### 2.6 Tear down the VM

Exit SSH, then from your local machine:

```powershell
az vm delete -g rg-ticketing-uksouth -n vm-bootstrap-temp --yes
az network nic delete -g rg-ticketing-uksouth -n vm-bootstrap-tempVMNic
az network public-ip delete -g rg-ticketing-uksouth -n vm-bootstrap-tempPublicIP

Start-Sleep -Seconds 10
az disk list -g rg-ticketing-uksouth --query "[?contains(name,'vm-bootstrap-temp')].name" -o tsv |
    ForEach-Object { az disk delete -g rg-ticketing-uksouth -n $_ --yes }
```

## Phase 3 — Application deployment

```powershell
gh workflow run deploy-api.yml
gh workflow run deploy-worker.yml
gh workflow run deploy-scheduler.yml
```

Each takes 5-8 minutes. They run in parallel.

Verify after completion:

```powershell
az aks get-credentials -g rg-ticketing-uksouth -n (az aks list -g rg-ticketing-uksouth --query '[0].name' -o tsv)
kubectl get pods -n ticketing
```

All six pods (api × 2, worker × 2, scheduler × 2) should be `1/1 Running`.

## Phase 4 — End-to-end smoke test

```powershell
# Port-forward to the API
kubectl port-forward -n ticketing svc/api 8000:80
```

In another shell:

```powershell
curl http://localhost:8000/events
$EVENT_ID = (curl -s http://localhost:8000/events | ConvertFrom-Json).items[0].id
$RES = curl -X POST "http://localhost:8000/events/$EVENT_ID/reservations" `
    -H "Content-Type: application/json" `
    -d '{"customer_email":"smoke@example.com","seat_count":2}' | ConvertFrom-Json
curl -X POST "http://localhost:8000/reservations/$($RES.id)/confirm" `
    -H "Content-Type: application/json" `
    -d '{"card_last_four":"1234"}'
```

If the reservation creates and confirms, the system is end-to-end working.

## Troubleshooting

### Pods CrashLoopBackOff with PostgreSQL auth errors

`pg_hba.conf rejects connection for host ... user "uami-ticketing-uksouth-api"`
means the UAMI isn't a registered Entra principal on the server. Re-run
Phase 2.4 (the grant script).

### Pods CrashLoopBackOff with Redis errors

Most likely the access policy assignment hasn't propagated. Wait 5-10
minutes and the pods will retry on their own. If still failing after
that, verify `kubectl get pods -n ticketing -o yaml | Select-String REDIS_USERNAME`
matches the UAMI principal IDs from Terraform outputs.

### Gateway has no ADDRESS

The ALB Controller needs an `ApplicationLoadBalancer` Kubernetes resource
or a BYO AGC instance to provision the public frontend. See
`docs/runbooks/02-gateway-setup.md` (TODO — being written).