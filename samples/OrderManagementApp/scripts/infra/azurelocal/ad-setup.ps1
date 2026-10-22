<#
.SYNOPSIS
    Prepares the Azure Local site's existing Active Directory domain controller as the identity
    source for Keycloak.

.DESCRIPTION
    On AKS a workload proves who it is with a federated managed identity, which only works while
    Entra is reachable. An Azure Local site has to keep working when the link to Azure is down, so
    the directory has to live inside the site. The Active Directory domain that the Azure Local
    instance is already joined to fills that role: it keeps serving its own tickets and LDAP binds
    with no connectivity to anything outside.

    The script targets that existing domain controller and adds only what the sample needs:
      * AD Certificate Services, if no certificate authority is installed yet, so the controller
        enrols a server certificate and LDAPS works on 636. An existing CA is reused.
      * The OMS OU, the oms-app-readers / oms-app-writers groups, the Keycloak bind account and a
        sample user in both groups.
      * Two Kubernetes Secrets in the cluster: the bind and sample-user credentials, and the CA
        root certificate for Keycloak to trust LDAPS.
      * Kerberos for SQL: a service account for SQL Server with its service principal names, an
        account for the application, their keytabs as Kubernetes Secrets and krb5.conf as a
        ConfigMap in the application namespace. The application then signs in to the SQL Server
        container as its own AD account, without a SQL password. SQL Server on Linux also needs
        reverse DNS for the domain controllers, so a PTR record is added for each one that lacks it.

    The controller's network settings and DNS forwarders are left untouched and the directory
    service is not restarted: LDAP is told to reload its certificate instead.

    Everything runs over PowerShell Direct, so run it on the Hyper-V host that runs the domain
    controller VM. If your controller is elsewhere, make the same objects with the Active Directory
    PowerShell module instead; the sample README lists them under "Connect your Active Directory".

    The script is safe to re-run. Re-running resets the passwords of the accounts it manages and
    rewrites the Secrets. Use -KerberosOnly to redo only the SQL Kerberos part, which leaves the
    Keycloak bind account untouched.

.PARAMETER DomainAdminCredential
    Domain administrator of the controller's domain. Prompted for when omitted.

.PARAMETER SkipBindSecret
    Do not write the bind credential and CA certificate into Kubernetes Secrets. By default they
    are written to the cluster so that scripts/infra/azurelocal/keycloak.ps1 can pick them up without the
    passwords being typed or displayed.

.PARAMETER KerberosOnly
    Only create the SQL Kerberos accounts, keytabs and krb5.conf. Skips the certificate authority, the
    Keycloak bind account and the sample user, so Keycloak keeps working without being reconfigured.

.PARAMETER SqlResourceName
    Name of the application's Radius.Data/sqlServerDatabases resource. With Kerberos, the SQL Recipe
    names the database Service after it, so the service principal names are
    MSSQLSvc/<SqlResourceName>.<AppNamespace>.svc.cluster.local[:1433].

