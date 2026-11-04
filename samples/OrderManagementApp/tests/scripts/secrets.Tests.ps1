# Tests for scripts/lib/secrets.ps1. Run with: Invoke-Pester ./tests/scripts
# kubectl is replaced by a function, so no cluster is needed.

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/secrets.ps1')

    # Stands in for kubectl: answers with $script:KubectlOutput and exits with $script:KubectlExitCode.
    function kubectl {
        $global:LASTEXITCODE = $script:KubectlExitCode
        $script:KubectlOutput
    }

    function ConvertTo-SecretJson([hashtable]$Data) {
        $encoded = @{}
        foreach ($key in $Data.Keys) { $encoded[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Data[$key])) }
        @{ apiVersion = 'v1'; kind = 'Secret'; data = $encoded } | ConvertTo-Json
    }
}

Describe 'Get-OmsSecretData' {
    It 'returns every key of a Secret as text' {
        $script:KubectlExitCode = 0
        $script:KubectlOutput = ConvertTo-SecretJson @{ username = 'app'; password = 'p@ss:word' }

        $data = Get-OmsSecretData -KubeContext 'ctx' -Namespace 'ns' -Name 'creds'

        $data['username'] | Should -Be 'app'
        $data['password'] | Should -Be 'p@ss:word'
    }

    It 'returns nothing for a Secret that does not exist' {
        # kubectl --ignore-not-found prints nothing and succeeds.
        $script:KubectlExitCode = 0
        $script:KubectlOutput = $null

        $data = Get-OmsSecretData -KubeContext 'ctx' -Namespace 'ns' -Name 'missing'

        $data.Count | Should -Be 0
    }

    It 'throws, rather than reporting a missing Secret, when the read fails' {
        $script:KubectlExitCode = 1
        $script:KubectlOutput = [Management.Automation.ErrorRecord]::new(
            [Exception]::new('Unable to connect to the server: i/o timeout'), 'NativeCommandError', 'NotSpecified', $null)

        { Get-OmsSecretData -KubeContext 'ctx' -Namespace 'ns' -Name 'creds' } |
            Should -Throw "*Reading Secret 'ns/creds' failed*i/o timeout*"
    }
}

Describe 'Get-OmsSecretValue' {
    It 'returns one key, or nothing when the key is absent' {
        $script:KubectlExitCode = 0
        $script:KubectlOutput = ConvertTo-SecretJson @{ 'ca.crt' = 'certificate' }

        Get-OmsSecretValue -KubeContext 'ctx' -Namespace 'ns' -Name 'ca' -Key 'ca.crt' | Should -Be 'certificate'
        Get-OmsSecretValue -KubeContext 'ctx' -Namespace 'ns' -Name 'ca' -Key 'tls.crt' | Should -BeNullOrEmpty
    }

    It 'throws when the read fails' {
        $script:KubectlExitCode = 1
        $script:KubectlOutput = $null

        { Get-OmsSecretValue -KubeContext 'ctx' -Namespace 'ns' -Name 'ca' -Key 'ca.crt' } | Should -Throw
    }
}

Describe 'Set-OmsSecret' {
    It 'sends the Secret, of the given type, to kubectl on stdin and never as an argument' {
        function kubectl {
            $script:KubectlArguments = $args
            $script:KubectlInput = @($input) -join "`n"
            $global:LASTEXITCODE = 0
        }

        Set-OmsSecret -KubeContext 'ctx' -Namespace 'ns' -Name 'pull' -Type 'kubernetes.io/dockerconfigjson' `
            -Data @{ '.dockerconfigjson' = '{"auths":{"10.0.0.1":{"password":"p@ss"}}}' }

        ($script:KubectlArguments -join ' ') | Should -Not -Match 'p@ss'
        $secret = $script:KubectlInput | ConvertFrom-Json
        $secret.type | Should -Be 'kubernetes.io/dockerconfigjson'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.'.dockerconfigjson')) |
            Should -Be '{"auths":{"10.0.0.1":{"password":"p@ss"}}}'
    }

    It 'throws when kubectl fails' {
        function kubectl { $global:LASTEXITCODE = 1 }

        { Set-OmsSecret -KubeContext 'ctx' -Namespace 'ns' -Name 'creds' -Data @{ password = 'x' } } |
            Should -Throw "*Writing Secret 'ns/creds' failed*"
    }
}
