# Shared by the setup and deploy scripts: native commands they check, and the parameter files and
# secrets they generate.

# $ErrorActionPreference does not apply to native commands, so every external call is checked.
# Returns what the command printed.
function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

# Writes an ARM-format parameter file for `az deployment` or `rad deploy`, whose
# `--parameters key=value` only handles strings: arrays, objects and booleans go through a file.
# It's owner-only, as New-TemporaryFile creates it, since it can carry passwords, and ends in .json.
# Returns its path; the caller deletes it.
function New-ParameterFile {
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    $parameters = @{}
    foreach ($key in $Values.Keys) {
        $parameters[$key] = @{ value = $Values[$key] }
    }

    $document = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }

    $file = New-TemporaryFile
    $path = "$($file.FullName).json"
    Move-Item $file $path
    # Without a BOM, which the az and rad CLIs reject.
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

# 24 random bytes as base64url, so the value survives being pasted into a URL or a header unescaped.
function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
