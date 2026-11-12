# Portability Patterns Library
The portability patterns library provides reusable application patterns, reference implementations, and guidance for building workloads that can operate consistently across Azure cloud, sovereign environments, and Azure Local. It supports business continuity by helping teams design adaptive applications that can be deployed, moved, or recovered across environments while minimizing dependencies on location-specific services.

> **Disclaimer**
>
> The sample applications and portability patterns ("Reference Materials") are provided for reference only, on an "as is" basis, and without warranties of any kind. Customers are solely responsible for validating the Reference Materials in their environment and for their final implementation and configuration. Microsoft assumes no responsibility or liability for any use of, reliance on, or results arising from the Reference Materials.

## How the repository is organized

```text
portability-patterns-library/
├── README.md
├── resources/                                # One folder per Azure resource
│   └── <slug>/                               # e.g. service-bus, blob-storage, postgresql
│       ├── README.md                         # Guide
│       └── alternatives/                     # One page per alternative
├── targets/                                  # One page per target environment
├── recipes/                                  # <capability>/<platform>/<implementation>
│   └── object-storage/azure-local/azurite/   # Recipe source, README, test app
├── recipe-packs/                             # One pack per environment, e.g. azure-local
└── samples/                                  # End-to-end apps, e.g. OrderManagementApp
```

| Folder | What it holds |
|---|---|
| [`resources/`](./resources) | One guide per Azure resource: what carries over to Azure Local, what you change, and the alternatives, with their limitations. |
| [`recipes/`](./recipes) | [Radius](https://docs.radapp.io/concepts/) Recipes: how each platform provides a resource, for example Azure Service Bus on Azure and RabbitMQ on Azure Local. |
| [`recipe-packs/`](./recipe-packs) | One Recipe Pack per platform, choosing the Recipe for each resource. |
| [`samples/`](./samples) | End-to-end applications that use the Recipes and Recipe Packs on Azure and on Azure Local. |

Some folders, such as `targets/`, are planned and not there yet. [Repository structure](./docs/repository-structure.md) explains each building block, the guide format and the labels the guides use.

## Getting started

1. **Run a sample.** Start with the [Order Management sample](./samples/OrderManagementApp/README.md). It runs one application definition and one set of container images on AKS with Azure services, and on AKS on Azure Local, where it keeps running when the site loses its link to Azure. Its README shows how to run it on your machine, on Azure and on Azure Local.
2. **Reuse the Recipes and Recipe Packs.** [Recipes and Recipe Packs](./docs/recipes-and-recipe-packs.md) explains how an application uses them, how the sample does it, and how to use the ones in this repository for your own app.
3. **Check the guide for each Azure service your app uses.** The [resource guides](./resources) say what carries over to Azure Local, what you change and which alternative to use.

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
- The container Recipe [`recipes/kubernetes/kubernetes-containers.bicep`](./recipes/kubernetes/kubernetes-containers.bicep)
  is adapted from the Kubernetes container Recipe in
  [radius-project/resource-types-contrib](https://github.com/radius-project/resource-types-contrib),
  under the Apache License 2.0. The file marks the changes, and its
  [license](./recipes/kubernetes/kubernetes-containers.LICENSE) is included alongside it.
- NuGet dependencies, including Azure SDK libraries, the AWS SDK for .NET (S3),
  Microsoft.Identity.Web, Dapper, Microsoft.Data.SqlClient, and RabbitMQ.Client, are referenced by the
  sample's project files and restored during the build. Refer to each package
  for its license and notices.
- Deployment definitions use external tools and container images, including
  Radius, Kubernetes, RabbitMQ, SeaweedFS, SQL Server, and Keycloak. These components
  have their own licenses and usage terms; this repository's license does not
  replace them.

## Trademarks

This project may contain trademarks or logos for projects, products, or services.
Authorized use of Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must
not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
