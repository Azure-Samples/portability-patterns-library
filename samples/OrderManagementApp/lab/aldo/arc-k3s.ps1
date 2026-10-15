<#
.SYNOPSIS
    Creates a k3s cluster in a Hyper-V VM and Arc-enables it against the Azure Local disconnected
    operations (ALDO) control plane.

.DESCRIPTION
    This is the alternative to lab/aldo/provision-infra.ps1 for environments whose ALDO
    appliance does not carry the AKS platform extension pack. Check what the appliance supports:

      Get-ChildItem C:\azurelocal\PlatformExtensionPacks

    If there is an 'arcenabledkubernetesagents' pack but nothing for HybridContainerService, then
    'az aksarc create' has no resource bridge to target and this script is the supported shape:
    bring your own cluster and register it as Microsoft.Kubernetes/connectedClusters.

    The VM attaches to the appliance's own Hyper-V switch, so it shares a layer 2 segment with the
    control plane and reaches the internet through the NAT the appliance already configured. That
    avoids the WSL2 network translation a Docker/kind setup would have to cross.

    Three things are copied from this host into the cluster, because none of them are discoverable
    from inside it:

      * the appliance host file entries, which stand in for the DNS zone ALDO does not serve
      * the appliance root CA, which the Arc agents must trust to reach the local ARM endpoint
      * the ARM endpoint itself, read from the active az CLI cloud

    The cluster is also configured to issue ServiceAccount tokens that a verifier outside the
    cluster can check. k3s already signs them, but under the default issuer name
    'https://kubernetes.default.svc.cluster.local', which nothing outside the cluster can resolve.
    Repointing the issuer at the API server's own address, and opening the OIDC discovery
    endpoints to unauthenticated callers, is what lets Keycloak accept those tokens. That is the
    disconnected stand-in for Entra workload identity federation: workloads obtain credentials
    from the domain and Keycloak, so nothing on the request path depends on Arc or ARM being
    reachable. Arc registration below is for cluster management only.

.PARAMETER CreateVm
    Create the Hyper-V VM and start it from -IsoPath. Requires an elevated session. Ubuntu Server
    is installed interactively, because its installer can only import SSH identities from GitHub or
    Launchpad: complete it with the user name passed as -SshUser, the static address passed as
    -IpAddress, and OpenSSH enabled. The script prints the command that authorises -SshPublicKeyPath
    afterwards. Re-run without this switch to configure the cluster.

.PARAMETER IpAddress
    Static address for the VM on the appliance switch. Must be free: the appliance itself answers
    on 10.0.60.4 and the host owns 10.0.60.1.

.PARAMETER AdDomain
    Active Directory domain to forward from CoreDNS to -AdDnsServer, so pods can resolve the
    domain controller created by lab/aldo/addc-vm.ps1. Both are needed for forwarding.

.PARAMETER SkipOidcIssuer
    Leave the API server on its default, cluster-internal token issuer.

.PARAMETER SkipArcConnect
    Build the cluster but stop before registering it with ALDO.

.EXAMPLE
    # Stage 1, elevated: create the VM, then install Ubuntu Server through the console.
    ./lab/aldo/arc-k3s.ps1 -CreateVm -IsoPath C:\iso\ubuntu-24.04.5-live-server-amd64.iso

.EXAMPLE
    # Stage 2: install k3s, trust the appliance CA and Arc-enable the cluster.
    ./lab/aldo/arc-k3s.ps1

.EXAMPLE
    # Also forward the AD zone to the domain controller.
    ./lab/aldo/arc-k3s.ps1 -AdDomain bcd.lab -AdDnsServer 10.0.60.60
