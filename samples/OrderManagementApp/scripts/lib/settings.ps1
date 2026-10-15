# Shared by setup-platform.ps1 and deploy.ps1: per-target values from scripts/settings.json.

function Read-BcdSettings([string]$Target, [string]$Path) {
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
function Get-BcdStepArguments([hashtable]$Settings, [string]$Step, [string]$ScriptPath) {
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
