# libgit2 N-API PoC

This is a standalone native module experiment. It is not listed in the production app's dependencies and is not wired into `SyncPage` or the current isomorphic-git bridge. The native module is packaged only by the `ohosTest` HAP for isolated API 26 emulator validation.

The module exports:

- `getVersion(): string`
- `getFeatures(): { threads: boolean; https: boolean; ssh: boolean }`
- `getRepositoryState(path): { branch: string; clean: boolean; statusEntryCount: number; packFileCount: number }` (read-only test probe)
- `clone(options): Promise<string>`

`clone` accepts `{ url, targetPath, branch?, username?, password?, caFile?, onProgress? }`. It accepts HTTP(S), checks HTTPS against HarmonyOS's preset CA bundle by default, and allows `caFile` as an optional override for private CA setups. It rejects credentials embedded in URLs and refuses a target path that already exists. Credential pairs stay in memory for the operation and are never logged. `branch` selects the branch to check out; `onProgress` receives best-effort packfile counters on the JS thread. The credential callback supports HTTP username/password; provider-specific GitHub/Gitee behavior still needs validation.

Clone runs on N-API async work so the caller thread does not wait for network I/O. Rejected promises include the libgit2 error detail. A failed clone may leave a partial new target; the caller owns cleanup. Do not pass a path to an existing vault. The intended future caller must derive the target from `context.filesDir` through the app's shared path resolver and pass only its unique import directory.

The `ohosTest` target links the same module and requests `ohos.permission.INTERNET` for its local HTTP fixture and public HTTPS probe. Build the test HAP with `hvigorw assembleHap --mode module -p module=entry@ohosTest -p product=default`; this is test-only packaging and does not enable the module in the production HAP.

The local API 26 SDK documents `/etc/ssl/certs/cacert.pem` as the preset CA bundle for `@ohos.net.http` starting at API 10. The wrapper configures libgit2 to read that bundle before HTTPS clones. The path and native mbedTLS access still need validation on API 24 / XT2.

Build the native dependency and wrapper with `./native/git2_napi/build.sh`. The script downloads libgit2 v1.9.7 and mbedTLS v3.6.7, builds for arm64 with `OHOS_COMPATIBLE_SDK_VERSION=24`, and writes libraries under `.build/out/libs/arm64-v8a/`. It does not modify the app build files. The generated N-API module links against `libgit2.so.1.9`; both libraries must be packaged together when integration is evaluated.

The local SDK used for the compile has API 26 headers/sysroot. The API 24 target flag is compile evidence only; module loading and clone behavior still require API 24 / XT2 validation.
