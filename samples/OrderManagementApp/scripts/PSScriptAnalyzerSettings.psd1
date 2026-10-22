@{
    # The PR check fails on errors only; warnings such as Write-Host are fine for setup scripts.
    Severity     = @('Error')

    # The setup scripts generate passwords (Keycloak, AD service accounts, SQL) and hand them
    # straight to Kubernetes or Active Directory, which need them as SecureStrings. Nothing is read
    # from a prompt or a file in plain text.
    ExcludeRules = @('PSAvoidUsingConvertToSecureStringWithPlainText')
}
