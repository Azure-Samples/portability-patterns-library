# Locates the library's shared Recipes, Recipe Packs and queue type at the repository root.

$LibraryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$LibraryRecipeRoot = Join-Path $LibraryRoot 'recipes'
$LibraryRecipePackRoot = Join-Path $LibraryRoot 'recipe-packs'
$QueueTypeFile = Join-Path $LibraryRecipeRoot 'message-queue/messageQueues.yaml'
# bicepconfig.json at the repository root maps the 'portability' extension to this file.
$QueueTypeExtension = Join-Path $LibraryRecipeRoot 'message-queue/messageQueues.tgz'

# Recipes are laid out as recipes/<capability>/<platform>/<implementation>/<name>.bicep. Recipes in
# recipes/kubernetes/ serve every platform.
function Get-LibraryRecipe {
    param([ValidateSet('azure', 'azure-local', 'all')][string]$Platform = 'all')

    $platforms = if ($Platform -eq 'all') { @('azure', 'azure-local', 'kubernetes') } else { @($Platform, 'kubernetes') }
    Get-ChildItem -Path $LibraryRecipeRoot -Filter *.bicep -Recurse |
        Where-Object { $_.Directory.Name -eq 'kubernetes' -or $platforms -contains $_.Directory.Parent.Name }
}