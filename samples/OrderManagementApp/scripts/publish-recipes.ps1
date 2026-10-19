<#
.SYNOPSIS
    Compiles and publishes the Bicep Recipes to an OCI registry.

.DESCRIPTION
    Radius fetches Bicep Recipes from an OCI registry at deployment time. The pull is performed by
    the Radius control plane running inside the cluster, so the registry address must be resolvable
    *from the cluster*, not just from your workstation.

.PARAMETER Registry
    Registry host and path prefix, for example 'myregistry.azurecr.io'.

.PARAMETER Set
    Which Recipe set to publish: 'azure', 'azurelocal' or 'all'. The shared Kubernetes Recipes
    (deploy/recipes/kubernetes) are always published with it.

.EXAMPLE
    ./scripts/publish-recipes.ps1 -Registry myregistry.azurecr.io -Set azure
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Registry,

    [ValidateSet('azure', 'azurelocal', 'all')]
    [string]$Set = 'all',

    [string]$Tag = 'latest',

    [switch]$PlainHttp
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# `containers` is a local build of the stock Recipe adding platformOptions support; `secrets` is the
# stock Recipe vendored so that no environment has to mirror an extra OCI artifact. Both are needed
# wherever Radius deploys containers, so they accompany every set.
$sets = if ($Set -eq 'all') { @('azure', 'azurelocal', 'kubernetes') } else { @($Set, 'kubernetes') }

foreach ($setName in $sets) {
    $recipeDir = Join-Path $repoRoot "deploy/recipes/$setName"
    if (-not (Test-Path $recipeDir)) {
        throw "Recipe directory '$recipeDir' does not exist."
    }
    $recipes = Get-ChildItem -Path $recipeDir -Filter *.bicep

    foreach ($recipe in $recipes) {
        $target = "br:$Registry/oms/recipes/$($recipe.BaseName):$Tag"
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
