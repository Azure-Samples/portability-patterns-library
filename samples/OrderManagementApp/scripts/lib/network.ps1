# Checks the AKS platform's address ranges before they're deployed: they can't change afterwards.

# Whether two IPv4 CIDR ranges share any address.
function Test-OmsCidrOverlap([string]$A, [string]$B) {
    $ranges = foreach ($cidr in $A, $B) {
        $address, $length = $cidr.Split('/')
        $bytes = ([System.Net.IPAddress]::Parse($address)).GetAddressBytes()
        [Array]::Reverse($bytes)
        $start = [uint64][BitConverter]::ToUInt32($bytes, 0)
        $size = [uint64][Math]::Pow(2, 32 - [int]$length)
        $start = $start - ($start % $size)
        , @($start, ($start + $size - 1))
    }
    $ranges[0][0] -le $ranges[1][1] -and $ranges[1][0] -le $ranges[0][1]
}

# Throws when the virtual network, pod and service ranges overlap each other or the hub's address
# space. A hub that overlaps podCidr or serviceCidr still peers, but pods can't reach those of its
# addresses: inside the cluster they belong to pods and services.
function Assert-OmsAddressRanges {
    param(
        [Parameter(Mandatory = $true)][string]$VirtualNetworkAddressPrefix,
        [Parameter(Mandatory = $true)][string]$PodCidr,
        [Parameter(Mandatory = $true)][string]$ServiceCidr,
        [string]$HubVirtualNetworkId
    )

    $ranges = [ordered]@{
        'the virtual network' = $VirtualNetworkAddressPrefix
        'podCidr'             = $PodCidr
        'serviceCidr'         = $ServiceCidr
    }
    $names = @($ranges.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            if (Test-OmsCidrOverlap $ranges[$names[$i]] $ranges[$names[$j]]) {
                throw "$($names[$i]) ($($ranges[$names[$i]])) overlaps $($names[$j]) ($($ranges[$names[$j]])). Choose ranges that don't overlap."
            }
        }
    }

    if (-not $HubVirtualNetworkId) { return }
    $hubPrefixes = az network vnet show --ids $HubVirtualNetworkId --query 'addressSpace.addressPrefixes' --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Can't read hub virtual network '$HubVirtualNetworkId'." }
    foreach ($hubPrefix in $hubPrefixes) {
        foreach ($name in $names) {
            if (Test-OmsCidrOverlap $hubPrefix $ranges[$name]) {
                throw "The hub's address space $hubPrefix overlaps $name ($($ranges[$name])). Change $name, or peer with a hub that doesn't use it."
            }
        }
    }
}
