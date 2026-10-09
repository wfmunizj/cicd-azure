#!/usr/bin/env bash
# Apaga TUDO do teste (VMs, discos, IPs, rede). Irreversível.
#   bash infra/99-apagar-tudo.sh
set -euo pipefail
RG="${RG:-rg-teste-cicd}"

echo "Recursos que serão apagados em $RG:"
az resource list -g "$RG" --query "[].{tipo:type, nome:name}" -o table
read -r -p "Digite o nome do resource group para confirmar: " conf
[[ "$conf" == "$RG" ]] || { echo "Cancelado."; exit 1; }

az group delete -n "$RG" --yes --no-wait
echo "Exclusão iniciada (leva alguns minutos). Conferir: az group exists -n $RG"
