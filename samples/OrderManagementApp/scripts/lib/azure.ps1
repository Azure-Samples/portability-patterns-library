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