#>
[CmdletBinding()]
param(
    [string]$VmName = 'bcd-arc-k3s',
    [string]$SwitchName = 'Winfield-Ingress',

    [string]$IpAddress = '10.0.60.50',
    [int]$PrefixLength = 24,
    [string]$Gateway = '10.0.60.1',
    [string[]]$DnsServers = @('10.0.254.4'),

    [int]$MemoryGB = 8,
    [int]$CpuCount = 4,
    [int]$DiskGB = 64,

    [switch]$CreateVm,
    [string]$IsoPath,
    [string]$VhdPath,

    [string]$SshUser = 'bcd',
    [string]$SshKeyPath = "$HOME\.ssh\id_ed25519",
    [string]$SshPublicKeyPath = "$HOME\.ssh\id_ed25519.pub",

    [string]$ClusterName = 'bcd-arc-k3s',
    [string]$KubeContext = 'bcd-arc-k3s',
    [string]$ResourceGroup = 'bcd-infra',
    [string]$Location,

    [string]$AdDomain,
    [string]$AdDnsServer,

    [switch]$SkipK3sInstall,
    [switch]$SkipOidcIssuer,
    [switch]$SkipArcConnect
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

# $ErrorActionPreference does not apply to native commands, so every external call is checked.
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

# Runs an 'az' command that is allowed to fail and returns its output, or $null.
# PowerShell turns redirected native stderr into a terminating error while $ErrorActionPreference
# is 'Stop', which would abort the script before a probe can report 'not found'.
function Invoke-AzProbe {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs)

    $ErrorActionPreference = 'Continue'

    $output = az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$Script
    )

    # The script travels as an argument rather than on stdin, and -tt allocates a terminal, so sudo
    # can prompt for its password instead of failing on a missing tty. Line endings are normalised
    # because bash treats a trailing carriage return as part of the command.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n")))

    # 'accept-new' trusts the key on first sight but still detects later changes.
    & ssh -tt -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
        -i $SshKeyPath "$SshUser@$IpAddress" "echo $encoded | base64 -d | sudo bash -euo pipefail -s"
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

# The appliance publishes its endpoints through this host's hosts file rather than a DNS zone, so
# the cluster can only learn them by copying what the appliance module wrote here.
function Get-ApplianceHostEntry {
    param([Parameter(Mandatory = $true)][string]$Zone)

    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $pattern = '^\s*(?<ip>\d{1,3}(\.\d{1,3}){3})\s+(?<name>\S+\.' + [regex]::Escape($Zone) + ')\s*(?:#.*)?$'

    Select-String -Path $hostsFile -Pattern $pattern | ForEach-Object {
        [pscustomobject]@{
            Ip   = $_.Matches[0].Groups['ip'].Value
            Name = $_.Matches[0].Groups['name'].Value
        }
    }
}

# Reads the appliance root CA off the TLS handshake. The callback accepts the presented chain
# because no request is ever sent on this connection; the chain is then rebuilt below and required
# to terminate at that same certificate.
function Export-ApplianceCaCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $captured = $null
    $client = [System.Net.Sockets.TcpClient]::new($HostName, 443)
    try {
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($sender, $certificate, $chain, $errors)
            # The handles behind these certificates are freed with the stream, so copy the raw data.
            $script:capturedChain = @($chain.ChainElements | ForEach-Object {
                    [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($_.Certificate.RawData)
                })
            return $true
        }

        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        try {
            $ssl.AuthenticateAsClient($HostName)
            $captured = $script:capturedChain
        }
        finally { $ssl.Dispose() }
    }
    finally { $client.Dispose() }

    if (-not $captured -or $captured.Count -lt 2) {
        throw "The TLS chain presented by '$HostName' carries no issuing certificate to trust."
    }

    $root = $captured[-1]
    if ($root.Subject -ne $root.Issuer) {
        throw "The top of the chain presented by '$HostName' is not self-signed, so it is not a root CA."
    }

    $leaf = $captured[0]
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    # Windows PowerShell has no CustomTrustStore, so the unknown anchor is waived here and the
    # chain is then required to terminate at the captured root, which is the same guarantee.
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    $captured | Select-Object -Skip 1 | ForEach-Object { $chain.ChainPolicy.ExtraStore.Add($_) | Out-Null }

    if (-not $chain.Build($leaf)) {
        $status = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join '; '
        throw "The certificate of '$HostName' does not validate against the captured root: $status"
    }

    $builtRoot = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
    if ($builtRoot.Thumbprint -ne $root.Thumbprint) {
        throw "The certificate of '$HostName' chains to '$($builtRoot.Subject)', not to the captured root."
    }

    $base64 = [Convert]::ToBase64String($root.RawData, [Base64FormattingOptions]::InsertLineBreaks)
    $pem = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n"
    Set-Content -Path $Path -Value $pem -Encoding ascii

    return $root.Subject
}

