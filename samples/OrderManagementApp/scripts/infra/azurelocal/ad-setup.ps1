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
      * LDAPS on 636: a controller that already has a certificate for its name keeps it. One without
        gets AD Certificate Services, unless it already runs a CA, and enrols a certificate.
      * The OMS OU, the oms-app-readers / oms-app-writers / oms-inventory-admins groups, the
        oms-operators group (who may use the site's Grafana; the sample inventory administrator is
        in it), the oms-identity-admins group (administrators of the app's Keycloak realm; it starts empty), the
        Keycloak bind account, a sample user who places orders and a sample inventory administrator.
      * Limits on the bind account: it can sign in only at the domain controllers and can't be
        delegated.
      * Two Kubernetes Secrets in the cluster: the bind and sample-user credentials, and the CA
        root certificate for Keycloak to trust LDAPS.

    The controller's network settings and DNS forwarders are left untouched and the directory
    service is not restarted: LDAP is told to reload its certificate instead.

    The script talks to the controller in one of two ways:
      -ComputerName  PowerShell remoting (WinRM), from the site's management machine or any machine
                     that reaches the controller, or 'localhost' on the controller itself. This is
                     the usual way: it needs no access to the machine that hosts the controller.
      -VmName        PowerShell Direct, from the Hyper-V host that runs the controller as a VM, for
                     a controller with no network path from your machine.
    If you'd rather not run it, make the same objects with the Active Directory PowerShell module
    instead; docs/authentication.md lists them under "Connect your Active Directory".

    setup-platform.ps1 (and so up.ps1) runs it as the ActiveDirectory step, right after it creates
    the cluster, with the domain controller from the Keycloak settings: AdServer, AdDomain and
    AdOuName. Run it yourself to change the directory later.

    The script is safe to re-run. Accounts that already exist keep their passwords, so Keycloak's
    directory sign-in keeps working; pass -ResetBindPassword to give the bind account a new one, then
    run keycloak.ps1, which applies it to Keycloak. The bind account's limits cover the containers
    and domain controllers that exist when it runs, so re-run it after adding either.

.PARAMETER VmName
    Name of the domain controller VM, when this runs on its Hyper-V host (PowerShell Direct).

.PARAMETER ComputerName
    Name of the domain controller, reached over PowerShell remoting. Use 'localhost' when this runs
    on the controller itself.

.PARAMETER DomainName
    The controller's Active Directory domain, such as contoso.local. The script stops if the
    controller belongs to another one.

.PARAMETER DomainAdminCredential
    Domain administrator of the controller's domain. Prompted for when omitted.

.PARAMETER ResetBindPassword
    Give an existing bind account a new password, and write it to the cluster. Without it, an
    existing bind account keeps its password.

.PARAMETER SkipBindSecret
    Do not write the bind credential and CA certificate into Kubernetes Secrets. By default they
    are written to the cluster so that scripts/infra/azurelocal/keycloak.ps1 can pick them up without the
    passwords being typed or displayed.

.PARAMETER CaCommonName
    Name of the enterprise CA to install when the controller has none. Empty: <domain>-<controller>-CA,
    the name Windows suggests.

.EXAMPLE
    # From the site's management machine, reaching the domain controller over WinRM.
    ./scripts/infra/azurelocal/ad-setup.ps1 -ComputerName dc01.contoso.local -DomainName contoso.local `
        -KubeContext my-aksarc

.EXAMPLE
    # Elevated, on the Hyper-V host that runs the domain controller VM.
    ./scripts/infra/azurelocal/ad-setup.ps1 -VmName <vm name> -DomainName contoso.local -KubeContext my-aksarc
#>
[CmdletBinding(DefaultParameterSetName = 'Remoting')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string]$VmName,
    # The aliases are the Keycloak settings' names, which setup-platform.ps1 passes.
    [Parameter(Mandatory = $true, ParameterSetName = 'Remoting')][Alias('AdServer')][string]$ComputerName,
    [Parameter(Mandatory = $true)][Alias('AdDomain')][string]$DomainName,
    [Alias('AdOuName')][string]$OuName = 'OMS',

    [pscredential]$DomainAdminCredential,

    [string]$BindAccountName = 'svc-keycloak',
    [string]$DemoUserName = 'oms-demo',
    [string]$InventoryAdminUserName = 'oms-inventory-admin',

    [switch]$ResetBindPassword,
    [switch]$SkipBindSecret,
    [switch]$SkipCertificateAuthority,
    # Only used when the controller has no certificate authority yet.
    [string]$CaCommonName,
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
# every character class. Drawn from the system's cryptographic random number generator.
function New-DirectoryPassword {
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_'
    )
    $random = { param($max) [Security.Cryptography.RandomNumberGenerator]::GetInt32($max) }

    $chars = [Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[(& $random $set.Length)]) }
    $all = -join $sets
    foreach ($i in 1..16) { $chars.Add($all[(& $random $all.Length)]) }

    # Fisher-Yates, so the guaranteed characters don't sit at the start.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = & $random ($i + 1)
        $chars[$i], $chars[$j] = $chars[$j], $chars[$i]
    }
    return -join $chars
}

function Invoke-Guest {
    param(
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $connection = if ($ComputerName) { @{ ComputerName = $ComputerName } } else { @{ VMName = $VmName } }
    # A machine outside the site's domain: its default sign-in falls back to NTLM, which remoting
    # allows only to TrustedHosts. Kerberos authenticates both ends, so it needs no TrustedHosts,
    # only the domain controller's name and the domain's KDC (port 88) reachable from here.
    if ($ComputerName -and -not $script:inSiteDomain) { $connection.Authentication = 'Kerberos' }
    Invoke-Command @connection -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

# An LDAP bind is a sign-in at the controller that answers it, so the bind account may sign in at the
# controllers and nowhere else. Controllers allow interactive and Remote Desktop sign-in to
# administrators only, which leaves the network sign-in LDAP uses. Nothing acts on the account's
# behalf, so delegation is off. Keycloak reads only the app's OU with it.
function Set-BindAccountRestriction {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    Write-Host "==> Limiting '$BindAccountName' to signing in at the domain controllers" -ForegroundColor Cyan
    $controllers = Invoke-Guest -Credential $Credential -ArgumentList $BindAccountName -ScriptBlock {
        param($bindName)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory
        $names = @(Get-ADDomainController -Filter * | ForEach-Object { $_.Name })
        Set-ADUser -Identity $bindName -LogonWorkstations ($names -join ',') -AccountNotDelegated $true
        $names -join ', '
    }
    Write-Host "    sign-in only at $controllers; not delegated" -ForegroundColor DarkGray
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

    $computer = if ($IsWindows) { Get-CimInstance -ClassName Win32_ComputerSystem }
    $script:inSiteDomain = $computer -and $computer.PartOfDomain -and $computer.Domain -eq $DomainName
    $how = if (-not $ComputerName) { 'over PowerShell Direct' }
    elseif ($script:inSiteDomain) { 'over PowerShell remoting' }
    else { "over PowerShell remoting with Kerberos (this machine isn't in '$DomainName')" }

    # NTLM falls back to the local SAM when the domain prefix does not resolve, so a credential
    # being accepted says nothing about the machine's role; the controller's own answer is
    # authoritative. A typed password that's empty or rejected is asked for again, up to 3 times.
    $prompted = -not $DomainAdminCredential
    for ($attempt = 1; ; $attempt++) {
        if ($prompted) {
            $DomainAdminCredential = Get-Credential -UserName "Administrator@$DomainName" `
                -Message "Domain administrator of '$DomainName' on '$target'"
            if (-not $DomainAdminCredential) { throw 'No domain administrator given.' }
        }
        $domainCredential = $DomainAdminCredential
        if ($domainCredential.Password.Length -eq 0) {
            if ($prompted -and $attempt -lt 3) { Write-Host '    The password is empty; enter it again.' -ForegroundColor Yellow; continue }
            throw "The password for '$($domainCredential.UserName)' is empty."
        }

        Write-Host "==> Connecting to '$target' $how" -ForegroundColor Cyan
        try {
            $controller = Invoke-Guest -Credential $domainCredential -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $role = [int](Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
                $dnsRoot = $null
                if ($role -ge 4) {
                    Import-Module ActiveDirectory
                    $dnsRoot = (Get-ADDomain).DNSRoot
                }
                [pscustomobject]@{ DomainRole = $role; DnsRoot = $dnsRoot }
            }
            break
        }
        catch {
            $message = "Could not run commands on '$target' as '$($domainCredential.UserName)': $($_.Exception.Message)"
            if ($prompted -and $attempt -lt 3) { Write-Host "    $message`n    Check the user name and password, and enter them again." -ForegroundColor Yellow; continue }
            $hint = if ($ComputerName -and -not $script:inSiteDomain) {
                " Kerberos from outside the domain needs the controller's full DNS name (not an IP address), the user as user@$DomainName, and the domain's KDC (port 88) reachable from here."
            }
            throw "$message$hint"
        }
    }
    if ($controller.DomainRole -lt 4) {
        throw "'$target' is not a domain controller (DomainRole $($controller.DomainRole))."
    }
    if ($controller.DnsRoot -ne $DomainName) {
        throw "'$target' is a domain controller of '$($controller.DnsRoot)', not '$DomainName'."
    }

    # LDAPS needs a server authentication certificate for the controller's own name. A controller
    # that already has one, usually from the organisation's PKI, keeps it. Only one without gets an
    # enterprise CA, which publishes the domain controller templates into AD, so the controller
    # enrols a certificate and port 636 becomes a working TLS endpoint. Keycloak is given the root of
    # the certificate's chain, whichever CA issued it.
    $caCertPem = $null
    if (-not $SkipCertificateAuthority) {
        Write-Host "==> Ensuring LDAPS on the controller" -ForegroundColor Cyan
        $caCertPem = Invoke-Guest -Credential $domainCredential -ArgumentList $CaCommonName, $domainCredential -ScriptBlock {
            param($caName, $directoryCredential)
            $ErrorActionPreference = 'Stop'

            # Other server certificates a controller may hold, for example for ADFS, don't count.
            $dcName = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
            $find = {
                Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
                        $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' -and
                        $_.DnsNameList.Unicode -contains $dcName
                    } | Sort-Object NotAfter -Descending | Select-Object -First 1
            }

            $dcCert = & $find
            if ($dcCert) {
                Write-Host "    the controller already has a certificate from '$($dcCert.Issuer)'"
            }
            else {
                # A CA this controller already runs is reused rather than stacking a second one.
                if (-not (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue).Active) {
                    # The name Windows suggests when you install a CA by hand.
                    if (-not $caName) {
                        Import-Module ActiveDirectory
                        $caName = "$((Get-ADDomain).NetBIOSName)-$env:COMPUTERNAME-CA"
                    }
                    Write-Host "    installing enterprise certificate authority '$caName'"
                    Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null
                    Import-Module ADCSDeployment
                    try {
                        Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName $caName `
                            -KeyLength 2048 -HashAlgorithmName SHA256 `
                            -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
                    }
                    catch [Microsoft.CertificateServices.Deployment.Common.CA.CertificationAuthoritySetupException] {
                        # Fine if a CA got configured after all; otherwise, say why it wasn't, for
                        # example a key left by a CA removed earlier.
                        if (-not (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue).Active) {
                            throw "Setting up the certificate authority '$caName' failed: $($_.Exception.Message)"
                        }
                    }
                }

                # Auto-enrolment is on a timer, so it's nudged rather than waited for.
                $deadline = (Get-Date).AddMinutes(5)
                while (-not ($dcCert = & $find) -and (Get-Date) -lt $deadline) {
                    certutil -pulse | Out-Null
                    Start-Sleep -Seconds 15
                }
                if (-not $dcCert) { throw "The controller never enrolled a server authentication certificate for $dcName." }

                # The controller serves other systems, so the directory is not restarted: the rootDSE
                # 'renewServerCertificate' operation tells LDAP to load the new certificate in place.
                # The bind is explicit because a remote session has no credentials to pass on.
                $rootDse = [System.DirectoryServices.DirectoryEntry]::new('LDAP://localhost/RootDSE',
                    $directoryCredential.UserName, $directoryCredential.GetNetworkCredential().Password)
                $rootDse.Properties['renewServerCertificate'].Value = 1
                $rootDse.CommitChanges()
                $rootDse.Dispose()
            }

            $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
            $chain.ChainPolicy.RevocationMode = 'NoCheck'
            [void]$chain.Build($dcCert)
            $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            if ($root.Subject -ne $root.Issuer) {
                throw "The controller's certificate from '$($dcCert.Issuer)' doesn't chain to a root certificate the controller has. Prepare the directory yourself (-Skip ActiveDirectory) and set Keycloak.AdCaCertificatePath to the root CA's certificate."
            }
            $b64 = [Convert]::ToBase64String($root.RawData, 'InsertLineBreaks')
            "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----"
        }

        Write-Host '    LDAPS available on 636' -ForegroundColor DarkGray
    }

    # Passwords are only set on accounts this run creates, and on the bind account with
    # -ResetBindPassword, so a re-run never breaks a sign-in that works.
    $bindPassword = New-DirectoryPassword
    $demoPassword = New-DirectoryPassword
    $inventoryAdminPassword = New-DirectoryPassword

    Write-Host "==> Creating the app's organisational unit, groups and accounts" -ForegroundColor Cyan
    $created = Invoke-Guest -Credential $domainCredential -ScriptBlock {
        param($ouName, $bindName, $bindPw, $resetBind, $demoName, $demoPw, $adminName, $adminPw)
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory

        $domain = Get-ADDomain
        $ouPath = "OU=$ouName,$($domain.DistinguishedName)"

        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName `
                -ProtectedFromAccidentalDeletion $true
        }

        # oms-identity-admins administer the app's Keycloak realm; add your administrators to it.
        # oms-operators use the site's Grafana.
        foreach ($group in 'oms-app-readers', 'oms-app-writers', 'oms-inventory-admins', 'oms-operators', 'oms-identity-admins') {
            if (-not (Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $group -GroupScope Global -GroupCategory Security -Path $ouPath
            }
        }

        # Creates the account with the given password, or leaves an existing one's alone unless
        # $reset. Returns whether the password was set.
        function Set-OmsUser([string]$Name, [string]$Initial, [string]$Description, [bool]$Reset, [hashtable]$Options = @{}) {
            $secure = ConvertTo-SecureString $Initial -AsPlainText -Force
            if (Get-ADUser -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue) {
                if (-not $Reset) { return $false }
                Set-ADAccountPassword -Identity $Name -NewPassword $secure -Reset
                return $true
            }
            New-ADUser -Name $Name -SamAccountName $Name -UserPrincipalName "$Name@$($domain.DNSRoot)" `
                -Path $ouPath -AccountPassword $secure -PasswordNeverExpires $true -Enabled $true `
                -Description $Description @Options
            return $true
        }

        # Keycloak reads the directory over LDAP with this account. It joins no group, and
        # Set-BindAccountRestriction below narrows it further.
        $bindSet = Set-OmsUser -Name $bindName -Initial $bindPw -Description 'Keycloak LDAP user federation bind account' -Reset $resetBind -Options @{ CannotChangePassword = $true }

        $demoSet = Set-OmsUser -Name $demoName -Initial $demoPw -Description 'Sample end user for API authentication' -Reset $false
        Add-ADGroupMember -Identity 'oms-app-readers' -Members $demoName -ErrorAction SilentlyContinue
        Add-ADGroupMember -Identity 'oms-app-writers' -Members $demoName -ErrorAction SilentlyContinue

        # A second sample user, who maintains the inventory and watches the site rather than placing orders.
        $adminSet = Set-OmsUser -Name $adminName -Initial $adminPw -Description 'Sample inventory administrator' -Reset $false
        Add-ADGroupMember -Identity 'oms-inventory-admins' -Members $adminName -ErrorAction SilentlyContinue
        Add-ADGroupMember -Identity 'oms-operators' -Members $adminName -ErrorAction SilentlyContinue

        [pscustomobject]@{
            DnsRoot              = $domain.DNSRoot
            BaseDn               = $domain.DistinguishedName
            OuDn                 = $ouPath
            BindDn               = (Get-ADUser -Identity $bindName).DistinguishedName
            BindUpn              = "$bindName@$($domain.DNSRoot)"
            BindPasswordSet      = $bindSet
            DemoUpn              = "$demoName@$($domain.DNSRoot)"
            DemoPasswordSet      = $demoSet
            InventoryAdminUpn    = "$adminName@$($domain.DNSRoot)"
            InventoryAdminPasswordSet = $adminSet
            # The controller's own name, which its LDAPS certificate carries. With -VmName it can
            # differ from the VM's name.
            DcFqdn               = "$env:COMPUTERNAME.$($domain.DNSRoot)".ToLowerInvariant()
        }
    } -ArgumentList $OuName, $BindAccountName, $bindPassword, $ResetBindPassword.IsPresent, $DemoUserName, $demoPassword, $InventoryAdminUserName, $inventoryAdminPassword
    if ($created.BindPasswordSet) { Write-Host "    new password for $($created.BindUpn)" -ForegroundColor DarkGray }

    Set-BindAccountRestriction -Credential $domainCredential

    if (-not $SkipBindSecret) {
        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Warning "'kubectl' is not on PATH, so the bind credential was not published."
        }
        else {
            Write-Host "==> Publishing the bind credential to the cluster" -ForegroundColor Cyan
            kubectl --context $KubeContext create namespace $SecretNamespace `
                --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$SecretNamespace' failed." }

            # Passwords this run didn't set stay as the Secret has them. The values go to kubectl on
            # stdin, never on a command line. The sample users' credentials are for sign-in tests.
            $data = Get-OmsSecretData -KubeContext $KubeContext -Namespace $SecretNamespace -Name $SecretName
            if ($data['bind-upn'] -and $data['bind-upn'] -ne $created.BindUpn) { $data.Remove('bind-password') }
            $data['bind-dn'] = $created.BindDn
            $data['bind-upn'] = $created.BindUpn
            $data['demo-upn'] = $created.DemoUpn
            $data['inventory-admin-upn'] = $created.InventoryAdminUpn
            if ($created.BindPasswordSet) { $data['bind-password'] = $bindPassword }
            if ($created.DemoPasswordSet) { $data['demo-password'] = $demoPassword }
            if ($created.InventoryAdminPasswordSet) { $data['inventory-admin-password'] = $inventoryAdminPassword }
            Set-OmsSecret -KubeContext $KubeContext -Namespace $SecretNamespace -Name $SecretName -Data $data
            Write-Host "    secret/$SecretName in namespace $SecretNamespace" -ForegroundColor DarkGray

            if (-not $data['bind-password']) {
                Write-Warning @"
'$($created.BindUpn)' already existed, so its password is unknown here and Secret
$SecretNamespace/$SecretName has none. Re-run with -ResetBindPassword to give it a new one, or let
keycloak.ps1 ask for the current one.
"@
            }
            elseif ($created.BindPasswordSet) {
                Write-Host '    run keycloak.ps1 to apply the new bind password to Keycloak' -ForegroundColor Yellow
            }

            # Keycloak is not domain joined, so it never receives the root certificate the way a
            # member machine would; it has to be handed over explicitly for LDAPS to validate.
            if ($caCertPem) {
                Set-OmsSecret -KubeContext $KubeContext -Namespace $SecretNamespace -Name $CaSecretName -Data @{ 'ca.crt' = $caCertPem }
                Write-Host "    secret/$CaSecretName in namespace $SecretNamespace" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`n================ Domain controller ready ================" -ForegroundColor Green
    Write-Host "Connected to  : $target"
    Write-Host "Domain        : $($created.DnsRoot)"
    Write-Host "Controller    : $($created.DcFqdn)"
    Write-Host "Search base   : $($created.BaseDn)"
    Write-Host "App OU        : $($created.OuDn)"
    Write-Host "Bind account  : $($created.BindUpn)"
    # Keycloak's user name is the account name (sAMAccountName); the sample accounts have no email
    # address, so their name@domain form doesn't sign in.
    Write-Host "Sample user   : $DemoUserName (places orders); sign in with this name, not $($created.DemoUpn)"
    Write-Host "Inventory admin: $InventoryAdminUserName (restocks products)"
    Write-Host "Realm admins  : oms-identity-admins (add the people who administer Keycloak's 'oms' realm)"
    if ($caCertPem) { Write-Host "LDAP          : ldaps://$($created.DcFqdn):636" }
    else { Write-Host "LDAP          : ldap://$($created.DcFqdn):389 (no TLS)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'The generated passwords were written to the cluster, never to this console.' -ForegroundColor DarkGray
    Write-Host "Copy the sample user's to the clipboard (inventory-admin-password for the inventory admin's) with:" -ForegroundColor DarkGray
    Write-Host "  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl --context $KubeContext -n $SecretNamespace get secret $SecretName -o jsonpath='{.data.demo-password}'))) | Set-Clipboard"
    Write-Host 'Next, stand up Keycloak (cluster nodes already resolve the domain through this controller):' -ForegroundColor Yellow
    Write-Host "  ./scripts/infra/azurelocal/keycloak.ps1 -AdServer $($created.DcFqdn) -AdDomain $($created.DnsRoot) -SpaOrigin https://<app address> -KubeContext $KubeContext -AllowInClusterIssuer ..."
}
finally {
    Pop-Location
}
