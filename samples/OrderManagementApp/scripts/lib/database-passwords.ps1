# Azure Local password initialization and explicit rotation share the same credential contract.

function Get-OmsDatabasePasswords([string]$KubeContext, [string]$Namespace, [string]$SecretName) {
    $passwords = Get-OmsSecretData $KubeContext $Namespace $SecretName
    $missing = @('sql-admin-password', 'postgres-admin-password', 'sql-api-password', 'sql-processor-password', 'postgres-inventory-password') |
        Where-Object { -not $passwords[$_] }
    if ($missing) { throw "Secret '$SecretName' lacks $($missing -join ', '). Supply the database credential Secret or run the KeyVault setup step." }
    $passwords
}

function Assert-OmsDatabasePasswordsUnchanged {
    param([string]$KubeContext, [string]$Namespace, [hashtable]$Passwords, [hashtable]$Applied)
    foreach ($key in 'sql-admin-password', 'postgres-admin-password') {
        if ($Applied[$key] -and $Applied[$key] -cne $Passwords[$key]) {
            throw "Database credentials changed. Run ./scripts/rotate-database-passwords.ps1 before deploying."
        }
    }
    $keys = @{
        api = @{ Environment = 'SQL_PASSWORD'; Password = 'sql-api-password' }
        processor = @{ Environment = 'SQL_PASSWORD'; Password = 'sql-processor-password' }
        inventory = @{ Environment = 'POSTGRES_PASSWORD'; Password = 'postgres-inventory-password' }
    }
    foreach ($service in $keys.Keys) {
        $current = Get-OmsSecretData $KubeContext $Namespace "$service-db-credentials"
        $key = $keys[$service]
        if ($current[$key.Environment] -and $current[$key.Environment] -cne $Passwords[$key.Password]) {
            throw "Database credentials changed. Run ./scripts/rotate-database-passwords.ps1 before deploying."
        }
    }
}

function Set-OmsServiceDatabasePasswords([string]$KubeContext, [string]$Namespace, [hashtable]$Passwords) {
    Set-OmsSecret $KubeContext $Namespace 'api-db-credentials' @{ SQL_PASSWORD = $Passwords['sql-api-password'] }
    Set-OmsSecret $KubeContext $Namespace 'processor-db-credentials' @{ SQL_PASSWORD = $Passwords['sql-processor-password'] }
    Set-OmsSecret $KubeContext $Namespace 'inventory-db-credentials' @{ POSTGRES_PASSWORD = $Passwords['postgres-inventory-password'] }
}

function Invoke-OmsLocalDatabaseSetup {
    param(
        [string]$KubeContext, [string]$Namespace, [string]$WorkspaceName, [string]$ResourceGroup,
        [string]$Image, [string]$ImagePullSecretName, [string]$PasswordsSecretName
    )
    $sql = Get-OmsRadiusResourceProperties 'Radius.Data/sqlServerDatabases' 'ordersdb' $WorkspaceName $ResourceGroup
    $postgres = Get-OmsRadiusResourceProperties 'Radius.Data/postgreSqlDatabases' 'inventorydb' $WorkspaceName $ResourceGroup
    $fromPasswords = { param($key) @{ Secret = $PasswordsSecretName; Key = $key } }
    Invoke-OmsDatabaseSetup -KubeContext $KubeContext -Namespace $Namespace -Image $Image `
        -ImagePullSecretName $ImagePullSecretName -Environment @{
            CONNECTION_SQL_HOST = $sql.host
            CONNECTION_SQL_PORT = $sql.port
            CONNECTION_SQL_DATABASE = $sql.database
            SQL_ADMIN_USERNAME = 'sa'
            CONNECTION_INVENTORYDB_HOST = $postgres.host
            CONNECTION_INVENTORYDB_PORT = $postgres.port
            CONNECTION_INVENTORYDB_DATABASE = $postgres.database
            CONNECTION_INVENTORYDB_TLS = $postgres.tls
            POSTGRES_ADMIN_USERNAME = 'pgadmin'
        } -SecretEnvironment @{
            SQL_ADMIN_PASSWORD = & $fromPasswords 'sql-admin-password'
            SQL_API_PASSWORD = & $fromPasswords 'sql-api-password'
            SQL_PROCESSOR_PASSWORD = & $fromPasswords 'sql-processor-password'
            POSTGRES_ADMIN_PASSWORD = & $fromPasswords 'postgres-admin-password'
            INVENTORY_DB_PASSWORD = & $fromPasswords 'postgres-inventory-password'
        }
}