try {
    foreach ($tool in @('ssh', 'kubectl', 'az')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' is not on PATH."
        }
    }

    # ------------------------------------------------------------------------------------------
    # Stage 1: the VM. Separate because Hyper-V needs elevation and Ubuntu installs interactively.
    # ------------------------------------------------------------------------------------------
    if ($CreateVm) {
        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isElevated) { throw 'Creating the VM needs an elevated session. Re-run as administrator.' }
        if (-not $IsoPath -or -not (Test-Path $IsoPath)) { throw "Pass -IsoPath to an Ubuntu Server ISO." }
        if (-not (Test-Path $SshPublicKeyPath)) { throw "No SSH public key at '$SshPublicKeyPath'. Create one with 'ssh-keygen'." }

        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
            throw "Hyper-V switch '$SwitchName' does not exist. The appliance normally creates it."
        }
        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
            throw "VM '$VmName' already exists. Remove it, or re-run without -CreateVm to configure it."
        }

        if (-not $VhdPath) {
            $vhdRoot = (Get-VMHost).VirtualHardDiskPath
            $VhdPath = Join-Path $vhdRoot "$VmName.vhdx"
        }

        Write-Host "==> Creating VM '$VmName' on switch '$SwitchName'" -ForegroundColor Cyan
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
            -NewVHDPath $VhdPath -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName | Out-Null

        # Static memory keeps the VM from competing with the appliance for the free RAM.
        Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $VmName -Count $CpuCount
        Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false

        Add-VMDvdDrive -VMName $VmName -Path $IsoPath
        $dvd = Get-VMDvdDrive -VMName $VmName
        Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd `
            -SecureBootTemplate MicrosoftUEFICertificateAuthority

        Start-VM -Name $VmName

        Write-Host "`n================ Finish the install in the console ================" -ForegroundColor Green
        Write-Host "  vmconnect.exe localhost $VmName"
        Write-Host ""
        Write-Host "  Network          : the switch has no DHCP, so choose Manual IPv4 on eth0"
        Write-Host "    Subnet         : $(($IpAddress -replace '\.\d+$', '.0'))/$PrefixLength"
        Write-Host "    Address        : $IpAddress"
        Write-Host "    Gateway        : $Gateway"
        Write-Host "    Name servers   : $($DnsServers -join ', ')"
        Write-Host "  User name        : $SshUser   (with a password: the installer cannot import a key)"
        Write-Host "  Install OpenSSH  : yes, and skip 'Import SSH identity'"
        Write-Host ""
        Write-Host "After the first boot, authorise this machine's key (one password prompt):" -ForegroundColor Yellow
        Write-Host "  Get-Content '$SshPublicKeyPath' | ssh $SshUser@$IpAddress ""mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"""
        Write-Host ""
        Write-Host "If the VM boots the installer again, eject the ISO (elevated):" -ForegroundColor Yellow
        Write-Host "  Set-VMDvdDrive -VMName $VmName -Path `$null"
        Write-Host ""
        Write-Host "Then re-run this script without -CreateVm." -ForegroundColor Yellow
        return
    }

    # ------------------------------------------------------------------------------------------
    # Stage 2: the cluster.
    # ------------------------------------------------------------------------------------------
    $armEndpoint = Invoke-AzProbe @('cloud', 'show', '--query', 'endpoints.resourceManager', '--output', 'tsv')
    if (-not $armEndpoint) { throw "Could not read the active az CLI cloud. Run 'az login' first." }

    $cloudName = Invoke-AzProbe @('cloud', 'show', '--query', 'name', '--output', 'tsv')
    if ($cloudName -eq 'AzureCloud') {
        throw "The az CLI is pointed at public Azure. Select the local cloud with 'az cloud set' first."
    }

    $armHost = ([uri]$armEndpoint).Host
    Write-Host "==> ALDO control plane: $armEndpoint" -ForegroundColor Cyan

    # Everything the appliance publishes sits under the ARM endpoint's parent domain.
    $zone = $armHost.Substring($armHost.IndexOf('.') + 1)
    Write-Host "    zone $zone" -ForegroundColor DarkGray

    $applianceHosts = @(Get-ApplianceHostEntry -Zone $zone)
    if ($applianceHosts.Count -eq 0) {
        throw "No '*.$zone' entries in this machine's hosts file. The appliance module normally writes them."
    }
    Write-Host "    $($applianceHosts.Count) appliance host entries to copy" -ForegroundColor DarkGray

    # Only Arc registration needs ARM. Everything else here is local or over SSH, so with
    # -SkipArcConnect the script stays usable when the ARM token has expired.
    if (-not $SkipArcConnect) {
        if ([string]::IsNullOrWhiteSpace((az extension list --query "[?name=='connectedk8s'].name" --output tsv))) {
            Write-Host "==> Installing the 'connectedk8s' az CLI extension" -ForegroundColor Cyan
            Invoke-Checked 'az extension add connectedk8s' {
                az extension add --name connectedk8s --only-show-errors
            }
        }

        # An unregistered provider is not an error: ARM just refuses the resource type at create time.
        Write-Host "==> Ensuring resource providers are registered" -ForegroundColor Cyan
        foreach ($provider in @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')) {
            $state = Invoke-AzProbe @('provider', 'show', '--namespace', $provider, '--query', 'registrationState', '--output', 'tsv')
            if ($state -eq 'Registered') { continue }

            Write-Host "    registering $provider ($state)" -ForegroundColor DarkGray
            Invoke-Checked "az provider register $provider" {
                az provider register --namespace $provider --wait --output none
            }
        }
    }

    Write-Host "==> Reading the appliance root CA" -ForegroundColor Cyan
    $caPath = Join-Path ([System.IO.Path]::GetTempPath()) 'aldo-root-ca.crt'
    $caSubject = Export-ApplianceCaCertificate -HostName $armHost -Path $caPath
    Write-Host "    $caSubject" -ForegroundColor DarkGray

    Write-Host "==> Checking SSH to $SshUser@$IpAddress" -ForegroundColor Cyan
    Invoke-RemoteScript -What 'ssh connectivity check' -Script 'echo "  $(hostname) is reachable"'

    $hostsBlock = ($applianceHosts | ForEach-Object { "$($_.Ip)`t$($_.Name)" }) -join "`n"
    $caPem = (Get-Content $caPath -Raw)

    Write-Host "==> Publishing appliance endpoints and CA to the VM" -ForegroundColor Cyan
    Invoke-RemoteScript -What 'VM trust configuration' -Script @"
