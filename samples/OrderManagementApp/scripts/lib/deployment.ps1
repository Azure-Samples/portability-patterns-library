# Native-command checks and parameter files for deployment lifecycle scripts.

function Invoke-OmsChecked {
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

function New-OmsParameterFile {
    param([Parameter(Mandatory)][hashtable]$Values)
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    $document = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) "oms-params-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::WriteAllText($path, '')
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite') }
    [IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $path
}
