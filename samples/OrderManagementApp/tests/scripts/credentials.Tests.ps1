# Tests for scripts/lib/credentials.ps1. Run with: Invoke-Pester ./tests/scripts
# kubectl is replaced by a function, so no cluster is needed.

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/credentials.ps1')

    # Stands in for kubectl: 'get' answers with $script:Existing as a Secret; 'apply' records the
    # object it was given on stdin in $script:Applied.
    function kubectl {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'apply') { $script:Applied = ($input | Out-String) | ConvertFrom-Json; return }
        if ($script:Existing) {
            $encoded = @{}
            foreach ($key in $script:Existing.Keys) { $encoded[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:Existing[$key])) }
            @{ apiVersion = 'v1'; kind = 'Secret'; data = $encoded } | ConvertTo-Json
        }
    }
    function Write-Host { }

    $script:Config = @{
        identities = @(
            @{ name = 'objects-ns'; credentials = @(@{ accessKey = 'OLD'; secretKey = 'old-secret' }); actions = @('Admin:ns.*') },
            @{ name = 'postgres-ns'; credentials = @(@{ accessKey = 'BACKUP'; secretKey = 'backup-secret' }); actions = @('Read:postgres-ns') }
        )
    } | ConvertTo-Json -Depth 10 -Compress
}

Describe 'New-OmsPassword' {
    It 'returns a different password each time, with nothing that needs quoting' {
        $first = New-OmsPassword
        $first | Should -Match '^Oms1-[A-Za-z0-9]{32}$'
        New-OmsPassword | Should -Not -Be $first
    }
}

Describe 'Initialize-OmsDatabasePasswords' {
    BeforeEach { $script:Applied = $null }

    It 'generates every password the first time' {
        $script:Existing = $null

        $passwords = Initialize-OmsDatabasePasswords 'ctx' 'ns' 'oms-db-passwords'

        $passwords.Keys | Sort-Object | Should -Be ($script:OmsDatabasePasswordKeys | Sort-Object)
        $script:Applied.metadata.name | Should -Be 'oms-db-passwords'
    }

    It 'keeps the passwords that exist and adds only the missing ones' {
        $script:Existing = @{ 'sql-admin-password' = 'kept-admin'; 'sql-api-password' = 'kept-api' }

        $passwords = Initialize-OmsDatabasePasswords 'ctx' 'ns' 'oms-db-passwords'

        $passwords['sql-admin-password'] | Should -Be 'kept-admin'
        $passwords['sql-api-password'] | Should -Be 'kept-api'
        $passwords['postgres-inventory-password'] | Should -Match '^Oms1-'
    }

    It 'writes nothing when every password exists' {
        $script:Existing = @{}
        foreach ($key in $script:OmsDatabasePasswordKeys) { $script:Existing[$key] = "kept-$key" }

        Initialize-OmsDatabasePasswords 'ctx' 'ns' 'oms-db-passwords' | Out-Null

        $script:Applied | Should -BeNullOrEmpty
    }
}

Describe 'Add-OmsS3Credential and Select-OmsS3Credential' {
    It 'adds a key next to the old one, then keeps only the new one' {
        $both = Add-OmsS3Credential $script:Config 'objects-ns' 'NEW' 'new-secret'
        $identity = ($both | ConvertFrom-Json).identities | Where-Object name -eq 'objects-ns'
        $identity.credentials.accessKey | Should -Be @('OLD', 'NEW')

        $after = Select-OmsS3Credential $both 'objects-ns' 'NEW' | ConvertFrom-Json
        ($after.identities | Where-Object name -eq 'objects-ns').credentials.accessKey | Should -Be @('NEW')
        # Other identities and the actions stay as they were.
        ($after.identities | Where-Object name -eq 'postgres-ns').credentials.accessKey | Should -Be @('BACKUP')
        ($after.identities | Where-Object name -eq 'objects-ns').actions | Should -Be @('Admin:ns.*')
    }

    It 'does not add the same key twice' {
        $once = Add-OmsS3Credential $script:Config 'objects-ns' 'NEW' 'new-secret'
        $twice = Add-OmsS3Credential $once 'objects-ns' 'NEW' 'new-secret'
        (($twice | ConvertFrom-Json).identities | Where-Object name -eq 'objects-ns').credentials.Count | Should -Be 2
    }

    It 'refuses an identity the store does not have' {
        { Add-OmsS3Credential $script:Config 'objects-other' 'NEW' 'new-secret' } | Should -Throw '*no identity*'
    }

    It 'refuses to keep a key the identity does not have, which would lock its clients out' {
        { Select-OmsS3Credential $script:Config 'objects-ns' 'MISSING' } | Should -Throw '*no key*'
    }
}
