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
      * The OMS OU, the oms-app-readers / oms-app-writers / oms-inventory-admins groups, the
        Keycloak bind account, a sample user who places orders and a sample inventory administrator.
      * Limits on the bind account: it can sign in only at the domain controllers, can't be
        delegated, and is denied listing every container outside the OMS OU.
      * Two Kubernetes Secrets in the cluster: the bind and sample-user credentials, and the CA
        root certificate for Keycloak to trust LDAPS.

    The controller's network settings and DNS forwarders are left untouched and the directory
    service is not restarted: LDAP is told to reload its certificate instead.

    The script talks to the controller in one of two ways:
      -ComputerName  PowerShell remoting (WinRM), from the site's management machine or any machine
                     that reaches the controller, or 'localhost' on the controller itself. This is
                     the usual way: it needs no access to the machine that hosts the controller.
      -VmName        PowerShell Direct, from the Hyper-V host that runs the controller as a VM, as
                     in a lab where the controller has no network path from your machine.
    If you'd rather not run it, make the same objects with the Active Directory PowerShell module
    instead; docs/authentication.md lists them under "Connect your Active Directory".

    The script is safe to re-run. Re-running resets the passwords of the accounts it manages and
    rewrites the Secrets. The bind account's limits cover the containers and domain controllers that
    exist when it runs, so re-run it after adding either.

.PARAMETER VmName
    Name of the domain controller VM, when this runs on its Hyper-V host (PowerShell Direct).

.PARAMETER ComputerName
    Name of the domain controller, reached over PowerShell remoting. Use 'localhost' when this runs
    on the controller itself. Takes precedence over -VmName.

.PARAMETER DomainAdminCredential
    Domain administrator of the controller's domain. Prompted for when omitted.

.PARAMETER SkipBindSecret
    Do not write the bind credential and CA certificate into Kubernetes Secrets. By default they
    are written to the cluster so that scripts/infra/azurelocal/keycloak.ps1 can pick them up without the
    passwords being typed or displayed.

.EXAMPLE
    # From the site's management machine, reaching the domain controller over WinRM.
    ./scripts/infra/azurelocal/ad-setup.ps1 -ComputerName dc01.contoso.local -DomainName contoso.local `
        -NetbiosName CONTOSO -KubeContext my-aksarc

.EXAMPLE
    # Lab: elevated, on the Hyper-V host that runs the domain controller VM.
    ./scripts/infra/azurelocal/ad-setup.ps1 -VmName DC01 -DomainName azurelocal.lab -NetbiosName AZURELOCAL `
        -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$VmName = 'DC01',
    [string]$ComputerName,
    [string]$DomainName = 'azurelocal.lab',
    [string]$NetbiosName = 'AZURELOCAL',
    [string]$OuName = 'OMS',

    [pscredential]$DomainAdminCredential,

    [string]$BindAccountName = 'svc-keycloak',
    [string]$DemoUserName = 'oms-demo',
    [string]$InventoryAdminUserName = 'oms-inventory-admin',

    [switch]$SkipBindSecret,
    [switch]$SkipCertificateAuthority,
    # Only used when the controller has no certificate authority yet.
    [string]$CaCommonName = 'OMS Lab Root CA',
    [string]$KubeContext = 'bcd-aksarc',
    [string]$SecretNamespace = 'identity',
    [string]$SecretName = 'oms-ad-bind',
    [string]$CaSecretName = 'oms-ad-ca'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/secrets.ps1')
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

# Promotion only rejects a weak restore-mode password after the role install has already run, so
# the same rules are applied up front: three of the four character classes, and long enough to
# satisfy any sensible policy.
# PowerShell Direct answers only once the guest has booted far enough to run the VM management
# service, which is well after the VM reports 'Running'. Returns $null on success, otherwise the
# failure message, because a rejected password and an unbooted guest are otherwise indistinguishable.
function Test-GuestCredential {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    try {
        $null = Invoke-Guest -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
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
'$target' rejected the password for '$($Credential.UserName -join "', '")'.
The controller is reachable, so this is the password, not the connection.
Check the account and password, then re-run.
"@
            }
        }

        Start-Sleep -Seconds 10
    }

    throw "Timed out waiting $TimeoutMinutes minutes for $What on '$target'. Last error: $lastError"
}

