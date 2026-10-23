# Shared by setup-platform.ps1 and deploy.ps1: per-target values from scripts/settings.json.

function Read-OmsSettings([string]$Target, [string]$Path) {
    if (-not $Path) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'settings.json' }
    if (-not (Test-Path $Path)) {
        throw "No settings file at '$Path'. Copy scripts/settings.example.json to scripts/settings.json and fill in your values."
    }
    $all = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $all.ContainsKey($Target)) { throw "'$Path' has no '$Target' section." }
    $all[$Target]
}

# 'Common' values go only to scripts that declare the parameter; the step's own section goes as is,
# so a misspelt name fails loudly instead of being ignored.
function Get-OmsStepArguments([hashtable]$Settings, [string]$Step, [string]$ScriptPath) {
    $declared = (Get-Command $ScriptPath).Parameters.Keys
    $arguments = @{}
    foreach ($section in 'Common', $Step) {
        if (-not $Settings.ContainsKey($section)) { continue }
        foreach ($name in $Settings[$section].Keys) {
            if ($section -eq 'Common' -and $name -notin $declared) { continue }
            $arguments[$name] = $Settings[$section][$name]
        }
    }
    $arguments
}

# The defaults a script declares in its param block, read without running it, so other scripts
# can use the same values instead of repeating them.
function Get-OmsScriptDefaults([string]$Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $defaults = @{}
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        if ($parameter.DefaultValue -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $defaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.Value
        }
        elseif ($parameter.DefaultValue) {
            try { $defaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.SafeGetValue() } catch { }
        }
    }
    $defaults
}

# Points az at the target's subscription ('Common' SubscriptionId) for one run, so every step works
# in the same subscription whatever az had selected before. Returns the previous subscription for
# Restore-OmsSubscription, or nothing when there was nothing to change.
function Select-OmsSubscription([hashtable]$Settings) {
    $id = if ($Settings.ContainsKey('Common')) { $Settings['Common']['SubscriptionId'] }
    if (-not $id -or $id -like '<*') { return }

    $previous = az account show --query id --output tsv 2>$null
    if ($previous -eq $id) { return }

    az account set --subscription $id
    if ($LASTEXITCODE -ne 0) {
        throw "Could not select subscription '$id'. If it is in another tenant, sign in to it first: az login --tenant <tenant-id>"
    }
    Write-Host "==> Using subscription $id" -ForegroundColor DarkGray
    $previous
}

function Restore-OmsSubscription([string]$SubscriptionId) {
    if ($SubscriptionId) { az account set --subscription $SubscriptionId 2>$null }
}
