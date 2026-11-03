# Tests for scripts/lib/site-https.ps1. Run with: Invoke-Pester ./tests/scripts
# A local TLS server with test certificates stands in for Keycloak.

BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/site-https.ps1')

    $rsa = [System.Security.Cryptography.RSA]
    $sha = [System.Security.Cryptography.HashAlgorithmName]::SHA256
    $pad = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    $now = [DateTimeOffset]::Now

    function New-TestCa([string]$Name) {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name", $rsa::Create(2048), $sha, $pad)
        $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
        $request.CreateSelfSigned($now.AddDays(-1), $now.AddDays(2))
    }

    $script:SiteCa = New-TestCa 'test-site-ca'
    $script:OtherCa = New-TestCa 'other-ca'

    # Keycloak's certificate: issued by the site CA for 127.0.0.1, the way keycloak.ps1 requests it.
    $leafKey = $rsa::Create(2048)
    $leafRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=keycloak', $leafKey, $sha, $pad)
    $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $names.AddIpAddress([Net.IPAddress]::Loopback)
    $leafRequest.CertificateExtensions.Add($names.Build())
    $leaf = $leafRequest.Create($script:SiteCa, $now.AddDays(-1), $now.AddDays(1), [byte[]](1, 2, 3, 4))
    $script:Leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($leaf, $leafKey).Export('Pfx'))

    $script:Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $script:Listener.Start()
    $script:Port = $script:Listener.LocalEndpoint.Port
    $script:Server = Start-ThreadJob -ArgumentList $script:Listener, $script:Leaf -ScriptBlock {
        param($listener, $certificate)
        while ($true) {
            try { $connection = $listener.AcceptTcpClient() } catch { return }
            try {
                $tls = [Net.Security.SslStream]::new($connection.GetStream())
                $tls.AuthenticateAsServer($certificate)
                $null = $tls.Read([byte[]]::new(4096), 0, 4096)
                $tls.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"))
                $tls.Dispose()
            }
            catch { }
            finally { $connection.Dispose() }
        }
    }

    function Invoke-TestGet([string]$CaPem, [string]$HostName) {
        $client = New-OmsSiteHttpClient -CaPem $CaPem -TimeoutSeconds 10
        try { [int]$client.GetAsync("https://${HostName}:$($script:Port)/").GetAwaiter().GetResult().StatusCode }
        finally { $client.Dispose() }
    }
}

AfterAll {
    $script:Listener.Stop()
    $script:Server | Stop-Job -PassThru | Remove-Job
}

Describe 'New-OmsSiteHttpClient' {
    It 'connects to a server whose certificate the given CA issued' {
        Invoke-TestGet $script:SiteCa.ExportCertificatePem() '127.0.0.1' | Should -Be 200
    }

    It 'accepts a self-signed server certificate when that certificate is what is trusted' {
        # A certificate supplied by hand rather than by cert-manager, with no CA of its own.
        $key = $rsa::Create(2048)
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=keycloak', $key, $sha, $pad)
        $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $names.AddIpAddress([Net.IPAddress]::Loopback)
        $request.CertificateExtensions.Add($names.Build())
        $selfSigned = $request.CreateSelfSigned($now.AddDays(-1), $now.AddDays(1))
        $selfSigned = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($selfSigned.Export('Pfx'))

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $server = Start-ThreadJob -ArgumentList $listener, $selfSigned -ScriptBlock {
            param($listener, $certificate)
            $connection = $listener.AcceptTcpClient()
            try {
                $tls = [Net.Security.SslStream]::new($connection.GetStream())
                $tls.AuthenticateAsServer($certificate)
                $null = $tls.Read([byte[]]::new(4096), 0, 4096)
                $tls.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"))
                $tls.Dispose()
            }
            finally { $connection.Dispose() }
        }
        $client = New-OmsSiteHttpClient -CaPem $selfSigned.ExportCertificatePem() -TimeoutSeconds 10
        try {
            [int]$client.GetAsync("https://127.0.0.1:$($listener.LocalEndpoint.Port)/").GetAwaiter().GetResult().StatusCode | Should -Be 200
        }
        finally {
            $client.Dispose()
            $listener.Stop()
            $server | Wait-Job -Timeout 10 | Remove-Job -Force
        }
    }
    It 'refuses a server whose certificate another CA issued, before sending anything' {
        { Invoke-TestGet $script:OtherCa.ExportCertificatePem() '127.0.0.1' } | Should -Throw
    }

    It 'refuses a certificate that does not name the address it connects to' {
        { Invoke-TestGet $script:SiteCa.ExportCertificatePem() 'localhost' } | Should -Throw
    }

    It 'refuses a CA PEM that holds no certificate' {
        { New-OmsSiteHttpClient -CaPem 'not a certificate' } | Should -Throw
    }
}
