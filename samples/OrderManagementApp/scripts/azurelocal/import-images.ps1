<#
.SYNOPSIS
    Moves every container image this application needs into a local registry.

.DESCRIPTION
    Azure Local with disconnected operations cannot reach mcr.microsoft.com, ghcr.io, quay.io or
    Docker Hub. Every image must therefore be present in the local Azure Container Registry before
    anything is deployed, including the Radius control plane itself.

    Recipes do NOT need mirroring: every Recipe in this repository, including the vendored stock
    Radius ones, is published from source with `rad bicep publish`, so the air gap only has to carry
    container images.

    Four modes:

      Copy    Registry-to-registry copy driven by this machine, with `docker buildx imagetools`.
              Use this when the machine running the script can reach both the public registries and
              the local one, which is the usual shape when the ALDO appliance runs on a devbox. The
              registry itself needs no outbound access.

      Mirror  Server-side copy with `az acr import`. Only works when the target registry itself can
              reach the public registries, which is true for a connected Azure Local instance or for
              rehearsing the flow against a normal ACR. A disconnected appliance cannot do this, and
              the command hangs until the server-side pull times out.

      Export  `docker pull` then `docker save` into a folder, run on a CONNECTED machine. Copy the
              folder across the air gap by whatever means your environment allows.

      Import  `docker load` then push into the local registry, run on the DISCONNECTED side.
              Multi-platform images are a known weak spot here: `docker save` writes the whole
              index, and after `docker load` the daemon refuses to push it, reporting that the
              image 'does not provide any platform'. Prefer Copy whenever both endpoints are
              reachable from one machine.

.PARAMETER Registry
    Login server of the target registry, for example 'mylocalacr.azurecr.local'.

.PARAMETER Platform
    Platform to select from multi-platform images. The cluster nodes decide this, not this machine.

.PARAMETER RadiusVersion
    Tag of the Radius control-plane images. Must match the rad CLI version used to install Radius.

.PARAMETER IncludeContour
    Also transfer the Contour ingress images. Not needed by this application: it exposes no
    gateways or routes, and lab/aldo/deploy.ps1 installs Radius with
    --skip-contour-install. Adds two images to the air-gap payload.

.EXAMPLE
    # ALDO appliance hosted on this machine: the script can reach both sides.
    ./scripts/azurelocal/import-images.ps1 -Mode Copy -Registry mylocalacr.autonomous.cloud.private

.EXAMPLE
    # Connected rehearsal, or a connected Azure Local instance.
    ./scripts/azurelocal/import-images.ps1 -Mode Mirror -Registry mylocalacr.azurecr.io

.EXAMPLE
    # Air-gapped: on the connected machine...
    ./scripts/azurelocal/import-images.ps1 -Mode Export -Path D:\bcd-images
    # ...then, after moving the folder, on the disconnected side:
    ./scripts/azurelocal/import-images.ps1 -Mode Import -Path D:\bcd-images -Registry mylocalacr.azurecr.local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Copy', 'Mirror', 'Export', 'Import')]
    [string]$Mode,

    [string]$Registry,

    [string]$Path,

    [string]$RadiusVersion = '0.60',

    [string]$RabbitMqTag = '4-management-alpine',
    [string]$SqlServerTag = '2022-latest',
    [string]$AzuriteTag = '3.35.0',
    [string]$DotnetTag = '9.0',
    [string]$KeycloakTag = '26.8',
    [string]$PostgresTag = '17-alpine',
    [string]$IngressNginxTag = 'v1.15.1',
    [string]$WebhookCertgenTag = 'v1.6.9',

    # Multi-platform images must be narrowed to one platform: an archive holding a bare index
    # cannot be pushed after 'docker load', which reports 'does not provide any platform'.
    [string]$Platform = 'linux/amd64',

    [switch]$IncludeContour
)

$ErrorActionPreference = 'Stop'

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

