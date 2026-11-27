# Shared by the scripts that read and write Kubernetes Secrets.

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

# Whether the ActiveDirectory step has already run against this cluster: it holds the bind account's
# password and, unless that step was told not to set up certificates, the directory's CA, so a run
# interrupted between writing the two is run again. A Secret that can't be read throws, as for
# Get-OmsSecretData: an unreachable cluster isn't one that needs the directory prepared, and that
# step changes the directory before it writes the Secrets.
function Test-OmsDirectoryPrepared {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [switch]$WithoutCertificate
    )

    if (-not (Get-OmsSecretValue -KubeContext $KubeContext -Namespace identity -Name oms-ad-bind -Key bind-password)) { return $false }
    $WithoutCertificate -or [bool](Get-OmsSecretValue -KubeContext $KubeContext -Namespace identity -Name oms-ad-ca -Key ca.crt)
}

# Creates or replaces a Secret, Opaque unless -Type says otherwise. The values go to kubectl on
# stdin, never on a command line.
function Set-OmsSecret {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Data,
        [string]$Type = 'Opaque',
        [hashtable]$Labels = @{}
    )

    $encoded = @{}
    foreach ($key in $Data.Keys) { $encoded[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Data[$key])) }
    $metadata = @{ name = $Name; namespace = $Namespace }
    if ($Labels.Count) { $metadata.labels = $Labels }
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        type       = $Type
        metadata   = $metadata
        data       = $encoded
    } | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Writing Secret '$Namespace/$Name' failed." }
}
