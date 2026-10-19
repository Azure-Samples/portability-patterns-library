# Contributing

This repository is maintained by Microsoft and is not currently accepting unsolicited
external pull requests. Bug reports and questions are welcome through GitHub Issues.
Any contributions accepted by the maintainers remain subject to Microsoft's
Contributor License Agreement requirements.

## Contributor License Agreement

Most contributions require you to agree to a Contributor License Agreement (CLA)
declaring that you have the right to, and actually do, grant us the rights to use
your contribution. For details, visit <https://cla.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether you
need to provide a CLA and decorate the PR appropriately (e.g., status check,
comment). Simply follow the instructions provided by the bot. You will only need
to do this once across all repositories using our CLA.

### Maintainer requirements

Microsoft CLA automation must be enabled and integrated for this repository.
Before merging a pull request, confirm that its `license/cla` status check reports
`All CLA requirements met`. Do not merge while CLA requirements are pending or
unmet.

## Reporting issues and proposing changes

- Search [existing issues](https://github.com/Azure-Samples/portability-patterns-library/issues)
  before opening a new one.
- For bugs, include the sample, environment, tool versions, reproduction steps,
  expected behavior, and actual behavior. Remove credentials, tokens, personal
  data, and other sensitive information from logs and configuration.
- For proposed changes or new patterns, open an issue to discuss the approach.
  Obtain maintainer approval before implementing a change or submitting an external
  pull request.
- Report security vulnerabilities privately following [SECURITY.md](./SECURITY.md).
  Do not report them in public issues or pull requests.

## Development workflow

The following workflow applies to maintainers and contributors whose changes have
been approved by the maintainers.

1. Create a branch for your change. Approved external contributors should fork
   the repository and create a branch in their fork.
2. Read the [project overview](./README.md) and the relevant sample documentation.
3. Keep changes focused and follow the existing naming, formatting, and directory
   structure. Update documentation and configuration examples when behavior changes.
4. Validate your change using the relevant build and deployment workflow.
5. Open a pull request describing the change, linking related issues, and listing
   validation performed and any environments you could not test.

### Working with samples

Samples live under [`samples/`](./samples). Follow the relevant sample's README
for prerequisites, required tool versions, build and validation commands,
deployment instructions, and the directory from which to run those commands.
Requirements may differ between samples.

When adding a sample, include a README documenting its purpose, supported
environments, prerequisites, configuration, build and validation steps, deployment
and cleanup instructions, and known limitations. Link the sample from the
[project overview](./README.md).

Validate deployment changes on the affected target when possible and describe
the results in your pull request. Cloud deployments can incur costs; clean up
resources you create. Do not commit local settings, secrets, or credentials.
Preserve third-party license notices when updating bundled dependencies or assets.

## Code of conduct

This project has adopted the [Microsoft Open Source Code of Conduct](./CODE_OF_CONDUCT.md).
For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional
questions or comments.
