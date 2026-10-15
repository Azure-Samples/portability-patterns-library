<#
.SYNOPSIS
    Builds, publishes and deploys the Business Continuity Demo App to a local kind cluster.

.DESCRIPTION
    End-to-end local path:
      1. Create the kind cluster (with an in-cluster OCI registry) if it does not exist.
      2. Install Radius into that cluster and bind a dedicated Radius workspace to it.
      3. Register the BusinessContinuity.Messaging/messageQueues Resource Type.
      4. Build both worker images and load them straight into the kind node.
      5. Publish the local Recipes to the in-cluster registry.
      6. Deploy the Recipe Pack, the Environment and the application.

    Every step is checked; the script stops at the first failure rather than reporting success.

.NOTES
    Two details that are easy to get wrong and are handled explicitly here:

    * Radius commands target the workspace's Kubernetes context, NOT the current kubectl context.
      Without a dedicated workspace bound to this cluster, `rad` silently operates against whatever
      cluster the default workspace points at.

    * Worker images are loaded with `kind load` rather than pulled from the in-cluster registry.
      The kubelet resolves image hostnames using the node's DNS, which cannot resolve
      *.svc.cluster.local names. The registry is still used for Recipes, which are pulled by the
      Radius control plane from inside the cluster where cluster DNS does work.

.EXAMPLE
    ./lab/local/deploy.ps1

.EXAMPLE
    ./lab/local/deploy.ps1 -SkipClusterCreate -SkipImageBuild
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'bcd',
    [string]$ResourceGroup = 'bcd',
    [string]$WorkspaceName = 'bcd',
    [string]$EnvironmentName = 'bcd-local',
    [string]$Namespace = 'bcd-local',
    [string]$ImageTag = 'local',
    [switch]$SkipClusterCreate,
    [switch]$SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The SQL Server password comes from the environment so no credential is stored in the repository.
if (-not $env:MSSQL_SA_PASSWORD) {
    throw 'Set $env:MSSQL_SA_PASSWORD to a SQL Server password (8+ characters from three of: upper, lower, digits, symbols) before deploying.'
}

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

