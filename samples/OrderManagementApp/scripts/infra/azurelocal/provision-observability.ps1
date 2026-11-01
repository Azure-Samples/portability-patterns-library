#Requires -Version 7.0
<#
.SYNOPSIS
    Monitoring, logs and traces for the Azure Local site, kept in the cluster: an OpenTelemetry
    Collector the app sends its telemetry to, Prometheus and Alertmanager for metrics and alerts,
    Loki for logs, Tempo for traces, and Grafana behind Keycloak sign-in.

.DESCRIPTION
    Platform layer, like provision-ingress.ps1. Nothing here depends on Azure: every image comes from
    the connected registry and every store is a volume in the cluster, so the site keeps its
    dashboards and alerts when the link to Azure is down. On Azure, Azure Monitor does this job.

    Installs into namespace 'observability', each from its own Helm chart with the values in
    infra/azurelocal/observability/<chart>/values.yaml; this script sets only the site values:
      1. kube-prometheus-stack: Prometheus, Alertmanager, Grafana, kube-state-metrics,
         node-exporter and the operator. Grafana is at -GrafanaUrl on the app's ingress, signs
         people in through Keycloak's 'grafana' client only, and trusts the site CA to reach it.
      2. Loki and Tempo, one process each, storing on their own volume.
      3. The OpenTelemetry Collector, as Service otel-collector: OTLP in on 4317 (gRPC) and 4318
         (HTTP); traces out to Tempo, logs to Loki, metrics for Prometheus to scrape. The app gets
         OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317.
      4. infra/azurelocal/observability/monitoring: scraping of RabbitMQ and cert-manager, the
         app's alerts and its Grafana dashboard.
    Alertmanager emails alerts when -SmtpHost is set, and otherwise only shows them.

    Generates Grafana's admin password once and keeps it in Secret observability/grafana-admin;
    nobody signs in with it, since the login form and basic auth are off. Idempotent.

    Prerequisites: scripts/infra/azurelocal/connected-registry.ps1 (the images, and the pull secret
    in 'observability'), provision-ingress.ps1 (ingress and site CA) and keycloak.ps1 (the 'grafana'
    client and its secret). A realm imported before the 'grafana' client existed needs
    keycloak.ps1 -ReimportRealm.

.PARAMETER GrafanaUrl
    Where people open Grafana, with its path and no trailing slash, such as
    https://10.0.0.50/grafana. Grafana is served under that path on the app's ingress address, so it
    must not be the root. Omit to use GRAFANA_ORIGIN from the keycloak-realm-settings ConfigMap,
    which keycloak.ps1 wrote for the realm's redirect address.

.PARAMETER SmtpHost
    Mail server Alertmanager sends alerts through. Empty sends no email: alerts still show in
    Grafana (Alerting) and in Alertmanager.

.PARAMETER SmtpPasswordSecret
    Secret in namespace 'observability' holding the SMTP password under key -SmtpPasswordKey,
    created beforehand: kubectl -n observability create secret generic <name> --from-literal=password=<password>
    Empty sends without authentication.

.EXAMPLE
    ./scripts/infra/azurelocal/provision-observability.ps1

.EXAMPLE
    ./scripts/infra/azurelocal/provision-observability.ps1 -SmtpHost mail.contoso.local -SmtpFrom oms-alerts@contoso.local -AlertEmailTo ops@contoso.local
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    # The connected registry's address. Empty reads it from the pull secret connected-registry.ps1 wrote.
    [string]$PullRegistry,
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$IngressClassName = 'nginx',

    [string]$CollectorChartVersion = '0.178.0',
    [string]$PrometheusStackChartVersion = '92.14.1',
    [string]$LokiChartVersion = '20.0.3',
    [string]$TempoChartVersion = '3.2.1',

    # Storage class for every volume. Empty uses the cluster's default class.
    [string]$StorageClassName,
    [string]$PrometheusRetention = '15d',
    [string]$PrometheusStorage = '10Gi',
    [string]$AlertmanagerStorage = '1Gi',
    [string]$GrafanaStorage = '1Gi',
    [string]$LokiRetention = '168h',
    [string]$LokiStorage = '10Gi',
    [string]$TempoRetention = '72h',
    [string]$TempoStorage = '10Gi',
    # Telemetry queued while Tempo or Loki is unavailable.
    [string]$CollectorQueueStorage = '2Gi',

    [string]$GrafanaUrl,
    # The realm's address as browsers and Grafana reach it. Empty uses https://<node>:30443/realms/oms,
    # Keycloak's NodePort, as keycloak.ps1 does.
    [string]$KeycloakRealmUrl,

    [string]$SmtpHost,
    [int]$SmtpPort = 587,
    [string]$SmtpFrom,
    # One or more addresses, comma-separated.
    [string]$AlertEmailTo,
    [string]$SmtpUsername,
    [string]$SmtpPasswordSecret,
    [string]$SmtpPasswordKey = 'password',
    [bool]$SmtpRequireTls = $true,

    # Where cert-manager runs: the Certificate Management for Azure Arc extension's namespace.
    [string]$CertManagerNamespace = 'cert-manager',
    [string]$CertManagerDeployment = 'cert-manager'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
