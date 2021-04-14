#!/bin/bash

: '
#***************************************
# INTIAL SETUP AND PREREQUISITES
#***************************************

# log in to Azure
az login

# show available subscriptions
az account list --output table

# if required, change subscription context
az account set --subscription "VSE-Subscription-01"

# Provider register: Register the Azure Kubernetes Service provider
az provider register --namespace Microsoft.ContainerService

# Provider register: Register the Azure Policy provider, required for logging to Log Analytics
az provider register --namespace Microsoft.PolicyInsights
az provider register --namespace Microsoft.OperationsManagement
az provider register --namespace Microsoft.OperationalInsights

# add azure firewall extension
az extension add --name azure-firewall

# add the aks-preview Az CLI extension, required to enable the --node-resource-group parameter for naming the NRG resource group
az extension add --name aks-preview
'
# create random number for globally unique resource names
RAND=$((10000 + $RANDOM % 99999))
RAND="8769"

# On Git Bash, if you specify command-line options starting with a slash, POSIX-to-Windows path conversion will kick in. This causes an issue for passing ARM Resource IDs
# https://github.com/Azure/azure-cli/blob/dev/doc/use_cli_with_git_bash.md#auto-translation-of-resource-ids
# haven't tried with WSL Bash.  Ask Hisham for preference.
# To disable the path conversion
MSYS_NO_PATHCONV=1

# log analytics workspace details, for monitoring
# ****************  if not using, remove parameter in az aks create
LAW_RG="defaultresourcegroup-weu"
LAW_NAME="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# create or retrieve environment variables
TENANT_ID=$(az account show --query tenantId --output tsv)
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
SUBSCRIPTION_NAME=$(az account show --query name --output tsv)
LOCATION="westeurope"
TTM_RG_NAME="TTM_RG"
TTM_NRG_NAME="TTM_NRG"
PCS_RG_NAME="MOI_PCS_RG"
TTM_AKS_VNET_NAME="ttm_vnet"
TTM_AKS_VNET_CIDR="10.10.0.0/16"
PCS_VNET_NAME="pcs_vnet"
PCS_VNET_CIDR="10.11.0.0/22"
FW_SUBNET_CIDR="10.11.0.0/24"
BASTION_SUBNET_CIDR="10.11.1.0/24"
TTM_AKS_SUBNET1_NAME="akssubnet1"
TTM_AKS_SUBNET1_CIDR="10.10.240.0/24"
TTM_AKS_SUBNET2_NAME="akssubnet2"
TTM_AKS_SUBNET2_CIDR="10.10.241.0/24"
TTM_AGIC_NAME="ttmagic"
TTM_AGIC_SUBNET_NAME="agicsubnet"
TTM_AGIC_SUBNET_CIDR="10.10.250.0/24"
FW_NAME="aksfw"
ACR_NAME="moiacr"$RAND
TTM_AKS_CLUSTER1_NAME="ttm-cluster1"
TTM_SP_NAME="ttm_sp"

# create resource groups
az group create --location $LOCATION --name $TTM_RG_NAME
az group create --location $LOCATION --name $PCS_RG_NAME

# create vnets and subnets
az network vnet create --resource-group $TTM_RG_NAME --name $TTM_AKS_VNET_NAME --address-prefixes $TTM_AKS_VNET_CIDR --output none
az network vnet subnet create --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AKS_SUBNET1_NAME --address-prefixes $TTM_AKS_SUBNET1_CIDR  --output none
az network vnet subnet create --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AKS_SUBNET2_NAME --address-prefixes $TTM_AKS_SUBNET2_CIDR  --output none
az network vnet subnet create --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AGIC_SUBNET_NAME --address-prefixes $TTM_AGIC_SUBNET_CIDR --output none

TTM_VNET_ID=$(az network vnet show --resource-group $TTM_RG_NAME --name $TTM_AKS_VNET_NAME --query id --output tsv)
TTM_AKS_SUBNET1_ID=$(az network vnet subnet show --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AKS_SUBNET1_NAME --query id --output tsv)
TTM_AKS_SUBNET2_ID=$(az network vnet subnet show --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AKS_SUBNET2_NAME --query id --output tsv)
TTM_AGIC_SUBNET_ID=$(az network vnet subnet show --resource-group $TTM_RG_NAME --vnet-name $TTM_AKS_VNET_NAME --name $TTM_AGIC_SUBNET_NAME --query id --output tsv)