try {
    $kubeContext = "kind-$ClusterName"
    # Radius pulls Recipes from inside the cluster, where cluster DNS resolves this name.
    $recipeRegistry = 'registry.bcd-registry.svc.cluster.local:5000'
    # `rad bicep publish` runs on the workstation and reaches the same registry through the
    # kind NodePort mapping.
    $publishRegistry = 'localhost:5000'

    if (-not $SkipClusterCreate) {
        $existing = kind get clusters 2>$null
        if ($existing -notcontains $ClusterName) {
            Write-Host "==> Creating kind cluster '$ClusterName'" -ForegroundColor Cyan
            Invoke-Checked 'kind create cluster' { kind create cluster --config lab/local/kind-cluster.yaml }
        }
        else {
            Write-Host "==> kind cluster '$ClusterName' already exists" -ForegroundColor DarkGray
        }

        Write-Host "==> Deploying the in-cluster OCI registry" -ForegroundColor Cyan
        Invoke-Checked 'kubectl apply registry' { kubectl apply --context $kubeContext -f lab/local/registry.yaml }
        Invoke-Checked 'registry rollout' {
            kubectl rollout status deployment/registry -n bcd-registry --context $kubeContext --timeout=180s
        }
    }

    Write-Host "==> Installing the Radius control plane" -ForegroundColor Cyan
    Invoke-Checked 'rad install' { rad install kubernetes --kubecontext $kubeContext }

    # A workspace bound to this cluster must exist before any group is created, otherwise `rad`
    # targets the default workspace's cluster. The group cannot be set on first creation because
    # it does not exist yet, so the workspace is created twice.
    Write-Host "==> Binding Radius workspace '$WorkspaceName' to context '$kubeContext'" -ForegroundColor Cyan
    Invoke-Checked 'rad workspace create' {
        rad workspace create kubernetes $WorkspaceName --context $kubeContext --force
    }
    Invoke-Checked 'rad group create' { rad group create $ResourceGroup --workspace $WorkspaceName }
    Invoke-Checked 'rad workspace bind group' {
        rad workspace create kubernetes $WorkspaceName --context $kubeContext --group $ResourceGroup --force
    }

    # Radius.Core/environments requires the target namespace to already exist.
    Write-Host "==> Creating namespace '$Namespace'" -ForegroundColor Cyan
    kubectl create namespace $Namespace --context $kubeContext --dry-run=client -o yaml | kubectl apply --context $kubeContext -f -
    if ($LASTEXITCODE -ne 0) { throw 'Creating the application namespace failed.' }

    # `rad deploy` always needs an environment to deploy *into*, including when the thing being
    # deployed is the Recipe Pack that the real environment depends on.
    Write-Host "==> Creating the bootstrap environment" -ForegroundColor Cyan
    Invoke-Checked 'rad env create bootstrap' {
        rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName
    }

    Write-Host "==> Registering the messageQueues Resource Type" -ForegroundColor Cyan
    Invoke-Checked 'rad resource-type create' {
        rad resource-type create messageQueues -f deploy/types/messageQueues.yaml --workspace $WorkspaceName
    }
    Invoke-Checked 'rad bicep publish-extension' {
        rad bicep publish-extension -f deploy/types/messageQueues.yaml --target deploy/types/businessContinuity.tgz
    }

    if (-not $SkipImageBuild) {
        Write-Host "==> Building worker images" -ForegroundColor Cyan
        Invoke-Checked 'docker build publisher' {
            docker build -f docker/Dockerfile.publisher -t "bcd/publisher:$ImageTag" .
        }
        Invoke-Checked 'docker build consumer' {
            docker build -f docker/Dockerfile.consumer -t "bcd/consumer:$ImageTag" .
        }

        # Loading into the node avoids the kubelet having to resolve a cluster DNS name.
        Write-Host "==> Loading worker images into the kind node" -ForegroundColor Cyan
        Invoke-Checked 'kind load publisher' {
            kind load docker-image "bcd/publisher:$ImageTag" --name $ClusterName
        }
        Invoke-Checked 'kind load consumer' {
            kind load docker-image "bcd/consumer:$ImageTag" --name $ClusterName
        }
    }

    Write-Host "==> Publishing local Recipes" -ForegroundColor Cyan
    ./scripts/publish-recipes.ps1 -Registry $publishRegistry -Set local -PlainHttp

    # Note: booleans and integers cannot be passed as `-p key=value`, which only supports strings.
    # `plainHttp` therefore stays at its default of true in the Recipe Pack template.
    Write-Host "==> Deploying the Recipe Pack" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy deploy/recipe-packs/local.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters registry=$recipeRegistry
    }

    Write-Host "==> Deploying the Environment" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy environment' {
        rad deploy deploy/environments/local.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap
    }

    Write-Host "==> Deploying the application" -ForegroundColor Cyan
    $appParameters = Get-Content deploy/params.local.json -Raw | ConvertFrom-Json
    $appParameters.parameters.sqlAdminPassword.value = $env:MSSQL_SA_PASSWORD
    $appParametersFile = Join-Path ([IO.Path]::GetTempPath()) "bcd-local-$([guid]::NewGuid().ToString('N')).json"
    try {
        $appParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $appParametersFile -Encoding utf8
        Invoke-Checked 'rad deploy application' {
            rad deploy deploy/app.bicep `
                --workspace $WorkspaceName `
                --group $ResourceGroup `
                --environment $EnvironmentName `
                --parameters "@$appParametersFile"
        }
    }
    finally {
        Remove-Item $appParametersFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`nDeployed successfully." -ForegroundColor Green
    Write-Host "Watch the workers with:"
    Write-Host "  kubectl logs -n $Namespace -l radapp.io/resource=publisher -f"
    Write-Host "  kubectl logs -n $Namespace -l radapp.io/resource=consumer -f"
    Write-Host "Check the records written to SQL Server with:"
    Write-Host "  ./lab/local/verify.ps1"
}
finally {
    Pop-Location
}