Push-Location $repoRoot

# Names fixed by the files in infra/azurelocal/observability: the charts' values point at each
# other's Services in this namespace, and the app at otel-collector.observability.
$Namespace = 'observability'
$IdentityNamespace = 'identity'
$KeycloakNodePort = 30443
$valuesDir = Join-Path $repoRoot 'infra/azurelocal/observability'

function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

function Get-SecretData([string]$SecretNamespace, [string]$Name, [string]$Key) {
    $escaped = $Key.Replace('.', '\.')
    $value = kubectl get secret $Name -n $SecretNamespace --context $KubeContext --ignore-not-found -o "jsonpath={.data.$escaped}"
    if ($value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
}

# Writes a Secret from string values without them passing through the command line.
function Set-OpaqueSecret([string]$Name, [hashtable]$Data) {
    $lines = $Data.GetEnumerator() | ForEach-Object {
        "  $($_.Key): $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Value)))"
    }
    @"
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: $Name
  namespace: $Namespace
data:
$($lines -join "`n")
"@ | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Writing Secret '$Namespace/$Name' failed." }
}

function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Every volume takes -StorageClassName when it is set; left out, Kubernetes uses the default class.
function Add-StorageClass([hashtable]$Spec, [string]$Key = 'storageClassName') {
    if ($StorageClassName) { $Spec[$Key] = $StorageClassName }
    $Spec
}

