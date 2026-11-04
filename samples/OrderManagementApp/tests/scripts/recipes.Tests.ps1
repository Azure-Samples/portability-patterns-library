# Tests for scripts/lib/recipes.ps1 and the Recipe Packs that reference what it publishes.
# Run with: Invoke-Pester ./tests/scripts. Needs az with Bicep, which compiles the packs.

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/recipes.ps1')

    # The pack compiled to ARM JSON, as Radius receives it.
    function Get-CompiledPack([string]$Pack) {
        $output = az bicep build --file (Join-Path $LibraryRecipePackRoot $Pack) --stdout 2>&1
        if ($LASTEXITCODE -ne 0) { throw "az bicep build $Pack failed: $($output -join ' ')" }
        ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n" | ConvertFrom-Json
    }

    # The values an argument of a format() expression can take: the registry parameter stands for
    # itself, a variable for each value it can have. Anything else fails the test, so a change to
    # how the pack builds its sources can't pass unchecked.
    function Resolve-Argument($Template, [string]$Argument) {
        if ($Argument -match "^parameters\('(\w+)'\)$") { return @("<$($Matches[1])>") }
        if ($Argument -notmatch "^variables\('(\w+)'\)$") { throw "Unsupported format() argument: $Argument" }
        $value = $Template.variables.($Matches[1])
        if ($value -is [string] -and -not $value.StartsWith('[')) { return @($value) }
        if ($value -match "^\[if\([^,]+, '([^']*)', '([^']*)'\)\]$") { return @($Matches[1], $Matches[2]) }
        throw "Unsupported value of variable $($Argument): $value"
    }

    # Every value a Recipe source expression can take.
    function Resolve-Source($Template, [string]$Source) {
        if (-not $Source.StartsWith('[')) { return @($Source) }
        if ($Source -notmatch "^\[format\('([^']*)', (.+)\)\]$") { throw "Unsupported Recipe source: $Source" }
        $format = $Matches[1]
        $values = @(, @())
        foreach ($argument in ($Matches[2] -split ', (?=(?:parameters|variables)\()')) {
            $values = @(foreach ($prefix in $values) { foreach ($candidate in (Resolve-Argument $Template $argument)) { , ($prefix + $candidate) } })
        }
        foreach ($combination in $values) { $format -f $combination }
    }

    # The library Recipes a pack can use: recipes/<implementation>/<name>, in the registry it's given.
    function Get-PackRecipeReference([string]$Pack) {
        $template = Get-CompiledPack $Pack
        $packs = @($template.resources.PSObject.Properties.Value | Where-Object { $_.type -like 'Radius.Core/recipePacks@*' })
        if (-not $packs) { throw "$Pack declares no Radius.Core/recipePacks resource." }
        $sources = foreach ($recipe in $packs.properties.properties.recipes.PSObject.Properties.Value) {
            Resolve-Source $template $recipe.source
        }
        $sources | Where-Object { $_ -match '^<registry>/(recipes/[^:]+):' } | ForEach-Object { $Matches[1] } | Select-Object -Unique
    }

    $script:References = @{
        'azure.bicep'       = @(Get-PackRecipeReference 'azure.bicep')
        'azure-local.bicep' = @(Get-PackRecipeReference 'azure-local.bicep')
    }
}

Describe 'Get-LibraryRecipeRepository' {
    It 'publishes every Recipe to its own repository' {
        $repositories = Get-LibraryRecipe -Platform all | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $repositories | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name | Should -BeNullOrEmpty
    }

    It 'names the repository after the implementation folder and the file' {
        $recipe = Get-LibraryRecipe -Platform azure-local | Where-Object { $_.Directory.Name -eq 'rabbitmq' }
        Get-LibraryRecipeRepository $recipe | Should -Be 'recipes/rabbitmq/rabbitmq-queue'
    }
}

Describe 'Recipe Packs' {
    It '<Pack> references only Recipes that <Platform> publishes' -TestCases @(
        @{ Pack = 'azure.bicep'; Platform = 'azure' }
        @{ Pack = 'azure-local.bicep'; Platform = 'azure-local' }
    ) {
        $published = Get-LibraryRecipe -Platform $Platform | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $referenced = $script:References[$Pack]
        $referenced | Should -Not -BeNullOrEmpty
        $referenced | Where-Object { $_ -notin $published } | Should -BeNullOrEmpty
    }

    It 'azure-local.bicep uses every Azure Local Recipe' {
        $published = Get-LibraryRecipe -Platform azure-local | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $published | Where-Object { $_ -notin $script:References['azure-local.bicep'] } | Should -BeNullOrEmpty
    }
}
