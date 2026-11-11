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
        oms-operators group (who may use the site's Grafana; the sample inventory administrator is
        in it), the oms-identity-admins group (administrators of the app's Keycloak realm; it starts empty), the
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
      -VmName        PowerShell Direct, from the Hyper-V host that runs the controller as a VM, for
                     a controller with no network path from your machine.
    If you'd rather not run it, make the same objects with the Active Directory PowerShell module
    instead; docs/authentication.md lists them under "Connect your Active Directory".

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
    [Parameter(Mandatory = $true, ParameterSetName = 'Remoting')][string]$ComputerName,
    [Parameter(Mandatory = $true)][string]$DomainName,
    [string]$OuName = 'OMS',

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
        $DomainAdminCredential = Get-Credential -UserName "Administrator@$DomainName" `
            -Message "Domain administrator of '$DomainName' on '$target'"
    }
    $domainCredential = $DomainAdminCredential

    Write-Host "==> Connecting to '$target' $(if ($ComputerName) { 'over PowerShell remoting' } else { 'over PowerShell Direct' })" -ForegroundColor Cyan
    # NTLM falls back to the local SAM when the domain prefix does not resolve, so a credential
    # being accepted says nothing about the machine's role; the controller's own answer is
    # authoritative.
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
    }
    catch {
        throw "Could not run commands on '$target' as '$($domainCredential.UserName)': $($_.Exception.Message)"
    }
    if ($controller.DomainRole -lt 4) {
        throw "'$target' is not a domain controller (DomainRole $($controller.DomainRole))."
    }
    if ($controller.DnsRoot -ne $DomainName) {
        throw "'$target' is a domain controller of '$($controller.DnsRoot)', not '$DomainName'."
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
                # The name Windows suggests when you install a CA by hand.
                if (-not $caName) {
                    Import-Module ActiveDirectory
                    $caName = "$((Get-ADDomain).NetBIOSName)-$env:COMPUTERNAME-CA"
                }
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
    Write-Host "Sample user   : $($created.DemoUpn) (places orders)"
    Write-Host "Inventory admin: $($created.InventoryAdminUpn) (restocks products)"
    Write-Host "Realm admins  : oms-identity-admins (add the people who administer Keycloak's 'oms' realm)"
    if ($caCertPem) { Write-Host "LDAP          : ldaps://$($created.DcFqdn):636" }
    else { Write-Host "LDAP          : ldap://$($created.DcFqdn):389 (no TLS)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'The generated passwords were written to the cluster, never to this console.' -ForegroundColor DarkGray
    Write-Host "Read one back (base64) with:" -ForegroundColor DarkGray
    Write-Host "  kubectl --context $KubeContext -n $SecretNamespace get secret $SecretName -o jsonpath='{.data.demo-password}'"
    Write-Host 'Next, stand up Keycloak (cluster nodes already resolve the domain through this controller):' -ForegroundColor Yellow
    Write-Host "  ./scripts/infra/azurelocal/keycloak.ps1 -AdServer $($created.DcFqdn) -AdDomain $($created.DnsRoot) -SpaOrigin https://<app address> -KubeContext $KubeContext -AllowInClusterIssuer ..."
}
finally {
    Pop-Location
}