try {
    if (-not $PullRegistry) {
        $PullRegistry = Get-OmsPullRegistry $KubeContext $ApplicationNamespace $PullSecretName
        if (-not $PullRegistry) {
            throw "No pull secret '$PullSecretName' in '$ApplicationNamespace' to read the connected registry's address from. Run scripts/infra/azurelocal/connected-registry.ps1 first, or pass -PullRegistry."
        }
    }
    if ($SmtpHost -and (-not $SmtpFrom -or -not $AlertEmailTo)) {
        throw '-SmtpHost needs -SmtpFrom and -AlertEmailTo too.'
    }

    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$Namespace' failed." }

    # connected-registry.ps1 writes the pull secret here; a registry set up before 'observability'
    # was in its list hasn't, so take the application's.
    if (-not (kubectl get secret $PullSecretName -n $Namespace --context $KubeContext --ignore-not-found -o name)) {
        $dockerConfig = kubectl get secret $PullSecretName -n $ApplicationNamespace --context $KubeContext -o 'jsonpath={.data.\.dockerconfigjson}'
        if ($LASTEXITCODE -ne 0 -or -not $dockerConfig) { throw "No pull secret '$PullSecretName' in '$ApplicationNamespace' to copy." }
        @"
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: $PullSecretName
  namespace: $Namespace
data:
  .dockerconfigjson: $dockerConfig
"@ | kubectl apply --context $KubeContext -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Copying the pull secret to '$Namespace' failed." }
        Write-Host "    copied pull secret $ApplicationNamespace/$PullSecretName" -ForegroundColor DarkGray
    }

    # ------------------------------------------------------------------------------------------
    # 1. Site values: where Grafana is served, and where it finds Keycloak
    # ------------------------------------------------------------------------------------------
    if (-not $GrafanaUrl) {
        $GrafanaUrl = kubectl get configmap keycloak-realm-settings -n $IdentityNamespace --context $KubeContext `
            --ignore-not-found -o 'jsonpath={.data.GRAFANA_ORIGIN}'
        if (-not $GrafanaUrl) {
            throw "No -GrafanaUrl, and no GRAFANA_ORIGIN in $IdentityNamespace/keycloak-realm-settings to take it from. Run scripts/infra/azurelocal/keycloak.ps1 first: it registers Grafana's address with Keycloak."
        }
    }
    $GrafanaUrl = $GrafanaUrl.TrimEnd('/')
    $grafanaPath = ([uri]$GrafanaUrl).AbsolutePath.TrimEnd('/')
    # The app's Ingress answers on '/' for any host, so Grafana needs a path of its own.
    if (-not $grafanaPath) { throw "-GrafanaUrl '$GrafanaUrl' has no path. Grafana shares the app's address, so give it one, such as $GrafanaUrl/grafana." }

    if (-not $KeycloakRealmUrl) {
        $nodeIp = kubectl get nodes --context $KubeContext -o 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
        if ($LASTEXITCODE -ne 0 -or -not $nodeIp) { throw 'Could not read a node address for Keycloak''s URL. Pass -KeycloakRealmUrl.' }
        $KeycloakRealmUrl = "https://${nodeIp}:$KeycloakNodePort/realms/oms"
    }
    $KeycloakRealmUrl = $KeycloakRealmUrl.TrimEnd('/')
    Write-Host "==> Grafana at $GrafanaUrl, signing in through $KeycloakRealmUrl" -ForegroundColor Cyan

    # ------------------------------------------------------------------------------------------
    # 2. Secrets, generated or copied once and kept in the cluster
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Secrets in namespace $Namespace" -ForegroundColor Cyan
    # Grafana's admin account exists but can't sign in (login form and basic auth are off). Its
    # password is still random rather than the chart's default.
    if (-not (Get-SecretData $Namespace 'grafana-admin' 'admin-password')) {
        Set-OpaqueSecret 'grafana-admin' @{ 'admin-user' = 'admin'; 'admin-password' = (New-RandomSecret) }
        Write-Host "    generated $Namespace/grafana-admin" -ForegroundColor DarkGray
    }

    # The 'grafana' client's secret, which keycloak.ps1 generated and gave the realm.
    $clientSecret = Get-SecretData $IdentityNamespace 'grafana-oauth' 'client-secret'
    if (-not $clientSecret) {
        throw "No Secret $IdentityNamespace/grafana-oauth with Keycloak's client secret for Grafana. Run scripts/infra/azurelocal/keycloak.ps1 first."
    }
    Set-OpaqueSecret 'grafana-oauth' @{ 'client-id' = 'grafana'; 'client-secret' = $clientSecret }
    $clientSecret = $null

    # The CA behind Keycloak's certificate (the site CA), so Grafana can verify Keycloak.
    $keycloakCa = Get-SecretData $IdentityNamespace 'keycloak-tls' 'ca.crt'
    if (-not $keycloakCa) { $keycloakCa = Get-SecretData $ApplicationNamespace 'oms-identity-ca' 'ca.crt' }
    if (-not $keycloakCa) {
        throw "Found no CA for Keycloak's certificate in $IdentityNamespace/keycloak-tls or $ApplicationNamespace/oms-identity-ca. Run scripts/infra/azurelocal/keycloak.ps1 first."
    }
    Set-OpaqueSecret 'keycloak-ca' @{ 'ca.crt' = $keycloakCa }

    if ($SmtpPasswordSecret -and -not (Get-SecretData $Namespace $SmtpPasswordSecret $SmtpPasswordKey)) {
        throw "No Secret $Namespace/$SmtpPasswordSecret with key '$SmtpPasswordKey'. Create it: kubectl -n $Namespace create secret generic $SmtpPasswordSecret --from-literal=$SmtpPasswordKey=<password>"
    }

    # The collector's queue volume. Created here rather than by the chart, which has no volume
    # claim of its own in deployment mode; left alone once it exists.
    if (-not (kubectl get pvc otel-collector-queue -n $Namespace --context $KubeContext --ignore-not-found -o name)) {
        $queueClaim = @{
            apiVersion = 'v1'; kind = 'PersistentVolumeClaim'
            metadata   = @{ name = 'otel-collector-queue'; namespace = $Namespace }
            spec       = Add-StorageClass @{ accessModes = @('ReadWriteOnce'); resources = @{ requests = @{ storage = $CollectorQueueStorage } } }
        }
        $queueClaim | ConvertTo-Json -Depth 10 | kubectl apply --context $KubeContext -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Creating the collector''s queue volume claim failed.' }
    }

    Invoke-Checked 'helm repo add open-telemetry' { helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update | Out-Null }
    Invoke-Checked 'helm repo add prometheus-community' { helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update | Out-Null }
    Invoke-Checked 'helm repo add grafana-community' { helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update | Out-Null }
    $common = @('--namespace', $Namespace, '--kube-context', $KubeContext, '--wait', '--timeout', '20m')

    # ------------------------------------------------------------------------------------------
    # 3. Prometheus, Alertmanager and Grafana. First, since it brings the ServiceMonitor and
    #    PrometheusRule types the other charts and the monitoring folder use.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Installing kube-prometheus-stack $PrometheusStackChartVersion (metrics, $PrometheusRetention)" -ForegroundColor Cyan
    $logoutUrl = "$KeycloakRealmUrl/protocol/openid-connect/logout?client_id=grafana&post_logout_redirect_uri=$([uri]::EscapeDataString("$GrafanaUrl/"))"
    $prometheusSpec = @{
        retention   = $PrometheusRetention
        storageSpec = @{ volumeClaimTemplate = @{ spec = Add-StorageClass @{ resources = @{ requests = @{ storage = $PrometheusStorage } } } } }
    }
    # Keep Prometheus's data under the volume's size, so it deletes old data before the disk fills.
    if ($PrometheusStorage -match '^(\d+)Gi$') { $prometheusSpec.retentionSize = "$([math]::Floor([int]$Matches[1] * 0.9))GB" }
    else { Write-Warning "-PrometheusStorage '$PrometheusStorage' isn't in Gi; keeping the retention size from values.yaml." }
    $alertmanagerSpec = @{
        storage = @{ volumeClaimTemplate = @{ spec = Add-StorageClass @{ resources = @{ requests = @{ storage = $AlertmanagerStorage } } } } }
    }
    # The structured site values go in as a values document on stdin: grafana.ini's dotted section
    # names and the Alertmanager receivers don't fit --set.
    $stackSite = @{
        prometheus   = @{ prometheusSpec = $prometheusSpec }
        alertmanager = @{ alertmanagerSpec = $alertmanagerSpec }
        grafana      = @{
            persistence   = Add-StorageClass @{ size = $GrafanaStorage }
            ingress       = @{ ingressClassName = $IngressClassName; path = $grafanaPath }
            'grafana.ini' = @{
                server              = @{ root_url = "$GrafanaUrl/" }
                auth                = @{ signout_redirect_url = $logoutUrl }
                'auth.generic_oauth' = @{
                    auth_url  = "$KeycloakRealmUrl/protocol/openid-connect/auth"
                    token_url = "$KeycloakRealmUrl/protocol/openid-connect/token"
                    api_url   = "$KeycloakRealmUrl/protocol/openid-connect/userinfo"
                }
            }
        }
    }
    if ($SmtpHost) {
        $smtp = @{
            resolve_timeout  = '5m'
            smtp_smarthost   = "${SmtpHost}:$SmtpPort"
            smtp_from        = $SmtpFrom
            smtp_require_tls = $SmtpRequireTls
        }
        if ($SmtpUsername) { $smtp.smtp_auth_username = $SmtpUsername }
        if ($SmtpPasswordSecret) {
            # The operator mounts the Secret into Alertmanager, which reads the password from the file.
            $alertmanagerSpec.secrets = @($SmtpPasswordSecret)
            $smtp.smtp_auth_password_file = "/etc/alertmanager/secrets/$SmtpPasswordSecret/$SmtpPasswordKey"
        }
        $stackSite.alertmanager.config = @{
            global    = $smtp
            route     = @{ receiver = 'email' }
            receivers = @(
                @{ name = 'null' },
                @{ name = 'email'; email_configs = @(@{ to = $AlertEmailTo; send_resolved = $true }) }
            )
        }
    }
    $stackValues = $stackSite | ConvertTo-Json -Depth 20
    Invoke-Checked 'helm upgrade --install kube-prometheus-stack' {
        $stackValues | helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
            --version $PrometheusStackChartVersion @common `
            --values (Join-Path $valuesDir 'kube-prometheus-stack/values.yaml') --values - `
            --set "global.imageRegistry=$PullRegistry" --set "global.imagePullSecrets[0].name=$PullSecretName"
    }
    # The operator creates Prometheus and Alertmanager after Helm is done, so wait for them here.
    foreach ($resource in 'prometheus/kube-prometheus-stack-prometheus', 'alertmanager/kube-prometheus-stack-alertmanager') {
        Invoke-Checked "waiting for $resource" {
            kubectl wait $resource -n $Namespace --context $KubeContext --for=condition=Available --timeout=15m | Out-Null
        }
    }

    # ------------------------------------------------------------------------------------------
    # 4. Loki and Tempo
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Installing Loki $LokiChartVersion (logs, $LokiRetention)" -ForegroundColor Cyan
    $lokiSite = @(
        '--set', "global.imageRegistry=$PullRegistry",
        '--set', "imagePullSecrets[0].name=$PullSecretName",
        '--set', "loki.limits_config.retention_period=$LokiRetention",
        '--set', "singleBinary.persistence.size=$LokiStorage"
    )
    if ($StorageClassName) { $lokiSite += '--set', "singleBinary.persistence.storageClass=$StorageClassName" }
    Invoke-Checked 'helm upgrade --install loki' {
        helm upgrade --install loki grafana-community/loki --version $LokiChartVersion @common `
            --values (Join-Path $valuesDir 'loki/values.yaml') @lokiSite
    }

    Write-Host "==> Installing Tempo $TempoChartVersion (traces, $TempoRetention)" -ForegroundColor Cyan
    $tempoSite = @(
        '--set', "global.imageRegistry=$PullRegistry",
        '--set', "tempo.pullSecrets[0]=$PullSecretName",
        '--set', "tempo.retention=$TempoRetention",
        '--set', "persistence.size=$TempoStorage"
    )
    if ($StorageClassName) { $tempoSite += '--set', "persistence.storageClassName=$StorageClassName" }
    Invoke-Checked 'helm upgrade --install tempo' {
        helm upgrade --install tempo grafana-community/tempo --version $TempoChartVersion @common `
            --values (Join-Path $valuesDir 'tempo/values.yaml') @tempoSite
    }

    # ------------------------------------------------------------------------------------------
    # 5. The OpenTelemetry Collector the app sends to
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Installing the OpenTelemetry Collector $CollectorChartVersion" -ForegroundColor Cyan
    $collectorSite = @(
        '--set', "image.repository=$PullRegistry/otel/opentelemetry-collector-contrib",
        '--set', "imagePullSecrets[0].name=$PullSecretName"
    )
    Invoke-Checked 'helm upgrade --install otel-collector' {
        helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version $CollectorChartVersion @common `
            --values (Join-Path $valuesDir 'opentelemetry-collector/values.yaml') @collectorSite
    }

    # ------------------------------------------------------------------------------------------
    # 6. RabbitMQ and cert-manager scraping, the app's alerts and dashboard
    # ------------------------------------------------------------------------------------------
    Write-Host '==> Applying infra/azurelocal/observability/monitoring' -ForegroundColor Cyan
    # The PodMonitor selects cert-manager's controller by the labels its chart sets. The Arc
    # extension packages cert-manager itself, so check rather than assume.
    $labelsJson = kubectl get deployment $CertManagerDeployment -n $CertManagerNamespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.spec.template.metadata.labels}'
    $labels = if ($labelsJson) { $labelsJson | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not $labelsJson) {
        Write-Warning "No Deployment $CertManagerNamespace/$CertManagerDeployment; certificate expiry won't be monitored until cert-manager's metrics are scraped."
    }
    elseif ($labels['app.kubernetes.io/name'] -ne 'cert-manager' -or $labels['app.kubernetes.io/component'] -ne 'controller') {
        Write-Warning "cert-manager's pods are labelled $labelsJson, not app.kubernetes.io/name=cert-manager and app.kubernetes.io/component=controller. Change the selector in infra/azurelocal/observability/monitoring/cert-manager-podmonitor.yaml to match."
    }

    $rendered = kubectl kustomize (Join-Path $valuesDir 'monitoring')
    if ($LASTEXITCODE -ne 0) { throw 'Could not render infra/azurelocal/observability/monitoring.' }
    # The files name the default namespaces; a site that uses others gets its own.
    $rendered = $rendered -replace '^(\s+- )oms-azurelocal$', "`${1}$ApplicationNamespace" `
        -replace '^(\s+- )cert-manager$', "`${1}$CertManagerNamespace" `
        -replace '^(\s+serverName: cert-manager\.)cert-manager(\.svc)$', "`${1}$CertManagerNamespace`${2}"
    $rendered | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/observability/monitoring.' }

    $alertsTo = if ($SmtpHost) { "email to $AlertEmailTo through $SmtpHost" } else { 'Grafana and Alertmanager only (no SMTP server set)' }
    Write-Host "`nObservability ready in namespace '$Namespace'" -ForegroundColor Green
    Write-Host "Grafana          : $GrafanaUrl/  (Keycloak sign-in; Inventory.Manage edits, everyone else views)"
    Write-Host "OTLP endpoint    : http://otel-collector.$Namespace.svc.cluster.local:4317 (gRPC), :4318 (HTTP)"
    Write-Host "Retention        : metrics $PrometheusRetention, logs $LokiRetention, traces $TempoRetention"
    Write-Host "Alerts           : $alertsTo"
}
finally {
    Pop-Location
}