sed -i '/# ALDO appliance/,+$($applianceHosts.Count)d' /etc/hosts
{
  echo '# ALDO appliance'
  cat <<'HOSTS'
$hostsBlock
HOSTS
} >> /etc/hosts

cat > /usr/local/share/ca-certificates/aldo-root-ca.crt <<'PEM'
$caPem
PEM
update-ca-certificates >/dev/null
echo "  trust store updated"
"@

    # The name the API server signs ServiceAccount tokens under. It has to be an address the
    # verifier can actually open, which the default cluster-internal name is not.
    $issuerUrl = "https://${IpAddress}:6443"

    if (-not $SkipOidcIssuer) {
        Write-Host "==> Setting the ServiceAccount token issuer to $issuerUrl" -ForegroundColor Cyan

        # Written before the install below so a fresh cluster comes up correct on first boot.
        Invoke-RemoteScript -What 'token issuer configuration' -Script @"
mkdir -p /etc/rancher/k3s

# New tokens are signed with the first issuer. The default one stays in the list so tokens already
# mounted into running pods keep validating until those pods restart.
cat > /etc/rancher/k3s/config.yaml <<'YAML'
kube-apiserver-arg:
  - "service-account-issuer=$issuerUrl"
  - "service-account-issuer=https://kubernetes.default.svc.cluster.local"
  - "api-audiences=https://kubernetes.default.svc.cluster.local,$issuerUrl"
YAML

if systemctl is-active --quiet k3s; then
  systemctl restart k3s
  k3s kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
  echo "  k3s restarted onto the new issuer"
else
  echo "  k3s not running yet; the install below will pick this up"
fi
"@
    }

    if (-not $SkipK3sInstall) {
        Write-Host "==> Installing k3s (reaches the internet through the appliance NAT)" -ForegroundColor Cyan
        Invoke-RemoteScript -What 'k3s install' -Script @"
if systemctl is-active --quiet k3s; then
  echo "  k3s already running"
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san $IpAddress --disable traefik" sh -
fi
k3s kubectl wait --for=condition=Ready node --all --timeout=180s

# Keep a copy the login user can read, so fetching it needs no further sudo prompt.
install -d -o $SshUser -g $SshUser -m 700 /home/$SshUser/.kube
install -o $SshUser -g $SshUser -m 600 /etc/rancher/k3s/k3s.yaml /home/$SshUser/.kube/config
"@
    }

    Write-Host "==> Fetching kubeconfig" -ForegroundColor Cyan
    $kubeConfigRaw = & ssh -o StrictHostKeyChecking=accept-new -i $SshKeyPath "$SshUser@$IpAddress" `
        'cat ~/.kube/config'
    if ($LASTEXITCODE -ne 0) { throw "Could not read ~/.kube/config from the VM." }

    $kubeConfig = ($kubeConfigRaw | Out-String).
        Replace('https://127.0.0.1:6443', "https://${IpAddress}:6443").
        Replace('name: default', "name: $KubeContext").
        Replace('cluster: default', "cluster: $KubeContext").
        Replace('user: default', "user: $KubeContext").
        Replace('current-context: default', "current-context: $KubeContext")

    $kubeDir = Join-Path $HOME '.kube'
    New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null
    $clusterConfig = Join-Path $kubeDir "$KubeContext.config"
    Set-Content -Path $clusterConfig -Value $kubeConfig -Encoding ascii

    # Merge so that deploy.ps1 -KubeContext works against the default kubeconfig.
    $mainConfig = Join-Path $kubeDir 'config'
    if (Test-Path $mainConfig) {
        $env:KUBECONFIG = "$mainConfig;$clusterConfig"
        $merged = kubectl config view --flatten
        $env:KUBECONFIG = $null
        if ($LASTEXITCODE -eq 0) {
            Copy-Item $mainConfig "$mainConfig.bak" -Force
            Set-Content -Path $mainConfig -Value ($merged | Out-String) -Encoding ascii
        }
    }
    else {
        Copy-Item $clusterConfig $mainConfig
    }

    Invoke-Checked 'kubectl cluster-info' {
        kubectl cluster-info --context $KubeContext --request-timeout=30s | Out-Null
    }

    if (-not $SkipOidcIssuer) {
        # A verifier fetches /.well-known/openid-configuration and the JWKS before it has any
        # credential for this cluster, so those two paths have to answer anonymously. The built-in
        # role covers exactly those paths and nothing else.
        Write-Host "==> Opening OIDC discovery to unauthenticated callers" -ForegroundColor Cyan
        @"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: service-account-issuer-discovery-unauthenticated
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:service-account-issuer-discovery
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:unauthenticated
"@ | kubectl --context $KubeContext apply -f - | Out-Null

        $discovery = kubectl --context $KubeContext get --raw /.well-known/openid-configuration 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'The API server did not serve an OIDC discovery document.' }

        $reportedIssuer = ($discovery | ConvertFrom-Json).issuer
        if ($reportedIssuer -ne $issuerUrl) {
            throw "The API server still reports issuer '$reportedIssuer'. Expected '$issuerUrl'."
        }
        Write-Host "    issuer $reportedIssuer" -ForegroundColor DarkGray
    }

    # Pods resolve through CoreDNS, which knows nothing about the appliance endpoints. k3s imports
    # any '*.server' key of the coredns-custom ConfigMap as an extra server block. A separate block
    # is required because the default one already uses the 'hosts' plugin for NodeHosts, and that
    # plugin may appear only once per block.
    Write-Host "==> Teaching CoreDNS the appliance endpoints" -ForegroundColor Cyan

    # k3s applies its bundled manifests shortly after the node reports Ready.
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (kubectl --context $KubeContext -n kube-system get deployment coredns --ignore-not-found --output name)) {
        if ((Get-Date) -gt $deadline) { throw 'CoreDNS never appeared in kube-system.' }
        Start-Sleep -Seconds 5
    }

    $ingressIps = @($applianceHosts | Select-Object -ExpandProperty Ip -Unique)
    if ($ingressIps.Count -eq 1) {
        # Every endpoint answers on one ingress address, so serve the whole zone. That also covers
        # names the appliance never wrote to the hosts file, such as per-registry endpoints.
        $zoneEscaped = $zone -replace '\.', '\.'
        $zoneBody = @"
        template IN A $zone {
            match .*\.$zoneEscaped\.`$
            answer "{{ .Name }} 60 IN A $($ingressIps[0])"
        }
        template IN AAAA $zone {
            match .*\.$zoneEscaped\.`$
            rcode NOERROR
        }
"@
    }
    else {
        $entries = ($applianceHosts | ForEach-Object { "                $($_.Ip) $($_.Name)" }) -join "`n"
        $zoneBody = @"
        hosts {
$entries
            fallthrough
        }
"@
    }

    # Pods that bind to the directory, or exchange a token at Keycloak by its domain name, need
    # the AD zone resolved by the domain controller rather than the appliance resolver.
    $adServerBlock = ''
    if ($AdDomain -and $AdDnsServer) {
        Write-Host "    forwarding $AdDomain to $AdDnsServer" -ForegroundColor DarkGray
        $adServerBlock = @"
  ad.server: |
    $($AdDomain):53 {
        errors
        forward . $AdDnsServer
    }
"@
    }
    elseif ($AdDomain -or $AdDnsServer) {
        throw 'Pass both -AdDomain and -AdDnsServer, or neither.'
    }

    $coreDnsPatch = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  aldo.server: |
    $($zone):53 {
        errors
$zoneBody
    }