.EXAMPLE
    # Elevated, on the Hyper-V host that runs the domain controller VM.
    ./scripts/infra/azurelocal/ad-setup.ps1 -VmName DC01 -DomainName azurelocal.lab -NetbiosName AZURELOCAL `
        -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$VmName = 'DC01',
    [string]$DomainName = 'azurelocal.lab',
    [string]$NetbiosName = 'AZURELOCAL',
    [string]$OuName = 'OMS',

    [pscredential]$DomainAdminCredential,

    [string]$BindAccountName = 'svc-keycloak',
    [string]$DemoUserName = 'oms-demo',

    [switch]$SkipBindSecret,
    [switch]$SkipCertificateAuthority,
    # Only used when the controller has no certificate authority yet.
    [string]$CaCommonName = 'OMS Lab Root CA',
    [string]$KubeContext = 'bcd-aksarc',
    [string]$SecretNamespace = 'identity',
    [string]$SecretName = 'oms-ad-bind',
    [string]$CaSecretName = 'oms-ad-ca',

    # SQL Kerberos: accounts, and where their keytabs and krb5.conf are published.
    [switch]$KerberosOnly,
    [switch]$SkipKerberos,
    [string]$SqlServiceAccountName = 'svc-oms-sql',
    [string]$AppServiceAccountName = 'svc-oms-app',
    [string]$AppNamespace = 'oms-azurelocal',
    [string]$SqlResourceName = 'ordersdb',
    [string]$KerberosConfigMapName = 'oms-krb5',
    [string]$SqlKeytabSecretName = 'oms-sql-kerberos',
    [string]$AppKeytabSecretName = 'oms-app-kerberos'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Push-Location $repoRoot

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Meets the default domain policy on its own, rather than relying on a random draw to include
# every character class.
function New-DirectoryPassword {
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_'
    )

    $chars = foreach ($set in $sets) {
        $set[(Get-Random -Maximum $set.Length)]
    }
    $all = -join $sets
    $chars += 1..16 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }

    return -join ($chars | Sort-Object { Get-Random })
}

# RFC 3962: key = DK(PBKDF2-HMAC-SHA1(password, salt), "kerberos"), where DK encrypts the 128-bit
# n-fold of "kerberos" with AES and chains blocks until the key length is reached. Deriving keys
# here, rather than with ktpass, gives every service principal name the account's own salt.
function Get-KerberosAesKey {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Salt,
        [ValidateSet(16, 32)][int]$KeyLength = 32,
        [int]$Iterations = 4096
    )

    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        [Text.Encoding]::UTF8.GetBytes($Password), [Text.Encoding]::UTF8.GetBytes($Salt), $Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA1)
    $baseKey = $kdf.GetBytes($KeyLength)
    $kdf.Dispose()

    # ECB on single blocks through a transform works on Windows PowerShell 5.1 as well as 7.
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.Key = $baseKey
    $encryptor = $aes.CreateEncryptor()
    $block = [byte[]](0x6b, 0x65, 0x72, 0x62, 0x65, 0x72, 0x6f, 0x73, 0x7b, 0x9b, 0x5b, 0x2b, 0x93, 0x13, 0x2b, 0x93)
    $key = [System.Collections.Generic.List[byte]]::new()
    while ($key.Count -lt $KeyLength) {
        $block = $encryptor.TransformFinalBlock($block, 0, $block.Length)
        $key.AddRange($block)
    }
    $encryptor.Dispose()
    $aes.Dispose()
    return [byte[]]$key.GetRange(0, $KeyLength).ToArray()
}

# MIT keytab format 0x0502: one entry per principal and encryption type, every integer big-endian.
function New-Keytab {
    param(
        [Parameter(Mandatory = $true)][string]$Realm,
        [Parameter(Mandatory = $true)][string[][]]$Principals,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Salt,
        [Parameter(Mandatory = $true)][int]$Kvno
    )

    $keys = @(
        @{ EncType = 18; Key = Get-KerberosAesKey -Password $Password -Salt $Salt -KeyLength 32 }
        @{ EncType = 17; Key = Get-KerberosAesKey -Password $Password -Salt $Salt -KeyLength 16 }
    )

    $out = [System.IO.MemoryStream]::new()
    $out.Write([byte[]](0x05, 0x02), 0, 2)
    foreach ($components in $Principals) {
        foreach ($k in $keys) {
            $entry = [System.IO.MemoryStream]::new()
            $w = {
                param([byte[]]$bytes)
                $entry.Write($bytes, 0, $bytes.Length)
            }
            $u16 = { param([int]$v) [byte[]]((($v -shr 8) -band 0xff), ($v -band 0xff)) }
            $u32 = { param([long]$v) [byte[]]((($v -shr 24) -band 0xff), (($v -shr 16) -band 0xff), (($v -shr 8) -band 0xff), ($v -band 0xff)) }
            $str = { param([string]$s) $b = [Text.Encoding]::UTF8.GetBytes($s); (& $u16 $b.Length) + $b }

            & $w (& $u16 $components.Length)
            & $w (& $str $Realm)
            foreach ($c in $components) { & $w (& $str $c) }
            & $w (& $u32 1)
            & $w (& $u32 ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
            & $w ([byte[]]($Kvno -band 0xff))
            & $w (& $u16 $k.EncType)
            & $w (& $u16 $k.Key.Length)
            & $w $k.Key
            & $w (& $u32 $Kvno)

            $body = $entry.ToArray()
            $len = & $u32 $body.Length
            $out.Write($len, 0, 4)
            $out.Write($body, 0, $body.Length)
            $entry.Dispose()
        }
    }
    return $out.ToArray()
}

# Promotion only rejects a weak restore-mode password after the role install has already run, so
# the same rules are applied up front: three of the four character classes, and long enough to
# satisfy any sensible policy.
# PowerShell Direct answers only once the guest has booted far enough to run the VM management
# service, which is well after the VM reports 'Running'. Returns $null on success, otherwise the
# failure message, because a rejected password and an unbooted guest are otherwise indistinguishable.
function Test-GuestCredential {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    try {
        $null = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop `
            -ScriptBlock { $env:COMPUTERNAME }
        return $null
    }
    catch { return $_.Exception.Message }
}