az network vnet create --resource-group $PCS_RG_NAME --name $PCS_VNET_NAME --address-prefixes $PCS_VNET_CIDR --output none
az network vnet subnet create --resource-group $PCS_RG_NAME --vnet-name $PCS_VNET_NAME --name AzureFirewallSubnet --address-prefixes $FW_SUBNET_CIDR  --output none
az network vnet subnet create -g $PCS_RG_NAME --vnet-name $PCS_VNET_NAME -n bastionsubnet --address-prefix $BASTION_SUBNET_CIDR

PCS_VNET_ID=$(az network vnet show --resource-group $PCS_RG_NAME --name $PCS_VNET_NAME --query id --output tsv)
FW_SUBNET_ID=$(az network vnet subnet show --resource-group $PCS_RG_NAME --vnet-name $PCS_VNET_NAME --name AzureFirewallSubnet --query id --output tsv)
BASTION_SUBNET_ID=$(az network vnet subnet show --resource-group $PCS_RG_NAME --vnet-name $PCS_VNET_NAME --name bastionsubnet --query id --output tsv)

# create vnet peerings
MSYS_NO_PATHCONV=1  az network vnet peering create --resource-group $PCS_RG_NAME --name PCS2TTM --vnet-name $PCS_VNET_NAME --remote-vnet-id $TTM_VNET_ID --allow-vnet-access
MSYS_NO_PATHCONV=1  az network vnet peering create --resource-group $TTM_RG_NAME --name TTM2PCS --vnet-name $TTM_AKS_VNET_NAME --remote-vnet-id $PCS_VNET_ID --allow-vnet-access

# create azure firewall
az network public-ip create --resource-group $PCS_RG_NAME --name $FW_NAME-pip --sku Standard

az network firewall create --resource-group $PCS_RG_NAME --location $LOCATION --name $FW_NAME
az network firewall ip-config create --firewall-name $FW_NAME --name $FW_NAME --public-ip-address $FW_NAME-pip --resource-group $PCS_RG_NAME --vnet-name $PCS_VNET_NAME

