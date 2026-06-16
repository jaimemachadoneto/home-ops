# migration-win-network.ps1
# Adds or removes the temporary 10.30.4.100/16 address on your NIC connected
# to the Services VLAN. This lets WSL2 reach Talos nodes at their old IPs
# (10.30.4.x) via L2 during the network migration.
#
# Run as Administrator.
#
# Usage:
#   .\migration-win-network.ps1 -Action Add
#   .\migration-win-network.ps1 -Action Remove
#   .\migration-win-network.ps1 -Action Add -InterfaceAlias "Ethernet 2"

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Add", "Remove")]
    [string]$Action,

    [string]$InterfaceAlias = "Wi-Fi"
)

$TempIP       = "10.30.4.100"
$PrefixLength = 16

# If no interface supplied, list connected ones and prompt
if (-not $InterfaceAlias) {
    Write-Host ""
    Write-Host "Connected network adapters:"
    Write-Host ""
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        $ip = Get-NetIPAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Select-Object -First 1
        $ipStr = if ($ip) { "$($ip.IPAddress)/$($ip.PrefixLength)" } else { "(no IPv4)" }
        Write-Host ("  [{0,2}] {1,-35} {2}" -f $_.ifIndex, $_.Name, $ipStr)
    }
    Write-Host ""
    $InterfaceAlias = Read-Host "Enter the adapter name for your VLAN 50 NIC (e.g. Ethernet 2)"
}

if ($Action -eq "Add") {
    Write-Host ""
    Write-Host "Adding $TempIP/$PrefixLength to '$InterfaceAlias'..."

    $existing = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $TempIP -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Address $TempIP already present on '$InterfaceAlias' - nothing to do."
    } else {
        try {
            New-NetIPAddress -InterfaceAlias $InterfaceAlias `
                             -IPAddress $TempIP `
                             -PrefixLength $PrefixLength `
                             -ErrorAction Stop | Out-Null
            Write-Host "Done."
            Write-Host ""
            Write-Host "You can now reach the Talos nodes at their old IPs from WSL2."
            Write-Host "Test with: ping 10.30.4.1"
        } catch {
            Write-Host "Failed: $_"
            exit 1
        }
    }
} else {
    Write-Host ""
    Write-Host "Removing $TempIP from '$InterfaceAlias'..."
    try {
        Remove-NetIPAddress -InterfaceAlias $InterfaceAlias `
                            -IPAddress $TempIP `
                            -Confirm:$false `
                            -ErrorAction Stop
        Write-Host "Done. Temporary address removed."
    } catch {
        Write-Host "Address not found or already removed."
    }
}
