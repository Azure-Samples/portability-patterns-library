<#
.SYNOPSIS
    Compiles and publishes the Bicep Recipes to an OCI registry.

.DESCRIPTION
    Radius fetches Bicep Recipes from an OCI registry at deployment time. The pull is performed by
    the Radius control plane running inside the cluster, so the registry address must be resolvable
    *from the cluster*, not just from your workstation.

.PARAMETER Registry
    Registry host and path prefix, for example 'myregistry.azurecr.io' or
    'registry.bcd-registry.svc.cluster.local:5000'.

.PARAMETER Set
    Which Recipe set to publish: 'local', 'azure', 'aldo', 'azurelocal', 'kubernetes' or 'all'.

.EXAMPLE
    ./scripts/publish-recipes.ps1 -Registry registry.bcd-registry.svc.cluster.local:5000 -Set local -PlainHttp

.EXAMPLE
    ./scripts/publish-recipes.ps1 -Registry myregistry.azurecr.io -Set azure
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Registry,

    [ValidateSet('local', 'azure', 'aldo', 'azurelocal', 'kubernetes', 'all')]
    [string]$Set = 'all',

    [string]$Tag = 'latest',

    [switch]$PlainHttp
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# A single-element array returned from an `if` expression is unrolled to a scalar, which turns the
# later `+=` into string concatenation ('azure' + 'kubernetes' = 'azurekubernetes'). Building an
# explicit list avoids that.
$sets = [System.Collections.Generic.List[string]]::new()
if ($Set -eq 'all') {
    $sets.Add('local')
    $sets.Add('azure')
}
elseif ($Set -eq 'aldo' -or $Set -eq 'azurelocal') {
    # Azure Local disconnected operations has no Service Bus, Azure SQL or Blob Storage, so it uses
    # the same in-cluster container Recipes as the local environment. Connected Azure Local uses
    # them too, so the workload does not depend on the Azure link.
    $sets.Add('local')
}
else {
    $sets.Add($Set)
}

# The Kubernetes Recipes (containers and secrets) are shared. `containers` is a local build of the
# stock Recipe adding platformOptions support; `secrets` is the stock Recipe vendored so that
# air-gapped environments never have to mirror an OCI artifact. Both are needed wherever Radius
# deploys containers, so they accompany every set except a bare 'local' publish, which uses the
# copies already in the in-cluster registry.
if (($sets -contains 'azure' -or $Set -eq 'aldo' -or $Set -eq 'azurelocal' -or $Set -eq 'local' -or $Set -eq 'all') -and -not $sets.Contains('kubernetes')) {
    $sets.Add('kubernetes')
}

foreach ($setName in $sets) {
    $recipeDir = Join-Path $repoRoot "deploy/recipes/$setName"
    if (-not (Test-Path $recipeDir)) {
        throw "Recipe directory '$recipeDir' does not exist."
    }
    $recipes = Get-ChildItem -Path $recipeDir -Filter *.bicep

    foreach ($recipe in $recipes) {
        $target = "br:$Registry/bcd/recipes/$($recipe.BaseName):$Tag"
        Write-Host "Publishing $($recipe.Name) -> $target" -ForegroundColor Cyan

        $radArgs = @('bicep', 'publish', '--file', $recipe.FullName, '--target', $target)
        if ($PlainHttp) { $radArgs += '--plain-http' }

        & rad @radArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to publish $($recipe.Name)"
        }
    }
}

Write-Host "`nAll '$Set' Recipes published to $Registry" -ForegroundColor Green
