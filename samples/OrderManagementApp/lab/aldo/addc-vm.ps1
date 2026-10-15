<#
.SYNOPSIS
    Creates a Windows Server domain controller in a Hyper-V VM alongside the Azure Local
    disconnected operations (ALDO) appliance, to act as the identity source for the demo.

.DESCRIPTION
    On AKS a workload proves who it is with a federated managed identity, which only works while
    Entra is reachable. A business continuity demo cannot make that assumption, so the directory
    has to live inside the site. Active Directory Domain Services fills that role: it keeps
    serving its own tickets and LDAP binds with no connectivity to anything outside.

    The controller is deliberately on its own VM rather than in the cluster. Azure Local requires
    AD DS to be reachable but not hosted on the cluster nodes, so building it this way now means
    the same domain can be reused when an Azure Local instance is deployed later.

    Everything after the operating system install runs over PowerShell Direct, which reaches the
    guest through the hypervisor rather than the network. That matters because the VM has no
    usable address until this script gives it one, and because a domain controller stops accepting
    its old local credentials the moment it is promoted.

    The script is safe to re-run. It skips the parts that are already done.

.PARAMETER CreateVm
    Create the Hyper-V VM and start it from -IsoPath. Windows Server is then installed
    interactively through the console: choose the Desktop Experience or Core edition, set the
    local Administrator password, and stop at the sign-in screen. Re-run without this switch, and
    with -LocalAdminCredential, to configure the domain.

.PARAMETER IpAddress
    Static address for the controller on the appliance switch. Must be free: the appliance answers
    on 10.0.60.4, the host owns 10.0.60.1, and lab/aldo/arc-k3s.ps1 takes 10.0.60.50.

.PARAMETER UpstreamDns
    Resolver the controller forwards to for names outside its own domain. Pods keep using the
    appliance resolver for everything else, so this only affects the controller itself.

.PARAMETER SkipBindSecret
    Do not write the Keycloak bind account credential into a Kubernetes Secret. By default it is
    written to the cluster so that scripts/azurelocal/keycloak.ps1 can pick it up without the password
    being typed or displayed.

.PARAMETER ExistingDomainController
    Target a domain controller that already exists and serves other systems, such as the DC01
    that a connected Azure Local instance is joined to. The VM's network settings and DNS
    forwarders are left untouched, no promotion is attempted, the directory service is not
    restarted, and an already installed certificate authority is reused. Only the AD CS role
    (if missing), the demo OU, groups and accounts are added. Pass the domain administrator as
    -LocalAdminCredential.

.EXAMPLE
    # Stage 1, elevated: create the VM, then install Windows Server through the console.
    ./lab/aldo/addc-vm.ps1 -CreateVm -IsoPath C:\iso\windows-server-2022.iso

.EXAMPLE
    # Stage 2, elevated: promote it and create the demo directory objects.
    ./lab/aldo/addc-vm.ps1 -LocalAdminCredential (Get-Credential Administrator)

