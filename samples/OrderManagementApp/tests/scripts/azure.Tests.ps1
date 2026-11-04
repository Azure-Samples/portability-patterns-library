# Tests for scripts/lib/azure.ps1. Run with: Invoke-Pester ./tests/scripts
# az is replaced by a function, so no Azure sign-in is needed.

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/azure.ps1')

    # Stands in for az: answers with $script:AzOutput and exits with $script:AzExitCode.
    function az {
        $global:LASTEXITCODE = $script:AzExitCode
        $script:AzOutput
    }

    function New-ErrorRecord([string]$Message) {
        [Management.Automation.ErrorRecord]::new([Exception]::new($Message), 'NativeCommandError', 'NotSpecified', $null)
    }
}

Describe 'Invoke-OmsAzShow' {
    It 'returns what az printed, without its warnings' {
        $script:AzExitCode = 0
        $script:AzOutput = @((New-ErrorRecord 'WARNING: Command group is in preview'), 'sha256:abc')

        Invoke-OmsAzShow @('acr', 'manifest', 'show-metadata', 'r/oms/api:latest') | Should -Be 'sha256:abc'
    }

    It 'returns nothing for a resource az reports as not found' {
        $script:AzExitCode = 3
        $script:AzOutput = New-ErrorRecord '(ResourceNotFound) The resource bcd-pull could not be found.'

        Invoke-OmsAzShow @('acr', 'token', 'show', '--name', 'bcd-pull') | Should -BeNullOrEmpty
    }

    It 'throws, rather than reporting a missing resource, when az fails' {
        $script:AzExitCode = 1
        $script:AzOutput = New-ErrorRecord 'AADSTS700082: The refresh token has expired.'

        { Invoke-OmsAzShow @('acr', 'token', 'show', '--name', 'bcd-pull') } |
            Should -Throw '*az acr token failed with exit code 1*refresh token has expired*'
    }
}
