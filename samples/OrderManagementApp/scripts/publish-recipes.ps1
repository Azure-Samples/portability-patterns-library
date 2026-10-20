<#
.SYNOPSIS
    Compiles and publishes the library's Bicep Recipes to an OCI registry.

.DESCRIPTION
    Radius fetches Bicep Recipes from an OCI registry at deployment time. The pull is performed by
    the Radius control plane running inside the cluster, so the registry address must be resolvable
    *from the cluster*, not just from your workstation.

    Recipes live at the repository root in recipes/<capability>/<platform>/<implementation>/. Each
    is published as <Registry>/recipes/<file name>:<Tag>, which is what the Recipe Packs in
    recipe-packs/ reference.

.PARAMETER Registry
    Registry host, for example 'myregistry.azurecr.io'.

.PARAMETER Platform
    Which platform's Recipes to publish: 'azure', 'azure-local' or 'all'. The shared Kubernetes
    Recipes (recipes/kubernetes) are always published with it.

.EXAMPLE
    ./scripts/publish-recipes.ps1 -Registry myregistry.azurecr.io -Platform azure
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Registry,

    [ValidateSet('azure', 'azure-local', 'all')]
    [string]$Platform = 'all',

    [string]$Tag = 'latest',

    [switch]$PlainHttp
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/recipes.ps1')
$recipes = Get-LibraryRecipe -Platform $Platform
if (-not $recipes) { throw "No Recipes found for platform '$Platform' under $LibraryRecipeRoot." }

foreach ($recipe in $recipes) {
    $target = "br:$Registry/recipes/$($recipe.BaseName):$Tag"
    Write-Host "Publishing $($recipe.Name) -> $target" -ForegroundColor Cyan

    $radArgs = @('bicep', 'publish', '--file', $recipe.FullName, '--target', $target)
    if ($PlainHttp) { $radArgs += '--plain-http' }

    & rad @radArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to publish $($recipe.Name)"
    }
}

Write-Host "`nAll '$Platform' Recipes published to $Registry" -ForegroundColor Green