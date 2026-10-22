# @zogien/native-sdk

An unofficial, personally maintained fork of [vercel-labs/native](https://github.com/vercel-labs/native), based on upstream `v0.11.0`. This fork is not affiliated with or endorsed by Vercel.

Native SDK is a toolkit for building native desktop applications with TypeScript and Native markup.

This fork is maintained for personal needs, including fixes and features. Current changes focus on builds and npm distribution. Fork versions use `0.11.0-fork.N`; upstream updates are reviewed before merging.

## Fork changes

- Separate installed SDK builds from repository tests and examples.
- Include the CLI sources and resolve platform packages under the `@zogien` scope.
- Support TypeScript core staging when installed inside `node_modules`.

## Quick start

Requires Node.js 24 or later. The CLI command remains `native`.

```bash
npm install -g @zogien/native-sdk
native version
native init my_app
cd my_app
native dev
```

This installs the latest fork release. To pin a release, add its version to the package name: `@zogien/native-sdk@<version>`.

## Resources

- [CLI usage and toolchain setup](packages/native-sdk/README.md)
- [Fork releases](https://github.com/zogien/native/releases)
- [Upstream documentation](https://native-sdk.dev/docs/quick-start) — use this fork's installation command above.
- [Examples](examples/README.md)

Report fork-specific problems in [this repository's issues](https://github.com/zogien/native/issues).

## License

[Apache-2.0](LICENSE). Original project: [vercel-labs/native](https://github.com/vercel-labs/native).