# Source is the public reference; Target is the repository and tag inside the local registry.
#
# The Radius control-plane images must land at FLAT repository names. `rad install kubernetes
# --set global.imageRegistry=<registry>` pulls them as <registry>/ucpd, <registry>/controller and
# so on, with no radius-project path segment.
$images = @(
    # --- Radius control plane ---------------------------------------------------------------
    @{ Source = "ghcr.io/radius-project/ucpd:$RadiusVersion";              Target = "ucpd:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/controller:$RadiusVersion";        Target = "controller:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/applications-rp:$RadiusVersion";   Target = "applications-rp:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/dynamic-rp:$RadiusVersion";        Target = "dynamic-rp:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/deployment-engine:$RadiusVersion"; Target = "deployment-engine:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/dashboard:$RadiusVersion";         Target = "dashboard:$RadiusVersion" }
    @{ Source = "ghcr.io/radius-project/bicep:$RadiusVersion";             Target = "bicep:$RadiusVersion" }

    # Run by the 'radius-api-readiness' post-install Helm hook. Without it 'rad install kubernetes'
    # reports 'resource Job/radius-system/radius-api-readiness not ready' even though every control
    # plane pod is running.
    @{ Source = "ghcr.io/radius-project/pre-upgrade:$RadiusVersion";       Target = "pre-upgrade:$RadiusVersion" }

    # --- Backing services deployed by the Recipes -------------------------------------------
    # Repository paths match the imageRepository defaults in deploy/recipes/local/*.bicep.
    @{ Source = "mcr.microsoft.com/mssql/server:$SqlServerTag";            Target = "mssql/server:$SqlServerTag" }
    @{ Source = "mcr.microsoft.com/azure-storage/azurite:$AzuriteTag";     Target = "azure-storage/azurite:$AzuriteTag" }
    @{ Source = "docker.io/library/rabbitmq:$RabbitMqTag";                 Target = "rabbitmq:$RabbitMqTag" }

    # --- Identity -----------------------------------------------------------------------------
    # Deployed by scripts/azurelocal/keycloak.ps1 as the token issuer that fronts Active Directory.
    @{ Source = "quay.io/keycloak/keycloak:$KeycloakTag";                  Target = "keycloak/keycloak:$KeycloakTag" }
    @{ Source = "docker.io/library/postgres:$PostgresTag";                 Target = "postgres:$PostgresTag" }

    # --- Ingress -------------------------------------------------------------------------------
    # Deployed by scripts/azurelocal/provision-ingress.ps1 so users reach the app over HTTPS.
    @{ Source = "registry.k8s.io/ingress-nginx/controller:$IngressNginxTag";            Target = "ingress-nginx/controller:$IngressNginxTag" }
    @{ Source = "registry.k8s.io/ingress-nginx/kube-webhook-certgen:$WebhookCertgenTag"; Target = "ingress-nginx/kube-webhook-certgen:$WebhookCertgenTag" }

    # --- Base images for building the workers -----------------------------------------------
    # Needed only where `docker build` runs. Referenced through the BASE_REGISTRY build argument
    # in docker/Dockerfile.*.
    @{ Source = "mcr.microsoft.com/dotnet/sdk:$DotnetTag";                 Target = "dotnet/sdk:$DotnetTag" }
    @{ Source = "mcr.microsoft.com/dotnet/runtime:$DotnetTag";             Target = "dotnet/runtime:$DotnetTag" }
    @{ Source = "mcr.microsoft.com/dotnet/aspnet:$DotnetTag";              Target = "dotnet/aspnet:$DotnetTag" }
)

if ($IncludeContour) {
    $images += @{ Source = 'ghcr.io/projectcontour/contour:v1.32.0'; Target = 'projectcontour/contour:v1.32.0' }
    $images += @{ Source = 'docker.io/envoyproxy/envoy:v1.34.1';     Target = 'envoyproxy/envoy:v1.34.1' }
}

function Get-ArchiveName {
    param([Parameter(Mandatory = $true)][string]$Target)

    # Repository paths contain slashes and tags contain colons; neither is a legal file name.
    return ($Target -replace '[/:]', '_') + '.tar'
}

