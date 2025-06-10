#**********************************************************
#
# Script to remove all resources restored in recovery plan
#
#**********************************************************

$WarningPreference = 'SilentlyContinue'

Disconnect-AzAccount

# Define your credentials
$clientId = ""   # App ID
$clientSecret = ""
$tenantId = ""

# Convert password to a secure string
$securePassword = ConvertTo-SecureString $clientSecret -AsPlainText -Force
$psCredential = New-Object System.Management.Automation.PSCredential($clientId, $securePassword)

# Connect to Azure using the service principal
Connect-AzAccount -TenantId $tenantId -ServicePrincipal -Credential $psCredential 

Update-AzConfig -DisplayBreakingChangeWarning $false

# Set the name of the resource group
$resourceGroupName = "<Resource Group Name"

# Get all resources in the specified resource group

Write-Host "Deleting all resources in resource group: $ResourceGroupName"

# Remove resource locks
$locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
foreach ($lock in $locks) {
    Write-Host "Removing lock '$($lock.Name)' from resource '$($lock.ResourceName)'..."
    Remove-AzResourceLock -LockId $lock.LockId -Force
}

# Step-by-step deletion
try {
    $vms = Get-AzVM -ResourceGroupName $ResourceGroupName
    foreach ($vm in $vms) {
        Write-Host "Deleting VM '$($vm.Name)'..."
        Remove-AzResource -ResourceId $vm.Id -Force
    }
} catch { Write-Warning "Error deleting VMs: $_" }

Start-Sleep -Seconds 180 # Delay required to delete NIC without issue

try {
    $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName
    foreach ($nic in $nics) {
        Write-Host "Deleting NIC '$($nic.Name)'..."
        Remove-AzResource -ResourceId $nic.Id -Force
    }
} catch { Write-Warning "Error deleting NICs: $_" }

try {
    $publicIps = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName
    foreach ($ip in $publicIps) {
        Write-Host "Deleting Public IP '$($ip.Name)'..."
        Remove-AzResource -ResourceId $ip.Id -Force
    }
} catch { Write-Warning "Error deleting Public IPs: $_" }

try {
    $disks = Get-AzDisk -ResourceGroupName $ResourceGroupName
    foreach ($disk in $disks) {
        Write-Host "Deleting Disk '$($disk.Name)'..."
       Remove-AzResource -ResourceId $disk.Id -Force
    }
} catch { Write-Warning "Error deleting Disks: $_" }

try {
    $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName
    foreach ($nsg in $nsgs) {
        Write-Host "Deleting NSG '$($nsg.Name)'..."
        Remove-AzResource -ResourceId $nsg.Id -Force
    }
} catch { Write-Warning "Error deleting NSGs: $_" }

try {
    $routes = Get-AzRouteTable -ResourceGroupName $ResourceGroupName
    foreach ($route in $routes) {
        Write-Host "Deleting Route Table '$($route.Name)'..."
        Remove-AzResource -ResourceId $route.Id -Force
    }
} catch { Write-Warning "Error deleting Route Tables: $_" }

try {
    $lbs = Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName
    foreach ($lb in $lbs) {
        Write-Host "Deleting Load Balancer '$($lb.Name)'..."
        Remove-AzResource -ResourceId $lb.Id -Force
    }
} catch { Write-Warning "Error deleting Load Balancers: $_" }

try {
    $appGws = Get-AzApplicationGateway -ResourceGroupName $ResourceGroupName
    foreach ($ag in $appGws) {
        Write-Host "Deleting Application Gateway '$($ag.Name)'..."
        Remove-AzResource -ResourceId $ag.Id -Force
    }
} catch { Write-Warning "Error deleting Application Gateways: $_" }

try {
    $vnets = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName
    foreach ($vnet in $vnets) {
        Write-Host "Deleting VNet '$($vnet.Name)'..."
       Remove-AzResource -ResourceId $vnet.Id -Force
    }
} catch { Write-Warning "Error deleting VNets: $_" }

try {
    $storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
    foreach ($sa in $storageAccounts) {
        Write-Host "Deleting Storage Account '$($sa.StorageAccountName)'..."
       Remove-AzResource -ResourceId $sa.Id -Force
    }
} catch { Write-Warning "Error deleting Storage Accounts: $_" }

# Catch-all: Delete remaining resources
try {
    $remaining = Get-AzResource -ResourceGroupName $ResourceGroupName
    foreach ($res in $remaining) {
        Write-Host "Deleting remaining resource '$($res.Name)' of type '$($res.ResourceType)'..."
        Remove-AzResource -ResourceId $res.ResourceId -Force
    }
} catch { Write-Warning "Error deleting remaining resources: $_" }

Write-Host "All deletions attempted for resource group '$ResourceGroupName'."

Disconnect-AzAccount