.EXAMPLE
    # Connected Azure Local: reuse its domain controller, elevated on the host.
    ./lab/aldo/addc-vm.ps1 -ExistingDomainController -VmName DC01 `
        -DomainName azurelocal.lab -NetbiosName AZURELOCAL -IpAddress 192.168.44.10 -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$VmName = 'bcd-addc',
    [string]$SwitchName = 'Winfield-Ingress',

    [string]$IpAddress = '10.0.60.60',
    [int]$PrefixLength = 24,
    [string]$Gateway = '10.0.60.1',
    [string[]]$UpstreamDns = @('10.0.254.4'),

    [int]$MemoryGB = 4,
    [int]$CpuCount = 2,
    [int]$DiskGB = 64,

    [switch]$CreateVm,
    [string]$IsoPath,
    [string]$VhdPath,

    [string]$DomainName = 'bcd.lab',
    [string]$NetbiosName = 'BCD',
    [string]$OuName = 'BCD',

    [pscredential]$LocalAdminCredential,
    [securestring]$SafeModePassword,

    [string]$BindAccountName = 'svc-keycloak',
    [string]$DemoUserName = 'bcd-demo',

    [switch]$SkipBindSecret,
    [switch]$SkipCertificateAuthority,
    [string]$CaCommonName = 'BCD Lab Root CA',
    [string]$KubeContext = 'bcd-arc-k3s',
    [string]$SecretNamespace = 'identity',
    [string]$SecretName = 'bcd-ad-bind',
    [string]$CaSecretName = 'bcd-ad-ca',

    [switch]$ExistingDomainController
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
function Test-DirectoryPasswordComplexity {
    param([Parameter(Mandatory = $true)][securestring]$Password)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }

    $classes = @(
        ($plain -cmatch '[A-Z]'),
        ($plain -cmatch '[a-z]'),
        ($plain -match '\d'),
        ($plain -match '[^a-zA-Z0-9]')
    )
    $met = @($classes | Where-Object { $_ }).Count
    $long = $plain.Length -ge 12

    $plain = $null
    return ($long -and $met -ge 3)
}

# Windows installation media prompts 'Press any key to boot from CD or DVD' and gives up after
# about five seconds, at which point the firmware falls through to the empty disk and shows a
# boot-failure summary. Hyper-V exposes the VM's synthetic keyboard over WMI, so the keypress can
# be delivered without anyone having to watch the console and race the timer.
function Send-BootKeypress {
    param([int]$DurationSeconds = 25)

    $vmWmi = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem |
        Where-Object { $_.ElementName -eq $VmName }
    $keyboard = Get-CimAssociatedInstance -InputObject $vmWmi -ResultClassName Msvm_Keyboard
    if (-not $keyboard) {
        Write-Warning 'No synthetic keyboard found. Press a key in the console when prompted.'
        return
    }

    $spaceKey = 0x20
    $deadline = (Get-Date).AddSeconds($DurationSeconds)
    while ((Get-Date) -lt $deadline) {
        Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey `
            -Arguments @{ keyCode = $spaceKey } -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Milliseconds 400
    }
}

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

    # ------------------------------------------------------------------------------------------
    # Stage 1: the VM.
    # ------------------------------------------------------------------------------------------
    if ($CreateVm) {
        if (-not $IsoPath) {
            throw 'Pass -IsoPath. Unlike Ubuntu, a Windows Server image cannot be downloaded unattended.'
        }
        if (-not (Test-Path $IsoPath)) {
            throw "No ISO at '$IsoPath'."
        }
        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
            throw "No Hyper-V switch named '$SwitchName'. The appliance normally creates it."
        }
        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
            throw "A VM named '$VmName' already exists. Remove it, or re-run without -CreateVm."
        }

        if (-not $VhdPath) {
            $vhdRoot = (Get-VMHost).VirtualHardDiskPath
            $VhdPath = Join-Path $vhdRoot "$VmName.vhdx"
        }
        if (Test-Path $VhdPath) {
            throw "A disk already exists at '$VhdPath'."
        }

        Write-Host "==> Creating '$VmName' on switch $SwitchName" -ForegroundColor Cyan
        $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
            -NewVHDPath $VhdPath -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName

        # A domain controller holds the directory in memory and pages badly, so give it a fixed
        # allocation rather than letting dynamic memory squeeze it.
        Set-VM -VM $vm -StaticMemory -ProcessorCount $CpuCount `
            -AutomaticStartAction StartIfRunning -AutomaticStopAction ShutDown

        # Windows Server images are signed by the Microsoft Windows CA, not the UEFI CA that
        # Linux images use, so the default Secure Boot template is correct here.
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

        Add-VMDvdDrive -VM $vm -Path $IsoPath
        $dvd = Get-VMDvdDrive -VM $vm
        Set-VMFirmware -VM $vm -FirstBootDevice $dvd

        Start-VM -VM $vm

        Write-Host '==> Answering the boot prompt' -ForegroundColor Cyan
        Send-BootKeypress

        Write-Host "`nVM started. Open the console and install Windows Server:" -ForegroundColor Yellow
        Write-Host "  vmconnect.exe localhost $VmName"
        Write-Host ''
        Write-Host 'Set a local Administrator password and stop at the sign-in screen. Leave the'
        Write-Host 'network alone; this script assigns the address. Then re-run elevated:'
        Write-Host "  ./lab/aldo/addc-vm.ps1 -LocalAdminCredential (Get-Credential Administrator)"
        return
    }

    # ------------------------------------------------------------------------------------------
    # Stage 2: the domain.
    # ------------------------------------------------------------------------------------------
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "No VM named '$VmName'. Create it first with -CreateVm."
    }
    if ($vm.State -ne 'Running') {
        Write-Host "==> Starting '$VmName'" -ForegroundColor Cyan
        Start-VM -Name $VmName
    }

    if (-not $LocalAdminCredential) {
        if ($ExistingDomainController) {
            $LocalAdminCredential = Get-Credential -UserName "$NetbiosName\Administrator" `
                -Message "Domain administrator of '$DomainName' on '$VmName'"
        }
        else {
            $LocalAdminCredential = Get-Credential -UserName 'Administrator' `
                -Message "Local Administrator of '$VmName' (before promotion)"
        }
    }

    # After promotion the local account is gone and the same password belongs to the domain
    # account, so both credentials are kept and used at the right points.
    $domainCredential = [pscredential]::new(
        "$NetbiosName\$($LocalAdminCredential.UserName -replace '^.*\\', '')",
        $LocalAdminCredential.Password)

    Write-Host "==> Waiting for PowerShell Direct on '$VmName'" -ForegroundColor Cyan
    $bootCredential = Wait-GuestReady -Credential $LocalAdminCredential, $domainCredential `
        -TimeoutMinutes 15 -What 'the administrator account'

    # NTLM falls back to the local SAM when the domain prefix does not resolve, so a credential
    # being accepted says nothing about promotion; the guest's own role is the authoritative answer.
    $domainRole = [int](Invoke-Guest -Credential $bootCredential -ScriptBlock {
            (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
        })
    $alreadyPromoted = $domainRole -ge 4
    if ($alreadyPromoted) {
        Write-Host '    already promoted; continuing with the domain account' -ForegroundColor DarkGray
        $bootCredential = $domainCredential
    }
    elseif ($ExistingDomainController) {
        throw "'$VmName' is not a domain controller (DomainRole $domainRole), but -ExistingDomainController was passed."
    }

    if ($ExistingDomainController) {
        Write-Host "==> Leaving the network configuration of '$VmName' unchanged" -ForegroundColor DarkGray
    }
    else {
        Write-Host "==> Configuring the network interface" -ForegroundColor Cyan
        Invoke-Guest -Credential $bootCredential -ArgumentList $IpAddress, $PrefixLength, $Gateway, $UpstreamDns -ScriptBlock {
            param($ip, $prefix, $gateway, $dns)
            $ErrorActionPreference = 'Stop'

            $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
            if (-not $adapter) { throw 'No connected network adapter inside the VM.' }

            $current = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($current.IPAddress -ne $ip) {
                $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip `
                    -PrefixLength $prefix -DefaultGateway $gateway | Out-Null
            }

            # Before promotion the controller needs an outside resolver to reach the internet; the
            # promotion itself repoints this at the loopback DNS it installs.
            if (-not (Get-Service NTDS -ErrorAction SilentlyContinue)) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns
            }

            "  $ip/$prefix via $gateway"
        }
    }

    if (-not $alreadyPromoted) {
        $complexityRule = 'at least 12 characters, using three of: uppercase, lowercase, digits, symbols'

        if ($SafeModePassword) {
            if (-not (Test-DirectoryPasswordComplexity -Password $SafeModePassword)) {
                throw "The -SafeModePassword is too weak: $complexityRule."
            }
        }
        else {
            $accepted = $false
            foreach ($attempt in 1..3) {
                $SafeModePassword = Read-Host -AsSecureString `
                    -Prompt "Directory Services Restore Mode password ($complexityRule; store it, it is needed to repair the directory)"
                if (Test-DirectoryPasswordComplexity -Password $SafeModePassword) { $accepted = $true; break }
                Write-Warning "Too weak: $complexityRule."
            }
            if (-not $accepted) { throw 'No acceptable Directory Services Restore Mode password was supplied.' }
        }

        Write-Host "==> Installing AD DS and promoting to a forest root" -ForegroundColor Cyan
        Write-Host '    the VM reboots partway through this step' -ForegroundColor DarkGray

        Invoke-Guest -Credential $bootCredential -ArgumentList $DomainName, $NetbiosName, $SafeModePassword -ScriptBlock {
            param($domain, $netbios, $safeMode)
            $ErrorActionPreference = 'Stop'

            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

            Import-Module ADDSDeployment
            # -Force suppresses the confirmation prompts, which cannot be answered over
            # PowerShell Direct. The reboot is what ends this session.
            Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios `
                -SafeModeAdministratorPassword $safeMode -InstallDns `
                -DomainMode WinThreshold -ForestMode WinThreshold `
                -NoRebootOnCompletion:$false -Force | Out-Null
        }

        Write-Host "==> Waiting for the controller to come back up" -ForegroundColor Cyan
        # The reboot is not instant, and the local credential keeps working until it happens.
        Start-Sleep -Seconds 60
        $null = Wait-GuestReady -Credential $domainCredential -TimeoutMinutes 20 -What 'the promoted controller'
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

    if ($ExistingDomainController) {
        Write-Host "==> Leaving the DNS forwarders of '$VmName' unchanged" -ForegroundColor DarkGray
    }
    else {
        Write-Host "==> Pointing DNS forwarding at $($UpstreamDns -join ', ')" -ForegroundColor Cyan
        Invoke-Guest -Credential $domainCredential -ArgumentList (, $UpstreamDns) -ScriptBlock {
            param($dns)
            $ErrorActionPreference = 'Stop'

            # Root hints are useless in a disconnected site, so every name the controller is not
            # authoritative for goes to the appliance resolver instead.
            Set-DnsServerForwarder -IPAddress $dns -UseRootHint $false
        }
    }

    # A domain controller only opens LDAPS once it holds a certificate with the Server
    # Authentication EKU. An Enterprise CA publishes the DC templates into AD, and the controller
    # auto-enrols against them, so standing one up is what turns port 636 from a socket that
    # accepts and drops into a working TLS endpoint.
    $caCertPem = $null
    if (-not $SkipCertificateAuthority) {
        Write-Host "==> Installing an enterprise certificate authority" -ForegroundColor Cyan
        $caCertPem = Invoke-Guest -Credential $domainCredential -ArgumentList $CaCommonName, $ExistingDomainController.IsPresent -ScriptBlock {
            param($caName, $sharedController)
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

            # Restarting the directory makes it pick the new certificate up immediately. A shared
            # controller is not restarted: the rootDSE 'renewServerCertificate' operation tells
            # LDAP to reload its certificate without interrupting anything else.
            if ($sharedController) {
                $rootDse = [System.DirectoryServices.DirectoryEntry]::new('LDAP://localhost/RootDSE')
                $rootDse.Properties['renewServerCertificate'].Value = 1
                $rootDse.CommitChanges()
                $rootDse.Dispose()
            }
            else {
                Restart-Service NTDS -Force
            }

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

        foreach ($group in 'bcd-app-readers', 'bcd-app-writers') {
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
        Add-ADGroupMember -Identity 'bcd-app-readers' -Members $demoName -ErrorAction SilentlyContinue
        Add-ADGroupMember -Identity 'bcd-app-writers' -Members $demoName -ErrorAction SilentlyContinue

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
                $caFile = Join-Path ([IO.Path]::GetTempPath()) "bcd-ad-ca-$PID.crt"
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
    Write-Host "VM            : $VmName at $IpAddress on switch $SwitchName"
    Write-Host "Domain        : $($created.DnsRoot) ($NetbiosName)"
    Write-Host "Controller    : $($created.DcFqdn)"
    Write-Host "Search base   : $($created.BaseDn)"
    Write-Host "Demo OU       : $($created.OuDn)"
    Write-Host "Bind account  : $($created.BindUpn)"
    Write-Host "Sample user   : $($created.DemoUpn)"
    if ($caCertPem) { Write-Host "LDAP          : ldaps://$($created.DcFqdn):636 ($CaCommonName)" }
    else { Write-Host "LDAP          : ldap://$IpAddress`:389 (no TLS)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'The generated passwords were written to the cluster, never to this console.' -ForegroundColor DarkGray
    Write-Host "Read them back with:" -ForegroundColor DarkGray
    Write-Host "  kubectl --context $KubeContext -n $SecretNamespace get secret $SecretName -o jsonpath='{.data.bind-password}'"
    Write-Host ''
    if ($ExistingDomainController) {
        Write-Host 'Next, stand up Keycloak (cluster nodes already resolve the domain through this controller):' -ForegroundColor Yellow
        Write-Host "  ./scripts/azurelocal/keycloak.ps1 -AdServer $($created.DcFqdn) -AdDomain $($created.DnsRoot) -KubeContext $KubeContext -AllowInClusterIssuer ..."
        return
    }
    Write-Host 'Next, let the cluster resolve the domain and stand up Keycloak:' -ForegroundColor Yellow
    Write-Host "  ./lab/aldo/arc-k3s.ps1 -SkipK3sInstall -SkipArcConnect -AdDomain $($created.DnsRoot) -AdDnsServer $IpAddress"
    if ($caCertPem) {
        Write-Host "  ./scripts/azurelocal/keycloak.ps1 -AdServer $($created.DcFqdn) -AdDomain $($created.DnsRoot)"
    }
    else {
        Write-Host "  ./scripts/azurelocal/keycloak.ps1 -AdServer $IpAddress -AdDomain $($created.DnsRoot)"
    }
}
finally {
    Pop-Location
}
