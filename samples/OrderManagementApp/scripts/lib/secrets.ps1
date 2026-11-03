# Shared by the scripts that handle credentials: Kubernetes Secrets, and local files that hold a
# credential while a command reads them. Works in Windows PowerShell 5.1 and PowerShell 7.

# Reads every key of a Secret as plain text. Returns an empty hashtable when the Secret doesn't
# exist; throws when it can't be read, so a caller never mistakes a failed read for a missing Secret
# and generates a replacement.
function Get-OmsSecretData {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $output = kubectl get secret $Name --namespace $Namespace --context $KubeContext --ignore-not-found --output json 2>&1
    $failed = $LASTEXITCODE -ne 0
    $errors = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($failed) { throw "Reading Secret '$Namespace/$Name' failed: $($errors -join ' ')" }

    $data = @{}
    $json = ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) { return $data }
    $values = ($json | ConvertFrom-Json).data
    if ($values) {
        foreach ($property in $values.PSObject.Properties) {
            $data[$property.Name] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($property.Value))
        }
    }
    return $data
}

# Reads one key of a Secret, or $null when the Secret or the key doesn't exist. Throws when the
# Secret can't be read.
function Get-OmsSecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Key
    )

    (Get-OmsSecretData -KubeContext $KubeContext -Namespace $Namespace -Name $Name)[$Key]
}

# Creates or replaces an Opaque Secret. The values go to kubectl on stdin, never on a command line.
function Set-OmsSecret {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Data
    )

    $encoded = @{}
    foreach ($key in $Data.Keys) { $encoded[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Data[$key])) }
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        type       = 'Opaque'
        metadata   = @{ name = $Name; namespace = $Namespace }
        data       = $encoded
    } | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Writing Secret '$Namespace/$Name' failed." }
}

# A Windows user profile, and so its temporary folder, is private already. On Linux and macOS the
# default umask leaves new files and folders readable by other users.
function Test-OmsPrivateByDefault { $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows }

# Creates a folder under the temporary directory that only the current user can open, for files that
# hold a credential while a command reads them. Delete it when done. On Linux and macOS it is created
# with owner-only access, so there is no moment when another user could read what goes in it.
function New-OmsPrivateDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) "oms-$([guid]::NewGuid().ToString('N'))"
    if (Test-OmsPrivateByDefault) { New-Item -ItemType Directory -Path $path | Out-Null }
    else { [IO.Directory]::CreateDirectory($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') | Out-Null }
    $path
}

# Writes a file that holds credentials so only the current user can read it. Its folder is made
# owner-only too, so put it in a folder of its own (New-OmsPrivateDirectory, or one such as ~/.kube)
# rather than a shared one.
function Write-OmsSecretFile([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    if (-not (Test-Path $Path)) { [IO.File]::WriteAllText($Path, '') }
    Protect-OmsSecretPath $Path
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

# Owner-only access to a credentials file and its folder.
function Protect-OmsSecretPath([string]$Path) {
    if (Test-OmsPrivateByDefault) { return }
    [IO.File]::SetUnixFileMode((Split-Path -Parent $Path), [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    if (Test-Path $Path) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite') }
}
