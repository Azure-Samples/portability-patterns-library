# Configuration

Radius injects these into the API and the processor from their connections. The same names work in
`appsettings.json` as `OrderManagement:<connection>:<property>`, and
[compose.yaml](../compose.yaml) sets them to run the app on your machine.

| Variable | Used by | Notes |
|---|---|---|
| `CONNECTION_QUEUE_PROVIDER` | both | `servicebus` or `rabbitmq` |
| `CONNECTION_QUEUE_QUEUENAME` | both | queue name |
| `CONNECTION_QUEUE_ENDPOINT` | both | Service Bus namespace host name, or `host:port` for RabbitMQ |
| `CONNECTION_QUEUE_OAUTH*` | both | Azure Local: Keycloak token endpoint, client and token file |
| `CONNECTION_QUEUE_USERNAME` / `_PASSWORD` | both | only when the queue Recipe issues credentials |
| `CONNECTION_ARCHIVE_ENDPOINT` / `_CONTAINERNAME` | processor | blob endpoint and container |
| `CONNECTION_ARCHIVE_CONNECTIONSTRING` | processor | Azure Local (Azurite) only |
| `CONNECTION_SQL_HOST` / `_PORT` / `_DATABASE` | both | |
| `CONNECTION_SQL_USERNAME` / `_PASSWORD` | both | ignored when the pod has an Entra workload identity or a Kerberos keytab |
