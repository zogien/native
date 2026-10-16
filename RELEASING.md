# Releasing the fork

The public CLI is `@zogien/native-sdk`. Its eight binary packages use
`@zogien/native-sdk-<platform>`. The `native` command and the bundled
`@native-sdk/core` authoring API keep their existing names; the core package is
included in the CLI payload and is not published separately by this fork.

## Prepare a release

1. Update `packages/native-sdk/package.json` to the next version, starting with
   `0.11.0-fork.1`. Keep `publishConfig.tag` set to `fork` for fork releases.
2. Run `npm --prefix packages/native-sdk run version:sync`. The repository's
   existing shared-version convention also updates the bundled core and the
   example/test app pins. Platform names and the CLI lockfile are checked by
   `npm --prefix packages/native-sdk run version:check`.
3. Run `npm --prefix packages/native-sdk run scripts:check`,
   `npm --prefix packages/native-sdk run package:check`, and
   `scripts/gate.sh fast`. Package verification builds or uses a staged local
   host binary, installs the real platform and main tarballs together, and
   builds both the default managed app and the `--full` app outside the checkout.
4. Review and commit the release configuration. Create an annotated tag on that
   commit, for example `git tag -a fork/v0.11.0-fork.1 -m "Release 0.11.0-fork.1"`.
5. Push the commit and the specific tag to `origin`. Ordinary `main` pushes do
   not publish. Never overwrite a published version or move a published tag.

## GitHub build and publish

`.github/workflows/release.yml` runs when a `fork/v*` tag is pushed. It verifies
that the tag matches the package version and that package provenance points to
this repository. A macOS runner cross-compiles all eight CLI targets, verifies
the installed host packages, and uploads nine npm tarballs plus the binaries as
Actions artifacts. The publish job uses these exact tarballs, publishes all
platform packages before the main package, and creates a GitHub prerelease.
Already-published versions are skipped when rerunning a partially completed job.

You can also run the workflow manually. Choose `main` to build and download
artifacts without publishing, or choose the matching `fork/v...` tag to publish.
The publish job uses the GitHub environment named `Release`.

### First publication

For the initial nine packages, either publish the downloaded tarballs manually
with an npm account that has 2FA enabled, or add a short-lived granular npm write
token with bypass 2FA enabled as the `NPM_TOKEN` secret in the `Release`
environment. The token must allow creating packages in the `@zogien` scope.
Publish platform tarballs first and the main tarball last, always using
`npm publish <tarball> --access public --tag fork`.

### Subsequent publications

Configure an npm GitHub Actions trusted publisher on each of the nine packages:

- Owner: `zogien`
- Repository: `native`
- Workflow filename: `release.yml`
- Environment: `Release`

After confirming trusted publishing works, remove the bootstrap `NPM_TOKEN`.
The workflow grants `id-token: write` and publishes with provenance. Trusted
publishing requires a supported npm version (11.5.1 or newer); the workflow uses
Node 24. See the [npm trusted publishing guide](https://docs.npmjs.com/trusted-publishers/)
and [scoped public package publishing](https://docs.npmjs.com/creating-and-publishing-scoped-public-packages/).

## Install

```sh
npm install -g @zogien/native-sdk@fork
native version
```
