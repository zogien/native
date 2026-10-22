# Releasing the fork

The public CLI is `@zogien/native-sdk`. Its eight binary packages use
`@zogien/native-sdk-<platform>`. The `native` command and the bundled
`@native-sdk/core` authoring API keep their existing names; the core package is
included in the CLI payload and is not published separately by this fork.

## Prepare a release

1. Update `packages/native-sdk/package.json` to the next version,
   `X.Y.Z-fork.N`: the upstream version the fork is based on plus a fork
   counter. Keep `publishConfig.tag` set to `latest`: fork releases are the
   only release line of these packages.
2. Run `npm --prefix packages/native-sdk run version:sync`. The repository's
   existing shared-version convention also updates the bundled core and the
   example/test app pins. Platform names and the CLI lockfile are checked by
   `npm --prefix packages/native-sdk run version:check`.
3. Run `npm --prefix packages/native-sdk run scripts:check` and confirm CI is
   green on the release commit. Package verification (`package:check`) runs in
   the release workflow, which builds every target; run it locally only when
   changing packaging.
4. Open a pull request with the release configuration and merge it into `main`.
5. Create an annotated tag on the merged commit,
   `git tag -a fork/vX.Y.Z-fork.N -m "Release X.Y.Z-fork.N"`, and push only
   that tag to `origin`. Ordinary `main` pushes do not publish. Never overwrite
   a published version or move a published tag.

## GitHub build and publish

`.github/workflows/release.yml` runs when a `fork/v*` tag is pushed. It verifies
that the tag matches the package version and that package provenance points to
this repository. A macOS runner cross-compiles all eight CLI targets, verifies
the installed host packages, and uploads nine npm tarballs plus the binaries as
Actions artifacts. The publish job uses these exact tarballs, publishes all
platform packages before the main package under the `latest` dist-tag, and
creates a GitHub release with generated notes. Already-published versions are
skipped when rerunning a partially completed job.

You can also run the workflow manually. Choose `main` to build and download
artifacts without publishing, or choose the matching `fork/v...` tag to publish.
The publish job uses the GitHub environment named `Release`.

### npm authentication

Publishing uses npm trusted publishing (OIDC); the workflow has no npm token.
Each of the nine packages has a GitHub Actions trusted publisher:

- Owner: `zogien`
- Repository: `native`
- Workflow filename: `release.yml`
- Environment: `Release`
- Allowed actions: `npm publish` (required; without it the publisher can only
  stage versions) and, on the main package, `npm dist-tag`

npm shows a new trusted publisher as pending until a release publishes through
it, and asks for that publish before the deadline shown on the package settings
page, so add or recreate publishers shortly before a release. If a package has
no trusted publisher, `npm publish` fails for that package. After a release,
`npm info @zogien/native-sdk` reports the version as published by
`GitHub Actions <npm-oidc-no-reply@github.com>`.

Trusted publishers are configured on packages that already exist. A new package
needs its first version published manually from an npm account with 2FA, using
`npm publish <tarball> --access public --tag latest`. Trusted publishing
requires npm 11.5.1 or newer; the workflow uses Node 24. See the
[npm trusted publishing guide](https://docs.npmjs.com/trusted-publishers/) and
[scoped public package publishing](https://docs.npmjs.com/creating-and-publishing-scoped-public-packages/).

## Install

```sh
npm install -g @zogien/native-sdk
native version
```
