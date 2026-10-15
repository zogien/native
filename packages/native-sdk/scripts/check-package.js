#!/usr/bin/env node

// Validate the actual installed package outside the checkout: build graph,
// packaging CLI sources, and a compiled default TypeScript app.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
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
  run(process.execPath, [npm, 'pack', '--quiet', '--pack-destination', work], packageRoot);
  const tarballs = readdirSync(work).filter(name => name.endsWith('.tgz'));
  assert.equal(tarballs.length, 1, 'Expected exactly one npm tarball');
  const tarball = join(work, tarballs[0]);
  const installation = join(work, 'installation');
  mkdirSync(installation);
  writeFileSync(join(installation, 'package.json'), '{"private":true}');
  run(process.execPath, [npm, 'install', tarball, '--no-audit', '--no-fund'], installation);
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
  const app = join(work, 'app');
  run(process.execPath, [dispatcher, 'init', app, '--full'], work);
  run(process.execPath, [dispatcher, 'check'], app);
  // Linux CI needs no GTK development libraries with the headless host.
  // Windows uses its desktop host, which links the compiled core's OS libraries.
  const platform = process.platform === 'linux' ? ['-Dplatform=null'] : [];
  run('zig', ['build', ...platform, '-Doptimize=ReleaseFast', '-j1'], app);
  console.log('Verified npm package: ' + tarball);
} catch (error) {
  console.error('Package check failed; reproduction retained at ' + work);
  throw error;
}
