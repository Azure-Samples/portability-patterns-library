# Tests for scripts/lib/recipes.ps1 and the Recipe Packs that reference what it publishes.
# Run with: Invoke-Pester ./tests/scripts

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/recipes.ps1')

    # The Recipe paths a pack names: recipes/<implementation>/<name>, written out in a source, or in a
    # variable named *Recipe that a source uses.
    function Get-PackRecipeReference([string]$Pack) {
        $text = Get-Content (Join-Path $LibraryRecipePackRoot $Pack) -Raw
        $literal = [regex]::Matches($text, "/recipes/([a-z0-9-]+/[a-z0-9-]+):") | ForEach-Object { "recipes/$($_.Groups[1].Value)" }
        $variable = [regex]::Matches($text, "(?m)^var \w+Recipe = .*$") |
            ForEach-Object { [regex]::Matches($_.Value, "'([a-z0-9-]+/[a-z0-9-]+)'") } |
            ForEach-Object { "recipes/$($_.Groups[1].Value)" }
        @($literal) + @($variable) | Select-Object -Unique
    }
}

Describe 'Get-LibraryRecipeRepository' {
    It 'publishes every Recipe to its own repository' {
        $repositories = Get-LibraryRecipe -Platform all | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $repositories | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name | Should -BeNullOrEmpty
    }

    It 'names the repository after the implementation folder and the file' {
        $recipe = Get-LibraryRecipe -Platform azure-local | Where-Object { $_.Directory.Name -eq 'rabbitmq-statefulset' }
        Get-LibraryRecipeRepository $recipe | Should -Be 'recipes/rabbitmq-statefulset/rabbitmq-queue'
    }
}

Describe 'Recipe Packs' {
    It '<Pack> references only Recipes that <Platform> publishes' -TestCases @(
        @{ Pack = 'azure.bicep'; Platform = 'azure' }
        @{ Pack = 'azure-local.bicep'; Platform = 'azure-local' }
    ) {
        $published = Get-LibraryRecipe -Platform $Platform | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $referenced = Get-PackRecipeReference $Pack
        $referenced | Should -Not -BeNullOrEmpty
        $referenced | Where-Object { $_ -notin $published } | Should -BeNullOrEmpty
    }

    It 'azure-local.bicep uses every Azure Local Recipe' {
        $published = Get-LibraryRecipe -Platform azure-local | ForEach-Object { Get-LibraryRecipeRepository $_ }
        $referenced = Get-PackRecipeReference 'azure-local.bicep'
        $published | Where-Object { $_ -notin $referenced } | Should -BeNullOrEmpty
    }
}
