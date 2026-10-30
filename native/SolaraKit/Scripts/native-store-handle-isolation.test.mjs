import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const handle = process.env.SOLARA_STORE_HANDLE_SOURCE ?? fileURLToPath(new URL('../Sources/SolaraStore/NativeStoreHandle.swift', import.meta.url));

test('workspace ownership and lifecycle reject nonisolated access', () => {
  const folder = mkdtempSync(join(tmpdir(), 'solara-handle-isolation-'));
  try {
    const probe = join(folder, 'OwnershipProbe.swift');
    writeFileSync(probe, `public final class Store {}
func writeOwnership() { NativeStoreHandle.ownsWorkspace = true }
func readOwnership() -> Bool { NativeStoreHandle.ownsWorkspace }\nfunc subscribe() { _ = NativeStoreHandle.subscribeLifecycle {} }\nfunc unsubscribe() { NativeStoreHandle.unsubscribeLifecycle(1) }
`);
    const result = spawnSync('swiftc', ['-typecheck', '-swift-version', '6', '-module-cache-path', join(folder, 'cache'), handle, probe], { encoding: 'utf8', timeout: 30000 });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0, 'off-main ownership access must fail compilation');
    assert.match(result.stderr, /main actor-isolated static property 'ownsWorkspace' can not be mutated from a nonisolated context/);
    assert.match(result.stderr, /main actor-isolated static property 'ownsWorkspace' can not be referenced from a nonisolated context/);
    assert.match(result.stderr, /call to main actor-isolated static method 'subscribeLifecycle' in a synchronous nonisolated context/);
    assert.match(result.stderr, /call to main actor-isolated static method 'unsubscribeLifecycle' in a synchronous nonisolated context/);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test('MainActor ownership and lifecycle access compiles', () => {
  const folder = mkdtempSync(join(tmpdir(), 'solara-handle-main-'));
  try {
    const probe = join(folder, 'MainActorProbe.swift');
    writeFileSync(probe, `public final class Store {}
@MainActor func accessOwnership() {
  NativeStoreHandle.ownsWorkspace = true
  _ = NativeStoreHandle.ownsWorkspace
  let listener = NativeStoreHandle.subscribeLifecycle {}
  NativeStoreHandle.unsubscribeLifecycle(listener)
}
`);
    const result = spawnSync('swiftc', ['-typecheck', '-swift-version', '6', '-module-cache-path', join(folder, 'cache'), handle, probe], { encoding: 'utf8', timeout: 30000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});