function Invoke-Guest {
    param(
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $connection = if ($ComputerName) { @{ ComputerName = $ComputerName } } else { @{ VMName = $VmName } }
    Invoke-Command @connection -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

# Keycloak signs in to the domain controllers over LDAP and reads the users and groups in the app's
# OU. The bind account is limited to exactly that.
function Set-BindAccountRestriction {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    Write-Host "==> Limiting '$BindAccountName' to reading the '$OuName' OU" -ForegroundColor Cyan
    $result = Invoke-Guest -Credential $Credential -ArgumentList $BindAccountName, $OuName -ScriptBlock {
        param($bindName, $ouName)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory

        $domain = Get-ADDomain
        $ouDn = "OU=$ouName,$($domain.DistinguishedName)"
        $bind = Get-ADUser -Identity $bindName

        # An LDAP bind is a sign-in at the controller that answers it, so the account may sign in at
        # the controllers and nowhere else. Controllers allow interactive and Remote Desktop sign-in
        # to administrators only, which leaves the network sign-in LDAP uses. Nothing acts on the
        # account's behalf, so delegation is off.
        $controllers = @(Get-ADDomainController -Filter * | ForEach-Object { $_.Name })
        Set-ADUser -Identity $bind -LogonWorkstations ($controllers -join ',') -AccountNotDelegated $true

        # Every account can list most of the domain, through permissions AD puts on each container.
        # A deny for this account on every container outside the OU takes precedence and hides
        # everything else from its searches. That includes empty OUs and containers, or anything
        # added to them later would be listable. The domain root stays listable, or the OU could
        # not be found. Group Policy objects are skipped: Group Policy Management flags a GPO whose
        # permissions differ from its SYSVOL folder.
        $candidates = @{}
        $policies = @{}
        Get-ADObject -Filter * -SearchBase $domain.DistinguishedName -SearchScope Subtree -ResultPageSize 1000 |
            ForEach-Object {
                if ($_.ObjectClass -eq 'groupPolicyContainer') { $policies[$_.DistinguishedName] = $true }
                if ($_.ObjectClass -in 'organizationalUnit', 'container') { $candidates[$_.DistinguishedName] = $true }
                if ($_.DistinguishedName -match '^(?:\\.|[^,\\])+,(.+)$') { $candidates[$Matches[1]] = $true }
            }
        $containers = @($candidates.Keys | Where-Object {
                $_.EndsWith(",$($domain.DistinguishedName)", [StringComparison]::OrdinalIgnoreCase) -and
                -not $policies.ContainsKey($_) -and
                $_ -ne $ouDn -and -not $_.EndsWith(",$ouDn", [StringComparison]::OrdinalIgnoreCase)
            })

        $rights = [System.DirectoryServices.ActiveDirectoryRights]'ListChildren, ListObject'
        $added = 0
        foreach ($dn in $containers) {
            # Through psbase: PowerShell's ADSI adapter otherwise reads these names as LDAP attributes.
            $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$($dn.Replace('/', '\/'))")
            try {
                $entry.psbase.Options.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
                $security = $entry.psbase.ObjectSecurity
                $present = $security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
                    Where-Object {
                        $_.AccessControlType -eq 'Deny' -and $_.IdentityReference -eq $bind.SID -and
                        ($_.ActiveDirectoryRights -band $rights) -eq $rights
                    }
                if (-not $present) {
                    $security.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new($bind.SID, $rights, 'Deny'))
                    $entry.psbase.ObjectSecurity = $security
                    $entry.psbase.CommitChanges()
                    $added++
                }
            }
            catch { throw "Could not restrict '$bindName' on '$dn': $($_.Exception.Message)" }
            finally { $entry.psbase.Dispose() }
        }

        [pscustomobject]@{ Controllers = $controllers -join ', '; Containers = $containers.Count; Added = $added }
    }
    Write-Host "    sign-in only at $($result.Controllers); listing denied on $($result.Containers) containers ($($result.Added) new)" -ForegroundColor DarkGray
}


try {
    $target = if ($ComputerName) { $ComputerName } else { $VmName }

    if (-not $ComputerName) {
        if (-not (Test-Elevated)) {
            throw 'Hyper-V and PowerShell Direct both need an elevated session. Re-run as Administrator, or use -ComputerName.'
        }

        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            throw "The Hyper-V PowerShell module is not available. Enable the 'Microsoft-Hyper-V-Management-PowerShell' feature, or use -ComputerName."
        }

        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            throw "No VM named '$VmName' on this host. Run this on the Hyper-V host that runs the domain controller, or use -ComputerName."
        }
        if ($vm.State -ne 'Running') {
            throw "'$VmName' is $($vm.State). Start the domain controller first."
        }
    }

    if (-not $DomainAdminCredential) {
        $DomainAdminCredential = Get-Credential -UserName "$NetbiosName\Administrator" `
            -Message "Domain administrator of '$DomainName' on '$target'"
    }
    $domainCredential = $DomainAdminCredential

    Write-Host "==> Connecting to '$target' $(if ($ComputerName) { 'over PowerShell remoting' } else { 'over PowerShell Direct' })" -ForegroundColor Cyan
    $null = Wait-GuestReady -Credential $domainCredential -TimeoutMinutes 5 -What 'the domain administrator account'

    # NTLM falls back to the local SAM when the domain prefix does not resolve, so a credential
    # being accepted says nothing about the machine's role; the guest's own answer is authoritative.
    $domainRole = [int](Invoke-Guest -Credential $domainCredential -ScriptBlock {
            (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
        })
    if ($domainRole -lt 4) {
        throw "'$target' is not a domain controller (DomainRole $domainRole)."
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
    if (-not $SkipCertificateAuthority) {
        Write-Host "==> Ensuring an enterprise certificate authority" -ForegroundColor Cyan
        $caCertPem = Invoke-Guest -Credential $domainCredential -ArgumentList $CaCommonName, $domainCredential -ScriptBlock {
            param($caName, $directoryCredential)
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

            # LDAPS uses a certificate issued to the controller's own name. Other server certificates
            # a controller may already hold, for example for ADFS, don't count.
            $dcName = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-Date) -lt $deadline) {
                $dcCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' -and
                        ($_.DnsNameList.Unicode -contains $dcName) -and $_.NotAfter -gt (Get-Date)
                    }
                if ($dcCert) { break }
                Start-Sleep -Seconds 15
                certutil -pulse | Out-Null
            }
            if (-not $dcCert) { throw "The controller never enrolled a server authentication certificate for $dcName." }

            # The controller serves other systems, so the directory is not restarted: the rootDSE
            # 'renewServerCertificate' operation tells LDAP to reload its certificate in place. The
            # bind is explicit because a remote session has no credentials to pass on.
            $rootDse = [System.DirectoryServices.DirectoryEntry]::new('LDAP://localhost/RootDSE',
                $directoryCredential.UserName, $directoryCredential.GetNetworkCredential().Password)
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

    $bindPassword = New-DirectoryPassword
    $demoPassword = New-DirectoryPassword
    $inventoryAdminPassword = New-DirectoryPassword

    Write-Host "==> Creating the demo organisational unit and accounts" -ForegroundColor Cyan
    $created = Invoke-Guest -Credential $domainCredential -ScriptBlock {
        param($ouName, $bindName, $bindPw, $demoName, $demoPw, $adminName, $adminPw)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory

        $domain = Get-ADDomain
        $ouPath = "OU=$ouName,$($domain.DistinguishedName)"

        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName `
                -ProtectedFromAccidentalDeletion $true
        }

        foreach ($group in 'oms-app-readers', 'oms-app-writers', 'oms-inventory-admins') {
            if (-not (Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $group -GroupScope Global -GroupCategory Security -Path $ouPath
            }
        }

        # Keycloak reads the directory over LDAP with this account. It joins no group, and
        # Set-BindAccountRestriction below narrows it further.
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

        # A second sample user, who maintains the inventory rather than placing orders.
        $adminSecure = ConvertTo-SecureString $adminPw -AsPlainText -Force
        if (Get-ADUser -Filter "SamAccountName -eq '$adminName'" -ErrorAction SilentlyContinue) {
            Set-ADAccountPassword -Identity $adminName -NewPassword $adminSecure -Reset
        }
        else {
            New-ADUser -Name $adminName -SamAccountName $adminName `
                -UserPrincipalName "$adminName@$($domain.DNSRoot)" -Path $ouPath `
                -AccountPassword $adminSecure -PasswordNeverExpires $true -Enabled $true `
                -Description 'Sample inventory administrator'
        }
        Add-ADGroupMember -Identity 'oms-inventory-admins' -Members $adminName -ErrorAction SilentlyContinue

        [pscustomobject]@{
            DnsRoot          = $domain.DNSRoot
            BaseDn           = $domain.DistinguishedName
            OuDn             = $ouPath
            BindDn           = (Get-ADUser -Identity $bindName).DistinguishedName
            BindUpn          = "$bindName@$($domain.DNSRoot)"
            DemoUpn          = "$demoName@$($domain.DNSRoot)"
            InventoryAdminUpn = "$adminName@$($domain.DNSRoot)"
            # Setup generates the machine name, so the certificate's subject is whatever this is
            # rather than the VM name, and that is the name LDAPS has to be reached by.
            DcFqdn           = "$env:COMPUTERNAME.$($domain.DNSRoot)".ToLowerInvariant()
        }
    } -ArgumentList $OuName, $BindAccountName, $bindPassword, $DemoUserName, $demoPassword, $InventoryAdminUserName, $inventoryAdminPassword

    Set-BindAccountRestriction -Credential $domainCredential

    if (-not $SkipBindSecret) {
        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Warning "'kubectl' is not on PATH, so the bind credential was not published."
        }
        else {
            Write-Host "==> Publishing the bind credential to the cluster" -ForegroundColor Cyan
            kubectl --context $KubeContext create namespace $SecretNamespace `
                --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

            # Every key at once, so a re-run that reset a password stays consistent. The values go to
            # kubectl on stdin, never on a command line. The inventory administrator's credentials
            # are for sign-in tests.
            Set-OmsSecret -KubeContext $KubeContext -Namespace $SecretNamespace -Name $SecretName -Data @{
                'bind-dn'                  = $created.BindDn
                'bind-upn'                 = $created.BindUpn
                'bind-password'            = $bindPassword
                'demo-upn'                 = $created.DemoUpn
                'demo-password'            = $demoPassword
                'inventory-admin-upn'      = $created.InventoryAdminUpn
                'inventory-admin-password' = $inventoryAdminPassword
            }

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
    Write-Host "Connected to  : $target"
    Write-Host "Domain        : $($created.DnsRoot) ($NetbiosName)"
    Write-Host "Controller    : $($created.DcFqdn)"
    Write-Host "Search base   : $($created.BaseDn)"
    Write-Host "Demo OU       : $($created.OuDn)"
    Write-Host "Bind account  : $($created.BindUpn)"
    Write-Host "Sample user   : $($created.DemoUpn) (places orders)"
    Write-Host "Inventory admin: $($created.InventoryAdminUpn) (restocks products)"
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