switch ($Mode) {
    'Copy' {
        if (-not $Registry) { throw '-Registry is required for Copy mode.' }

        # Client-side registry-to-registry copy. Unlike Mirror this needs no outbound access from
        # the registry, and unlike Export/Import it never puts a multi-platform index through
        # 'docker save', which produces archives that cannot be pushed afterwards.
        Write-Host "==> Copying $($images.Count) images into $Registry ($Platform)" -ForegroundColor Cyan

        $platformOs, $platformArch = $Platform.Split('/')
        foreach ($image in $images) {
            $repository = $image.Source -replace ':[^:/]+$', ''
            $destination = "$Registry/$($image.Target)"

            $index = docker manifest inspect $image.Source | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw "Could not read the manifest of $($image.Source)." }

            # A single-platform image has no 'manifests' array and is copied by tag as it stands.
            $reference = $image.Source
            if ($index.manifests) {
                $digest = ($index.manifests | Where-Object {
                        $_.platform.os -eq $platformOs -and $_.platform.architecture -eq $platformArch -and -not $_.platform.variant
                    } | Select-Object -First 1).digest
                if (-not $digest) { throw "$($image.Source) publishes no $Platform manifest." }
                $reference = "$repository@$digest"
            }

            Write-Host "    $($image.Target)" -ForegroundColor DarkGray
            Invoke-Checked "copy $($image.Target)" {
                docker buildx imagetools create --tag $destination $reference
            }
        }

        Write-Host "`nAll images copied into $Registry" -ForegroundColor Green
    }

    'Mirror' {
        if (-not $Registry) { throw '-Registry is required for Mirror mode.' }

        # `az acr import` is server-side: the registry pulls from the source itself, so this only
        # works while the registry has outbound access to the public registries.
        $acrName = $Registry.Split('.')[0]
        Write-Host "==> Importing $($images.Count) images into '$acrName' (server-side)" -ForegroundColor Cyan

        foreach ($image in $images) {
            Write-Host "    $($image.Source)  ->  $($image.Target)" -ForegroundColor DarkGray
            az acr import --name $acrName --source $image.Source --image $image.Target --force --only-show-errors
            if ($LASTEXITCODE -ne 0) {
                throw "Importing $($image.Source) failed. If the registry has no outbound access, use -Mode Export/Import instead."
            }
        }

        Write-Host "`nAll images imported into $Registry" -ForegroundColor Green
    }

    'Export' {
        if (-not $Path) { throw '-Path is required for Export mode.' }
        New-Item -ItemType Directory -Force -Path $Path | Out-Null

        Write-Host "==> Pulling and saving $($images.Count) images to $Path ($Platform)" -ForegroundColor Cyan

        foreach ($image in $images) {
            $archive = Join-Path $Path (Get-ArchiveName -Target $image.Target)
            Write-Host "    $($image.Source)" -ForegroundColor DarkGray

            Invoke-Checked "docker pull $($image.Source)" { docker pull --quiet --platform $Platform $image.Source | Out-Null }
            Invoke-Checked "docker save $($image.Source)" { docker save --output $archive $image.Source }
        }

        # The manifest carries the source-to-target mapping across the air gap so Import does not
        # have to re-derive it, and records the versions the payload was built for.
        $manifest = @{
            createdUtc     = (Get-Date).ToUniversalTime().ToString('o')
            radiusVersion  = $RadiusVersion
            includeContour = [bool]$IncludeContour
            images         = @($images | ForEach-Object {
                @{ source = $_.Source; target = $_.Target; archive = (Get-ArchiveName -Target $_.Target) }
            })
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $Path 'manifest.json') -Encoding utf8

        $sizeMb = [math]::Round(((Get-ChildItem $Path -Filter *.tar | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
        Write-Host "`nExported $($images.Count) images ($sizeMb MB) to $Path" -ForegroundColor Green
        Write-Host 'Copy this folder across the air gap, then run this script with -Mode Import.'
    }

    'Import' {
        if (-not $Path) { throw '-Path is required for Import mode.' }
        if (-not $Registry) { throw '-Registry is required for Import mode.' }

        $manifestPath = Join-Path $Path 'manifest.json'
        if (-not (Test-Path $manifestPath)) {
            throw "No manifest.json in '$Path'. Run -Mode Export on a connected machine first."
        }

        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Host "==> Loading $($manifest.images.Count) images exported $($manifest.createdUtc)" -ForegroundColor Cyan

        if ($manifest.radiusVersion -ne $RadiusVersion) {
            Write-Warning "Payload was built for Radius $($manifest.radiusVersion) but -RadiusVersion is $RadiusVersion."
        }

        foreach ($image in $manifest.images) {
            $archive = Join-Path $Path $image.archive
            if (-not (Test-Path $archive)) { throw "Missing archive '$archive'." }

            $destination = "$Registry/$($image.target)"
            Write-Host "    $($image.target)" -ForegroundColor DarkGray

            Invoke-Checked "docker load $($image.archive)" { docker load --input $archive | Out-Null }
            Invoke-Checked "docker tag $($image.source)" { docker tag $image.source $destination }
            Invoke-Checked "docker push $destination" { docker push --quiet $destination | Out-Null }
        }

        Write-Host "`nAll images pushed to $Registry" -ForegroundColor Green
    }
}
