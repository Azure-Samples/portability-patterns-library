# Shared by the scripts that read Azure resources with az.

# Runs an az command that reads one resource ('show' and the like), given as an array of arguments,
# and returns what it printed, or $null when az reports that the resource doesn't exist (exit code
# 3). Throws on any other failure, so an expired sign-in, throttling or a network error is never
# mistaken for a missing resource.
function Invoke-OmsAzShow {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 3) { return $null }
    if ($exitCode -ne 0) {
        $errors = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
        throw "az $($Arguments[0..1] -join ' ') failed with exit code ${exitCode}: $($errors -join ' ')"
    }
    (@($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
}

# The Kubernetes version an AKS Arc cluster gets, and why. A version given in the settings is used
# as is; it is how an existing cluster is upgraded. Otherwise an existing cluster keeps the version
# it runs, so re-running setup never upgrades it, and a new one gets the newest generally available
# version the Azure Local instance offers for Linux nodes. Throws when the instance offers none.
function Resolve-OmsKubernetesVersion {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][string]$CustomLocationId,
        [string]$KubernetesVersion
    )

    $offered = Invoke-OmsAzShow @('rest', '--method', 'get', '--url',
        "https://management.azure.com$CustomLocationId/providers/Microsoft.HybridContainerService/kubernetesVersions/default?api-version=2024-01-01",
        '--output', 'json') | ConvertFrom-Json
    $ready = @(foreach ($minor in @($offered.properties.values | Where-Object { -not $_.isPreview })) {
            foreach ($patch in $minor.patchVersions.PSObject.Properties) {
                if ($patch.Value.readiness | Where-Object { $_.osType -eq 'Linux' -and $_.ready }) { $patch.Name }
            }
        })

    $cluster = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$ClusterName"
    $current = Invoke-OmsAzShow @('resource', 'show', '--ids', "$cluster/providers/Microsoft.HybridContainerService/provisionedClusterInstances/default",
        '--api-version', '2024-01-01', '--query', 'properties.kubernetesVersion', '--output', 'tsv')

    if (-not [string]::IsNullOrWhiteSpace($KubernetesVersion)) {
        # The version a cluster already runs is always fine, even once the instance stops offering it.
        return [pscustomobject]@{ Version = $KubernetesVersion; Reason = 'from the settings'; Offered = $KubernetesVersion -in $ready -or $KubernetesVersion -eq $current; Ready = $ready }
    }
    if ($current) {
        return [pscustomobject]@{ Version = $current; Reason = 'the version the cluster runs'; Offered = $true; Ready = $ready }
    }

    if (-not $ready) { throw "The Azure Local instance offers no generally available Kubernetes version for Linux nodes ($CustomLocationId)." }
    $newest = $ready | Sort-Object { [version]$_ } | Select-Object -Last 1
    [pscustomobject]@{ Version = $newest; Reason = 'the newest the instance offers'; Offered = $true; Ready = $ready }
}