# Accepts several candidate credentials because promotion swaps the local account for a domain
# one, and returns whichever the guest accepted.
function Wait-GuestReady {
    param(
        [Parameter(Mandatory = $true)][pscredential[]]$Credential,
        [int]$TimeoutMinutes = 20,
        [string]$What = 'guest'
    )

    # The guest can briefly reject a correct password while LSA starts, so allow a short grace
    # period before concluding the password is actually wrong rather than waiting out the timeout.
    $invalidCredentialGrace = 6
    $invalidCredentialCount = 0
    $lastError = $null

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $allInvalid = $true
        foreach ($candidate in $Credential) {
            $lastError = Test-GuestCredential -Credential $candidate
            if (-not $lastError) { return $candidate }
            if ($lastError -notmatch 'credential is invalid') { $allInvalid = $false }
        }

        if ($allInvalid) {
            $invalidCredentialCount++
            if ($invalidCredentialCount -ge $invalidCredentialGrace) {
                throw @"
'$VmName' rejected the password for '$($Credential.UserName -join "', '")'.
The guest is reachable over PowerShell Direct, so this is the password, not the VM.
Confirm it by unlocking the console, then re-run:
  vmconnect.exe localhost $VmName
"@
            }
        }

        Start-Sleep -Seconds 10
    }

    throw "Timed out waiting $TimeoutMinutes minutes for $What on '$VmName'. Last error: $lastError"
}

