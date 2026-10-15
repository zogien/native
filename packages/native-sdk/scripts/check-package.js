#!/usr/bin/env node

// Validate the actual installed package outside the checkout: build graph,
// packaging CLI sources, and a compiled default TypeScript app.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const metadata = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
const work = mkdtempSync(join(tmpdir(), 'native-sdk-package-'));
const env = { ...process.env };
delete env.NATIVE_SDK_PATH;
delete env.NATIVE_SDK_CORE_COMPILER;

function run(file, args, cwd) {
  execFileSync(file, args, { cwd, env, stdio: 'inherit' });
}

try {
  assert.ok(process.env.npm_execpath, 'Run this check with npm run package:check');
  const npm = process.env.npm_execpath;
  function pack(directory, destination) {
    mkdirSync(destination);
    run(process.execPath, [npm, 'pack', '--quiet', '--pack-destination', destination], directory);
    const tarballs = readdirSync(destination).filter(name => name.endsWith('.tgz'));
    assert.equal(tarballs.length, 1, 'Expected exactly one npm tarball');
    return join(destination, tarballs[0]);
  }
  // Install the local host binary in the same transaction as the main package.
  // New release versions must be testable before any package is published.
  const libc = process.platform === 'linux'
    ? (process.report.getReport().header.glibcVersionRuntime ? '-gnu' : '-musl') : '';
  const platformKey = process.platform + '-' + process.arch + libc;
  const platformRoot = join(packageRoot, 'npm', platformKey);
  const platformMetadata = JSON.parse(readFileSync(join(platformRoot, 'package.json'), 'utf8'));
  assert.equal(metadata.optionalDependencies[platformMetadata.name], platformMetadata.version);
  const executable = process.platform === 'win32' ? 'native.exe' : 'native';
  let binary = join(platformRoot, 'bin', executable);
  if (!existsSync(binary)) {
    const prefix = join(work, 'host-cli');
    run('zig', ['build', 'cli', '-Doptimize=ReleaseSmall', '-j1', '--prefix', prefix], join(packageRoot, '../..'));
    binary = join(prefix, 'bin', executable);
  }
  const staging = join(work, 'platform-package');
  mkdirSync(join(staging, 'bin'), { recursive: true });
  copyFileSync(join(platformRoot, 'package.json'), join(staging, 'package.json'));
  copyFileSync(binary, join(staging, 'bin', executable));
  const platformTarball = pack(staging, join(work, 'platform-tarball'));
  const tarball = pack(packageRoot, join(work, 'main-tarball'));
  const installation = join(work, 'installation');
  mkdirSync(installation);
  writeFileSync(join(installation, 'package.json'), '{"private":true}');
  run(process.execPath, [npm, 'install', tarball, platformTarball, '--no-audit', '--no-fund'], installation);
  const sdk = join(installation, 'node_modules', metadata.name);
  for (const path of ['tests', 'examples', 'evals']) {
    assert.equal(existsSync(join(sdk, path)), false, path + ' must remain repository-only');
  }
  assert.ok(existsSync(join(sdk, 'packages/core/testing/index.ts')), 'Keep the public app-testing API');
  assert.ok(existsSync(join(sdk, 'tools/native-sdk/main.zig')), 'Include the downstream packaging tool source');

  const consumer = join(work, 'consumer');
  mkdirSync(consumer);
  run('zig', ['init', '--minimal'], consumer);
  const manifest = join(consumer, 'build.zig.zon');
  const dependency = JSON.stringify(relative(consumer, sdk).split(sep).join('/'));
  writeFileSync(manifest, readFileSync(manifest, 'utf8').replace(/\}\s*$/, '.dependencies = .{ .native_sdk = .{ .path = ' + dependency + ' }, }, }'));
  writeFileSync(join(consumer, 'build.zig'), [
    'const std = @import("std");',
    'const sdk = @import("native_sdk");',
    'pub fn build(b: *std.Build) void {',
    '    const dep = b.dependency("native_sdk", .{});',
    '    _ = dep.artifact("native");',
    '    inline for (.{"AppOptions", "addApp", "AppArtifacts", "addAppArtifacts", "MobileLibOptions", "addMobileLib"}) |name| {',
    '        if (!@hasDecl(sdk, name)) @compileError("Missing SDK build API: " ++ name);',
    '    }',
    '    if (dep.builder.top_level_steps.contains("test")) @panic("Repository tests leaked into the consumer build");',
    '}',
    '',
  ].join('\n'));
  execFileSync('zig', ['build', '--help'], { cwd: consumer, env, stdio: ['ignore', 'pipe', 'inherit'] });
  console.log('Consumer build graph: OK');
  // Compile the artifact too: LazyPath inputs may not be opened by --help.
  run('zig', ['build', 'cli', '-Doptimize=ReleaseSmall', '-j1'], sdk);
  run(join(sdk, 'zig-out/bin', process.platform === 'win32' ? 'native.exe' : 'native'), ['version'], work);

  const dispatcher = join(sdk, 'bin/native.js');
  const installedBinary = createRequire(join(sdk, 'package.json')).resolve(platformMetadata.name + '/bin/' + executable);
  const version = execFileSync(process.execPath, [dispatcher, 'version'], { cwd: work, env, encoding: 'utf8' });
  assert.ok(version.startsWith('native ' + metadata.version + ' '), 'Dispatcher must run the locally built release version');
  // Direct invocation must locate the fork's sibling SDK and skill payloads too.
  run(installedBinary, ['skills', 'list'], work);
  const slim = join(work, 'default-app');
  run(installedBinary, ['init', slim], work);
  assert.equal(existsSync(join(slim, 'build.zig')), false, 'Default scaffold must use the managed build');
  run(process.execPath, [dispatcher, 'check'], slim);
  const platform = process.platform === 'linux' ? ['-Dplatform=null'] : [];
  run(process.execPath, [dispatcher, 'build', ...platform], slim);
  const app = join(work, 'app');
  run(process.execPath, [dispatcher, 'init', app, '--full'], work);
  run(process.execPath, [dispatcher, 'check'], app);
  // Linux CI needs no GTK development libraries with the headless host.
  // Windows uses its desktop host, which links the compiled core's OS libraries.
  run('zig', ['build', ...platform, '-Doptimize=ReleaseFast', '-j1'], app);
  console.log('Verified npm package: ' + tarball);
} catch (error) {
  console.error('Package check failed; reproduction retained at ' + work);
  throw error;
}
