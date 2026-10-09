#!/usr/bin/env bash
# Cria a rede (VNet) e as duas VMs do teste.
#
# Rodar no Git Bash, de dentro da pasta teste-cicd:
#   az login
#   MEU_IP=$(curl -4 -s https://ifconfig.me) bash infra/01-criar-rede-e-vms.sh
#
# Resultado:
#   rg-teste-cicd
#   └── vnet-teste-cicd (10.10.0.0/16)
#       └── snet-app (10.10.1.0/24) ── nsg-app (SSH e HTTP só do MEU_IP)
#           ├── vm-dev   Standard_B2ats_v2  ← recebe deploy de push em dev
#           └── vm-prod  Standard_B2ats_v2  ← recebe deploy de push em main
#
# Custo: a conta gratuita dá 750 h/mês de B2ats v2 (x64, mesma arquitetura da produção). Duas VMs
# ligadas 24h somam ~1.488 h — as ~740 h excedentes saem do crédito de US$ 200 (poucos dólares).
# Para ficar 100% no gratuito: desalocar a vm-dev quando não estiver testando
#   az vm deallocate -g rg-teste-cicd -n vm-dev
# (B1s saiu da lista gratuita; B2pts v2 é ARM e exigiria imagem arm64 + driver ODBC arm64.)
set -euo pipefail

RG="${RG:-rg-teste-cicd}"
LOC="${LOC:-chilecentral}"   # brazilsouth e eastus2 bloqueiam B2ats v2 na conta gratuita
VNET="vnet-teste-cicd"
SUBNET="snet-app"
NSG="nsg-app"
ADMIN="azureuser"
MEU_IP="${MEU_IP:?defina MEU_IP com seu IP público. Ex: MEU_IP=\$(curl -4 -s https://ifconfig.me)}"
CLOUD_INIT="$(dirname "$0")/cloud-init.yaml"

echo "==> Resource group $RG ($LOC)"
az group create -n "$RG" -l "$LOC" -o none

echo "==> VNet $VNET + subnet $SUBNET"
az network vnet create -g "$RG" -n "$VNET" \
  --address-prefix 10.10.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefixes 10.10.1.0/24 -o none

echo "==> NSG $NSG (entrada só do seu IP: $MEU_IP)"
az network nsg create -g "$RG" -n "$NSG" -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-ssh-meu-ip \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$MEU_IP" --destination-port-ranges 22 -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-http-meu-ip \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$MEU_IP" --destination-port-ranges 80 -o none
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" \
  --network-security-group "$NSG" -o none

criar_vm() {
  local nome="$1" size="$2"
  echo "==> VM $nome ($size)"
  az vm create -g "$RG" -n "$nome" \
    --image Ubuntu2404 \
    --size "$size" \
    --vnet-name "$VNET" --subnet "$SUBNET" \
    --nsg "" \
    --public-ip-sku Standard \
    --admin-username "$ADMIN" \
    --generate-ssh-keys \
    --os-disk-size-gb 64 --storage-sku Premium_LRS \
    --custom-data "$CLOUD_INIT" \
    -o none
}

criar_vm vm-dev  Standard_B2ats_v2
criar_vm vm-prod Standard_B2ats_v2

echo
echo "==> Pronto. IPs:"
az vm list-ip-addresses -g "$RG" \
  --query "[].{vm:virtualMachine.name, publico:virtualMachine.network.publicIpAddresses[0].ipAddress, privado:virtualMachine.network.privateIpAddresses[0]}" \
  -o table
echo
echo "Próximo: ssh $ADMIN@<ip> e rodar 'cloud-init status --wait' (leva ~3-5 min no primeiro boot)"
