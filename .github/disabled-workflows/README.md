# Disabled upstream workflows

`release.yml` is preserved here because it publishes the upstream `graphqlite`
packages to PyPI and crates.io. GitHub Actions does not discover workflows in
this directory, so tags pushed to this fork cannot trigger those publishers.

Before restoring it to `.github/workflows/`, configure package ownership,
registry credentials, and release behavior for this fork.