$adServerBlock
"@
    $coreDnsPatch | kubectl --context $KubeContext apply -f - | Out-Null
    Invoke-Checked 'coredns restart' {
        kubectl --context $KubeContext -n kube-system rollout restart deployment coredns | Out-Null
    }
    Invoke-Checked 'coredns rollout' {
        kubectl --context $KubeContext -n kube-system rollout status deployment coredns --timeout=120s | Out-Null
    }

    if ($SkipArcConnect) {
        Write-Host "`nCluster ready. Skipping Arc registration as requested." -ForegroundColor Yellow
        return
    }

    if (-not $Location) {
        $Location = Invoke-AzProbe @('account', 'list-locations', '--query', '[0].name', '--output', 'tsv')
        if (-not $Location) { throw 'Could not determine a location. Pass -Location explicitly.' }
    }

    Invoke-Checked 'az group create' {
        az group create --name $ResourceGroup --location $Location --output none
    }

    $existing = Invoke-AzProbe @('connectedk8s', 'show', '--name', $ClusterName, '--resource-group', $ResourceGroup, '--query', 'name', '--output', 'tsv')
    if ($existing) {
        Write-Host "==> Cluster '$ClusterName' is already Arc-enabled" -ForegroundColor DarkGray
    }
    else {
        Write-Host "==> Arc-enabling '$ClusterName' against $cloudName" -ForegroundColor Cyan
        Invoke-Checked 'az connectedk8s connect' {
            az connectedk8s connect --name $ClusterName --resource-group $ResourceGroup `
                --location $Location --kube-context $KubeContext --custom-ca-cert $caPath `
                --disable-auto-upgrade --output none
        }
    }

    Write-Host "`n================ Arc cluster ready ================" -ForegroundColor Green
    Write-Host "Cloud            : $cloudName"
    Write-Host "Connected cluster: $ClusterName (resource group $ResourceGroup)"
    Write-Host "VM               : $VmName at $IpAddress on switch $SwitchName"
    Write-Host "kubectl context  : $KubeContext"
    if (-not $SkipOidcIssuer) {
        Write-Host "Token issuer     : $issuerUrl"
    }
    Write-Host ""
    Write-Host "Verify the ARM resource with:" -ForegroundColor Yellow
    Write-Host "  az connectedk8s show --name $ClusterName --resource-group $ResourceGroup --output table"
    Write-Host ""
    Write-Host "Then deploy the app onto it:" -ForegroundColor Yellow
    Write-Host "  ./lab/aldo/deploy.ps1 -Registry <login-server> -KubeContext $KubeContext"
}
finally {
    Pop-Location
}