FW_PUBIP=$(az network public-ip show --resource-group $PCS_RG_NAME --name $FW_NAME-pip --query ipAddress)
FW_PRIVIP=$(az network firewall show --resource-group $PCS_RG_NAME --name $FW_NAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# create log analytics workspace
#az monitor log-analytics workspace create --resource-group $PCS_RG_NAME --workspace-name $LAW_NAME-lagw --location $LOCATION

# route outbound traffic to firewall
az network route-table create --resource-group $TTM_RG_NAME --name $TTM_AKS_SUBNET1_NAME-rt
az network route-table route create --resource-group $TTM_RG_NAME --name $FW_NAME \
        --route-table-name $TTM_AKS_SUBNET1_NAME-rt --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance \
        --next-hop-ip-address $FW_PRIVIP
MSYS_NO_PATHCONV=1  az network vnet subnet update --route-table $TTM_AKS_SUBNET1_NAME-rt --ids $TTM_AKS_SUBNET1_ID
az network route-table route list --resource-group $TTM_RG_NAME --route-table-name $TTM_AKS_SUBNET1_NAME-rt

az network route-table create --resource-group $TTM_RG_NAME --name $TTM_AKS_SUBNET2_NAME-rt
az network route-table route create --resource-group $TTM_RG_NAME --name $FW_NAME \
        --route-table-name $TTM_AKS_SUBNET2_NAME-rt --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance \
        --next-hop-ip-address $FW_PRIVIP
MSYS_NO_PATHCONV=1  az network vnet subnet update --route-table $TTM_AKS_SUBNET2_NAME-rt --ids $TTM_AKS_SUBNET2_ID
az network route-table route list --resource-group $TTM_RG_NAME --route-table-name $TTM_AKS_SUBNET2_NAME-rt

# add required egress destinations
# https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic
az network firewall network-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "time" --destination-addresses "*"  --destination-ports 123 --name "allow network" --protocols "UDP" --source-addresses "*" --action "Allow" --description "aks node time sync rule" --priority 101
az network firewall network-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "dns" --destination-addresses "*"  --destination-ports 53 --name "allow network" --protocols "Any" --source-addresses "*" --action "Allow" --description "aks node dns rule" --priority 102
az network firewall network-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "servicetags" --destination-addresses "AzureContainerRegistry" "MicrosoftContainerRegistry" "AzureActiveDirectory" "AzureMonitor" --destination-ports "*" --name "allow service tags" --protocols "Any" --source-addresses "*" --action "Allow" --description "allow service tags" --priority 110
az network firewall network-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "hcp" --destination-addresses "AzureCloud.$LOCATION" --destination-ports "1194" --name "allow master tags" --protocols "UDP" --source-addresses "*" --action "Allow" --description "allow aks link access to masters" --priority 120
az network firewall application-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 101
az network firewall application-rule create  --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "osupdates" --name "allow network" --protocols http=80 https=443 --source-addresses "*"  --action "Allow" --target-fqdns "download.opensuse.org" "security.ubuntu.com" "packages.microsoft.com" "azure.archive.ubuntu.com" "changelogs.ubuntu.com" "snapcraft.io" "api.snapcraft.io" "motd.ubuntu.com"  --priority 102
# for demo only
# added acr endpoints -- fixed acr pull issue
az network firewall application-rule create  --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "dockerhub" --name "allow network" --protocols http=80 https=443 --source-addresses "*"  --action "Allow" --target-fqdns "*auth.docker.io" "*cloudflare.docker.io" "*cloudflare.docker.com" "*registry-1.docker.io" "*.azurecr.io" "*.blob.core.windows.net" --priority 200
# for api to communicate with node

az network firewall network-rule create --firewall-name $FW_NAME --resource-group $PCS_RG_NAME --collection-name "apitcp" --destination-addresses "AzureCloud.$LOCATION" --destination-ports "9000" --name "allow service tags" --protocols "TCP" --source-addresses "*" --action "Allow" --description "allow service tags" --priority 200

# create acr
az acr create --resource-group $PCS_RG_NAME --name $ACR_NAME --sku Basic
ACR_ID=$(az acr show --resource-group $PCS_RG_NAME --name $ACR_NAME --query id --output tsv)

# create service principal and add role assignments
TTM_SP_PASSWD=$(MSYS_NO_PATHCONV=1 az ad sp create-for-rbac --name http://$TTM_SP_NAME --scopes $ACR_ID --role acrpull --query password --output tsv)
TTM_SP_APP_ID=$(az ad sp show --id http://$TTM_SP_NAME --query appId --output tsv)

MSYS_NO_PATHCONV=1 az role assignment create --assignee $TTM_SP_APP_ID --scope "$TTM_VNET_ID" --role "Network Contributor"
MSYS_NO_PATHCONV=1 az role assignment create --assignee $TTM_SP_APP_ID --scope "$TTM_VNET_ID" --role "Virtual Machine Contributor"

# get log analytics workspace id, for monitoring
LAW_ID=$(az monitor log-analytics workspace show --resource-group $LAW_RG --workspace-name $LAW_NAME --query id --output tsv)

# create aks cluster
# read https://docs.microsoft.com/en-us/azure/application-gateway/tutorial-ingress-controller-add-on-new
# to understand why we're not using --appgw-name moiagic (we'll have a WAF as well)
#added outbound routing type -- this fixed acr pull
MSYS_NO_PATHCONV=1 az aks create --resource-group $TTM_RG_NAME \
        --name $TTM_AKS_CLUSTER1_NAME \
        --location $LOCATION \
        --node-resource-group $TTM_NRG_NAME \
        --node-count 1 \
        --min-count 1 \
        --max-count 1 \
        --enable-cluster-autoscaler \
        --network-plugin azure \
        --network-policy azure \
        --outbound-type userDefinedRouting \
        --enable-managed-identity \
        --docker-bridge-address 172.17.0.1/16 \
        --service-cidr 10.10.249.0/24 \
        --dns-service-ip 10.10.249.10 \
        --vnet-subnet-id $TTM_AKS_SUBNET1_ID \
        --attach-acr $ACR_NAME \
        --service-principal $TTM_SP_APP_ID \
        --client-secret $TTM_SP_PASSWD \
        --generate-ssh-keys \
        --tags service=TTM environment=PoC \
        --enable-addons ingress-appgw,monitoring \
        --appgw-name $TTM_AGIC_NAME \
        --appgw-subnet-id $TTM_AGIC_SUBNET_ID \
        --workspace-resource-id $LAW_ID

        # --enable-private-cluster \

# create redis cache
# ******** NOT RECOMMENDED FOR TESTING THIS SCRIPT - it takes _HOURS_ to create and delete
# MSYS_NO_PATHCONV=1 az redis create --location $LOCATION --name $REDIS_NAME --resource-group $RG_NAME --sku Basic --vm-size c0 --subnet-id $REDIS_SUBNET_ID --tags service=TTM environment=PoC
# az redis create --location $LOCATION --name $REDIS_NAME --resource-group $RG_NAME --sku Basic --vm-size c0 --tags service=TTM environment=PoC

# from azure cloud shell, run 
echo "az aks get-credentials --resource-group $TTM_RG_NAME --name $TTM_AKS_CLUSTER1_NAME"

# kubectl get nodes

# clean up resources
echo "az group delete --name $RG_NAME"