function Invoke-Guest {
    param(
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $ScriptBlock `
        -ArgumentList $ArgumentList
}


try {
    if (-not (Test-Elevated)) {
        throw 'Hyper-V and PowerShell Direct both need an elevated session. Re-run as Administrator.'
    }

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "The Hyper-V PowerShell module is not available. Enable the 'Microsoft-Hyper-V-Management-PowerShell' feature."
    }

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "No VM named '$VmName' on this host. Run this on the Hyper-V host that runs the domain controller."
    }
    if ($vm.State -ne 'Running') {
        throw "'$VmName' is $($vm.State). Start the domain controller first."
    }

    if (-not $DomainAdminCredential) {
        $DomainAdminCredential = Get-Credential -UserName "$NetbiosName\Administrator" `
            -Message "Domain administrator of '$DomainName' on '$VmName'"
    }
    $domainCredential = $DomainAdminCredential

    Write-Host "==> Waiting for PowerShell Direct on '$VmName'" -ForegroundColor Cyan
    $null = Wait-GuestReady -Credential $domainCredential -TimeoutMinutes 5 -What 'the domain administrator account'

    # NTLM falls back to the local SAM when the domain prefix does not resolve, so a credential
    # being accepted says nothing about the machine's role; the guest's own answer is authoritative.
    $domainRole = [int](Invoke-Guest -Credential $domainCredential -ScriptBlock {
            (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
        })
    if ($domainRole -lt 4) {
        throw "'$VmName' is not a domain controller (DomainRole $domainRole)."
    }

    Write-Host "==> Waiting for the directory to accept requests" -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        $ready = Invoke-Guest -Credential $domainCredential -ScriptBlock {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $null = Get-ADDomain -ErrorAction Stop
                $true
            }
            catch { $false }
        }
        if ($ready) { break }
        if ((Get-Date) -gt $deadline) { throw 'The directory never began answering.' }
        Start-Sleep -Seconds 15
    }

    # A domain controller only opens LDAPS once it holds a certificate with the Server
    # Authentication EKU. An Enterprise CA publishes the DC templates into AD, and the controller
    # auto-enrols against them, so standing one up is what turns port 636 from a socket that
    # accepts and drops into a working TLS endpoint.
    $caCertPem = $null
    if (-not $SkipCertificateAuthority -and -not $KerberosOnly) {
        Write-Host "==> Ensuring an enterprise certificate authority" -ForegroundColor Cyan
        $caCertPem = Invoke-Guest -Credential $domainCredential -ArgumentList $CaCommonName -ScriptBlock {
            param($caName)
            $ErrorActionPreference = 'Stop'

            # A controller already serving other systems may have its own CA. Reuse it rather than
            # stacking a second one, and look its root up by the name it was actually given.
            $activeCa = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue).Active
            if ($activeCa) {
                $caName = $activeCa
            }
            else {
                Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null

                Import-Module ADCSDeployment
                try {
                    Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName $caName `
                        -KeyLength 2048 -HashAlgorithmName SHA256 `
                        -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
                }
                catch [Microsoft.CertificateServices.Deployment.Common.CA.CertificationAuthoritySetupException] {
                    # Already configured; a re-run should not start over.
                }
            }

            # Auto-enrolment is on a timer, so nudge it rather than waiting for the next cycle.
            certutil -pulse | Out-Null

            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-Date) -lt $deadline) {
                $dcCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' }
                if ($dcCert) { break }
                Start-Sleep -Seconds 15
                certutil -pulse | Out-Null
            }
            if (-not $dcCert) { throw 'The controller never enrolled a server authentication certificate.' }

            # The controller serves other systems, so the directory is not restarted: the rootDSE
            # 'renewServerCertificate' operation tells LDAP to reload its certificate in place.
            $rootDse = [System.DirectoryServices.DirectoryEntry]::new('LDAP://localhost/RootDSE')
            $rootDse.Properties['renewServerCertificate'].Value = 1
            $rootDse.CommitChanges()
            $rootDse.Dispose()

            $root = Get-ChildItem Cert:\LocalMachine\Root |
                Where-Object { $_.Subject -like "CN=$caName*" } | Select-Object -First 1
            if (-not $root) { throw "The root certificate for '$caName' is not in the local store." }

            $b64 = [Convert]::ToBase64String($root.RawData, 'InsertLineBreaks')
            "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----"
        }

        Write-Host '    certificate authority ready; LDAPS available on 636' -ForegroundColor DarkGray
    }

    if (-not $SkipKerberos) {
        # SQL Server is reached as <resource>.<namespace>.svc.cluster.local, which is what the client
        # asks a ticket for, so that is the host the service principal names carry.
        $sqlHost = "$SqlResourceName.$AppNamespace.svc.cluster.local".ToLowerInvariant()
        $sqlPassword = New-DirectoryPassword
        $appPassword = New-DirectoryPassword

        Write-Host "==> Creating the SQL Kerberos accounts" -ForegroundColor Cyan
        $kerberos = Invoke-Guest -Credential $domainCredential -ScriptBlock {
            param($ouName, $sqlName, $sqlPw, $appName, $appPw, $sqlHost)
            $ErrorActionPreference = 'Stop'
            Import-Module ActiveDirectory

            $domain = Get-ADDomain
            $ouPath = "OU=$ouName,$($domain.DistinguishedName)"
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName `
                    -ProtectedFromAccidentalDeletion $true
            }

            $spns = @("MSSQLSvc/${sqlHost}:1433", "MSSQLSvc/$sqlHost")
            foreach ($spn in $spns) {
                $holder = Get-ADObject -LDAPFilter "(servicePrincipalName=$spn)" -Properties sAMAccountName
                if ($holder -and $holder.sAMAccountName -ne $sqlName) {
                    throw "$spn is already registered on $($holder.sAMAccountName)."
                }
            }

            $accounts = [ordered]@{
                $sqlName = @{ Password = $sqlPw; Description = 'SQL Server service account for Kerberos' }
                $appName = @{ Password = $appPw; Description = 'Application account that signs in to SQL Server' }
            }
            foreach ($name in $accounts.Keys) {
                $secure = ConvertTo-SecureString $accounts[$name].Password -AsPlainText -Force
                if (Get-ADUser -Filter "SamAccountName -eq '$name'" -ErrorAction SilentlyContinue) {
                    Set-ADAccountPassword -Identity $name -NewPassword $secure -Reset
                }
                else {
                    New-ADUser -Name $name -SamAccountName $name -UserPrincipalName "$name@$($domain.DNSRoot)" `
                        -Path $ouPath -AccountPassword $secure -PasswordNeverExpires $true `
                        -CannotChangePassword $true -Enabled $true -Description $accounts[$name].Description
                }
                # The keytabs carry AES keys only, so the KDC must not issue RC4 tickets.
                Set-ADUser -Identity $name -KerberosEncryptionType AES128, AES256
            }
            Set-ADUser -Identity $sqlName -ServicePrincipalNames @{ Replace = $spns }

            # SQL Server on Linux resolves each domain controller's address back to its name before it
            # looks an account up, so every controller needs a PTR record in a reverse lookup zone.
            Import-Module DnsServer
            foreach ($dc in Get-ADDomainController -Filter *) {
                if (-not $dc.IPv4Address) { continue }
                $octets = $dc.IPv4Address.Split('.')
                $zone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
                if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
                    Add-DnsServerPrimaryZone -NetworkId "$($octets[0]).$($octets[1]).$($octets[2]).0/24" `
                        -ReplicationScope Domain
                }
                if (-not (Get-DnsServerResourceRecord -ZoneName $zone -Name $octets[3] -RRType Ptr -ErrorAction SilentlyContinue)) {
                    Add-DnsServerResourceRecordPtr -ZoneName $zone -Name $octets[3] -PtrDomainName "$($dc.HostName)."
                }
            }

            [pscustomobject]@{
                Realm   = $domain.DNSRoot.ToUpperInvariant()
                Netbios = $domain.NetBIOSName
                DcFqdn  = "$env:COMPUTERNAME.$($domain.DNSRoot)".ToLowerInvariant()
                DcAddress = (Get-ADDomainController -Identity $env:COMPUTERNAME).IPv4Address
                SqlKvno = [int](Get-ADUser $sqlName -Properties 'msDS-KeyVersionNumber').'msDS-KeyVersionNumber'
                AppKvno = [int](Get-ADUser $appName -Properties 'msDS-KeyVersionNumber').'msDS-KeyVersionNumber'
            }
        } -ArgumentList $OuName, $SqlServiceAccountName, $sqlPassword, $AppServiceAccountName, $appPassword, $sqlHost

        $realm = $kerberos.Realm
        $appLogin = "$($kerberos.Netbios)\$AppServiceAccountName"

        # A user account's AES salt is the realm followed by its sAMAccountName, for every principal
        # name it holds, which is why the SPN entries reuse the account's keys.
        $sqlPrincipals = [System.Collections.Generic.List[string[]]]::new()
        $sqlPrincipals.Add([string[]]@($SqlServiceAccountName))
        $sqlPrincipals.Add([string[]]@('MSSQLSvc', "${sqlHost}:1433"))
        $sqlPrincipals.Add([string[]]@('MSSQLSvc', $sqlHost))
        $sqlKeytab = New-Keytab -Realm $realm -Principals $sqlPrincipals.ToArray() -Password $sqlPassword `
            -Salt "$realm$SqlServiceAccountName" -Kvno $kerberos.SqlKvno

        $appPrincipals = [System.Collections.Generic.List[string[]]]::new()
        $appPrincipals.Add([string[]]@($AppServiceAccountName))
        $appKeytab = New-Keytab -Realm $realm -Principals $appPrincipals.ToArray() -Password $appPassword `
            -Salt "$realm$AppServiceAccountName" -Kvno $kerberos.AppKvno
        $sqlPassword = $null
        $appPassword = $null

        $domainLower = $DomainName.ToLowerInvariant()
        $krb5Conf = @(
            '[libdefaults]'
            "    default_realm = $realm"
            '    dns_lookup_realm = false'
            '    dns_lookup_kdc = false'
            '    rdns = false'
            '    dns_canonicalize_hostname = false'
            '    udp_preference_limit = 0'
            ''
            '[realms]'
            "    $realm = {"
            "        kdc = $($kerberos.DcFqdn)"
            '    }'
            ''
            '[domain_realm]'
            "    .$domainLower = $realm"
            "    $domainLower = $realm"
            "    .svc.cluster.local = $realm"
            ''
        ) -join "`n"

        Write-Host "==> Publishing the keytabs and krb5.conf to namespace '$AppNamespace'" -ForegroundColor Cyan
        kubectl --context $KubeContext create namespace $AppNamespace `
            --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

        $tempDir = Join-Path ([IO.Path]::GetTempPath()) "oms-kerberos-$PID"
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        try {
            [IO.File]::WriteAllBytes((Join-Path $tempDir 'mssql.keytab'), $sqlKeytab)
            [IO.File]::WriteAllBytes((Join-Path $tempDir 'client.keytab'), $appKeytab)
            [IO.File]::WriteAllText((Join-Path $tempDir 'krb5.conf'), $krb5Conf)

            # Each entry is one kubectl argument list; the leading comma keeps it from being flattened.
            $manifests = @(
                , @('secret', 'generic', $SqlKeytabSecretName, "--from-file=mssql.keytab=$tempDir/mssql.keytab",
                    "--from-literal=account=$SqlServiceAccountName")
                , @('secret', 'generic', $AppKeytabSecretName, "--from-file=client.keytab=$tempDir/client.keytab",
                    "--from-literal=login=$appLogin")
                # SQL Server on Linux resolves the short domain name as a host; these pin it to the controller.
                , @('configmap', $KerberosConfigMapName, "--from-file=krb5.conf=$tempDir/krb5.conf",
                    "--from-literal=kdc-address=$($kerberos.DcAddress)",
                    "--from-literal=kdc-hostnames=$($kerberos.DcFqdn),$domainLower,$($kerberos.Netbios.ToLowerInvariant())")
            )
            foreach ($manifest in $manifests) {
                kubectl --context $KubeContext -n $AppNamespace create @manifest --dry-run=client --output yaml |
                    kubectl --context $KubeContext apply -f - | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "kubectl create $($manifest[0..1] -join ' ') failed in namespace '$AppNamespace'." }
            }
        }
        finally {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "    SQL service account : $($kerberos.Netbios)\$SqlServiceAccountName (MSSQLSvc/$sqlHost)" -ForegroundColor DarkGray
        Write-Host "    Application login   : $appLogin" -ForegroundColor DarkGray
        Write-Host "    secret/$SqlKeytabSecretName, secret/$AppKeytabSecretName, configmap/$KerberosConfigMapName" -ForegroundColor DarkGray
        Write-Host '    Redeploy the application so SQL Server and the pods pick up the new keys.' -ForegroundColor Yellow
    }

    if ($KerberosOnly) {
        return
    }

    $bindPassword = New-DirectoryPassword
    $demoPassword = New-DirectoryPassword

    Write-Host "==> Creating the demo organisational unit and accounts" -ForegroundColor Cyan
    $created = Invoke-Guest -Credential $domainCredential -ScriptBlock {
        param($ouName, $bindName, $bindPw, $demoName, $demoPw)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory

        $domain = Get-ADDomain
        $ouPath = "OU=$ouName,$($domain.DistinguishedName)"

        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName `
                -ProtectedFromAccidentalDeletion $true
        }

        foreach ($group in 'oms-app-readers', 'oms-app-writers') {
            if (-not (Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $group -GroupScope Global -GroupCategory Security -Path $ouPath
            }
        }

        # Keycloak reads the directory over LDAP with this account. It needs nothing beyond the
        # read access every authenticated account already has, so it joins no privileged group.
        $bindSecure = ConvertTo-SecureString $bindPw -AsPlainText -Force
        if (Get-ADUser -Filter "SamAccountName -eq '$bindName'" -ErrorAction SilentlyContinue) {
            Set-ADAccountPassword -Identity $bindName -NewPassword $bindSecure -Reset
        }
        else {
            New-ADUser -Name $bindName -SamAccountName $bindName `
                -UserPrincipalName "$bindName@$($domain.DNSRoot)" -Path $ouPath `
                -AccountPassword $bindSecure -PasswordNeverExpires $true `
                -CannotChangePassword $true -Enabled $true `
                -Description 'Keycloak LDAP user federation bind account'
        }

        $demoSecure = ConvertTo-SecureString $demoPw -AsPlainText -Force
        if (Get-ADUser -Filter "SamAccountName -eq '$demoName'" -ErrorAction SilentlyContinue) {
            Set-ADAccountPassword -Identity $demoName -NewPassword $demoSecure -Reset
        }
        else {
            New-ADUser -Name $demoName -SamAccountName $demoName `
                -UserPrincipalName "$demoName@$($domain.DNSRoot)" -Path $ouPath `
                -AccountPassword $demoSecure -PasswordNeverExpires $true -Enabled $true `
                -Description 'Sample end user for API authentication'
        }
        Add-ADGroupMember -Identity 'oms-app-readers' -Members $demoName -ErrorAction SilentlyContinue
        Add-ADGroupMember -Identity 'oms-app-writers' -Members $demoName -ErrorAction SilentlyContinue

        [pscustomobject]@{
            DnsRoot          = $domain.DNSRoot
            BaseDn           = $domain.DistinguishedName
            OuDn             = $ouPath
            BindDn           = (Get-ADUser -Identity $bindName).DistinguishedName
            BindUpn          = "$bindName@$($domain.DNSRoot)"
            DemoUpn          = "$demoName@$($domain.DNSRoot)"
            # Setup generates the machine name, so the certificate's subject is whatever this is
            # rather than the VM name, and that is the name LDAPS has to be reached by.
            DcFqdn           = "$env:COMPUTERNAME.$($domain.DNSRoot)".ToLowerInvariant()
        }
    } -ArgumentList $OuName, $BindAccountName, $bindPassword, $DemoUserName, $demoPassword

    if (-not $SkipBindSecret) {
        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Warning "'kubectl' is not on PATH, so the bind credential was not published."
        }
        else {
            Write-Host "==> Publishing the bind credential to the cluster" -ForegroundColor Cyan
            kubectl --context $KubeContext create namespace $SecretNamespace `
                --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

            # Replaced rather than patched, so a re-run that reset the password stays consistent.
            kubectl --context $KubeContext -n $SecretNamespace delete secret $SecretName `
                --ignore-not-found | Out-Null

            # Quoted because a generated password may contain characters PowerShell would
            # otherwise treat as syntax when building the argument.
            kubectl --context $KubeContext -n $SecretNamespace create secret generic $SecretName `
                "--from-literal=bind-dn=$($created.BindDn)" `
                "--from-literal=bind-upn=$($created.BindUpn)" `
                "--from-literal=bind-password=$bindPassword" `
                "--from-literal=demo-upn=$($created.DemoUpn)" `
                "--from-literal=demo-password=$demoPassword" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not write the bind credential Secret.' }

            Write-Host "    secret/$SecretName in namespace $SecretNamespace" -ForegroundColor DarkGray

            # Keycloak is not domain joined, so it never receives the root certificate the way a
            # member machine would; it has to be handed over explicitly for LDAPS to validate.
            if ($caCertPem) {
                $caFile = Join-Path ([IO.Path]::GetTempPath()) "oms-ad-ca-$PID.crt"
                try {
                    Set-Content -Path $caFile -Value $caCertPem -Encoding ascii
                    kubectl --context $KubeContext -n $SecretNamespace delete secret $CaSecretName `
                        --ignore-not-found | Out-Null
                    kubectl --context $KubeContext -n $SecretNamespace create secret generic $CaSecretName `
                        "--from-file=ca.crt=$caFile" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Could not write the CA certificate Secret.' }
                }
                finally { Remove-Item $caFile -ErrorAction SilentlyContinue }

                Write-Host "    secret/$CaSecretName in namespace $SecretNamespace" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`n================ Domain controller ready ================" -ForegroundColor Green
    Write-Host "VM            : $VmName"
    Write-Host "Domain        : $($created.DnsRoot) ($NetbiosName)"
    Write-Host "Controller    : $($created.DcFqdn)"
    Write-Host "Search base   : $($created.BaseDn)"
    Write-Host "Demo OU       : $($created.OuDn)"
    Write-Host "Bind account  : $($created.BindUpn)"
    Write-Host "Sample user   : $($created.DemoUpn)"
    if ($caCertPem) { Write-Host "LDAP          : ldaps://$($created.DcFqdn):636" }
    else { Write-Host "LDAP          : ldap://$($created.DcFqdn):389 (no TLS)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'The generated passwords were written to the cluster, never to this console.' -ForegroundColor DarkGray
    Write-Host "Read them back with:" -ForegroundColor DarkGray
    Write-Host "  kubectl --context $KubeContext -n $SecretNamespace get secret $SecretName -o jsonpath='{.data.bind-password}'"
    Write-Host 'Next, stand up Keycloak (cluster nodes already resolve the domain through this controller):' -ForegroundColor Yellow
    Write-Host "  ./scripts/infra/azurelocal/keycloak.ps1 -AdServer $($created.DcFqdn) -AdDomain $($created.DnsRoot) -SpaOrigin https://<app address> -KubeContext $KubeContext -AllowInClusterIssuer ..."
}
finally {
    Pop-Location
}
