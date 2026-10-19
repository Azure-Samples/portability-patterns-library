# Portability Patterns Library
The portability patterns library provides reusable application patterns, reference implementations, and guidance for building workloads that can operate consistently across Azure cloud, sovereign environments, and Azure Local. It supports business continuity by helping teams design adaptive applications that can be deployed, moved, or recovered across environments while minimizing dependencies on location-specific services.

Note: These resources are provided solely as reference and sample implementations and should not be used for production workloads.

## Samples

| Sample | What it shows |
|---|---|
| [Order Management](./samples/OrderManagementApp/README.md) | One Radius application definition and one set of container images deployed unchanged to AKS with Azure PaaS services and to Azure Local (AKS enabled by Arc), where it keeps running when the site loses its link to Azure. Users sign in with MSAL.js against Entra ID in Azure or Keycloak federated to Active Directory on Azure Local, and place orders that flow through a queue into object storage and SQL Server. |
## Getting started

Start with the [Order Management sample](./samples/OrderManagementApp/README.md) for
prerequisites, build instructions, deployment options, configuration, and known gaps.
The sample's file paths and commands are relative to
[`samples/OrderManagementApp`](./samples/OrderManagementApp).

## Contributing and support

- See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution instructions and the
  Contributor License Agreement requirement.
- Participation is governed by the [Microsoft Open Source Code of Conduct](./CODE_OF_CONDUCT.md).
- See [SUPPORT.md](./SUPPORT.md) for questions, bug reports, and feature requests.
- Report security vulnerabilities privately as described in [SECURITY.md](./SECURITY.md),
  not through public GitHub issues.

## License and third-party materials

This project is licensed under the [MIT License](./LICENSE.txt).
Third-party materials remain subject to their respective licenses and terms:

- The Order Management sample includes the Microsoft Authentication Library for
  JavaScript (MSAL.js) browser bundle under
  [`wwwroot/lib/msal-browser`](./samples/OrderManagementApp/src/OrderManagement.Api/wwwroot/lib/msal-browser).
  Its [MIT license](./samples/OrderManagementApp/src/OrderManagement.Api/wwwroot/lib/msal-browser/LICENSE)
  is included alongside the bundle.
- NuGet dependencies, including Azure SDK libraries, Microsoft.Identity.Web,
  Dapper, Microsoft.Data.SqlClient, and RabbitMQ.Client, are referenced by the
  sample's project files and restored during the build. Refer to each package
  for its license and notices.
- Architecture diagrams include Microsoft and third-party product icons.
  Their sources and usage terms are described in the
  [diagram documentation](./samples/OrderManagementApp/docs/diagrams/README.md#icons).
- Deployment definitions use external tools and container images, including
  Radius, Kubernetes, RabbitMQ, Azurite, SQL Server, and Keycloak. These components
  have their own licenses and usage terms; this repository's license does not
  replace them.

## Trademarks

This project may contain trademarks or logos for projects, products, or services.
Authorized use of Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must
not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
