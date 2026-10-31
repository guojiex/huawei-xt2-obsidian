# libgit2 N-API

This module is wired into the production App HAP through `entry/src/main/cpp/` and is also packaged in the `ohosTest` HAP for isolated validation. The existing Web/isomorphic-git implementation remains in the repository as historical implementation and fallback evidence.

## API

- `getVersion()` / `getFeatures()` report the linked libgit2 build.
- `getRepositoryState(path)` reads the current branch, HEAD, worktree/index status count, pack count, and ahead/behind counts against `origin/xt2`.
- `clone(options)` clones an HTTP(S) repository into a new target directory, with optional branch, Basic credentials or Bearer token, CA override, and transfer progress callback.
- `gitAction(options)` supports `stage`, `commit`, `fetch`, and `push` on an existing repository.

`stage` writes the libgit2 index and excludes the root `.trash` path while retaining any already tracked `.trash` index entries. `commit` writes Git objects and the current branch reference. `fetch` updates Git objects and `origin/xt2`. `push` fetches first, targets only `refs/heads/xt2`, rejects a non-fast-forward update, and never uses a force refspec. These operations do not checkout files or write/delete note or attachment paths in the worktree.

`pull` and checkout are intentionally not exposed. libgit2 does not promise an all-files transaction or rollback after a failed/interrupted checkout, and `AtomicFile` cannot wrap those native writes. Do not add an existing-vault checkout until an application-level recovery boundary is designed and verified.

Clone accepts only a non-existent absolute target path. The App obtains its path from `VaultRegistry` and the shared resolver, creates a unique `__importing` directory, verifies the cloned repository from disk, and registers it only after validation. Clone failure cleanup is limited to that marked import. Never pass an existing vault as a clone target.

HTTPS uses the HarmonyOS preset CA path by default; `caFile` is only for exceptional private-CA environments. Credential values stay in operation memory and are not logged or written to the repository URL. App tokens are read from `@kit.AssetStoreKit`; Basic and Bearer are selected by remote provider. Device tests currently verify authentication with a local isolated HTTP fixture; provider-specific HTTPS authentication remains unverified.

## Build and validation

Build the Native dependencies for the arm64 API 24 compatibility target:

```sh
./native/git2_napi/build.sh
```

This targets **arm64-v8a** with `OHOS_COMPATIBLE_SDK_VERSION=24` by default, which covers the XT2 device and Apple Silicon Mac emulators. A second architecture exists only for x86_64 emulator images — Windows DevEco ships no arm64 image, so an arm64-only HAP is rejected there with `install failed, code:9568347` (ABI mismatch):

```sh
OHOS_ARCH=x86_64 ./native/git2_napi/build.sh        # artifact: .build/out/libs/x86_64
OHOS_NDK=/path/to/openharmony/native ./native/git2_napi/build.sh   # non-macOS default SDK path
```

Set `OHOS_NDK` when the NDK is not at the macOS default `/Applications/DevEco-Studio.app/...`. Build trees are keyed per architecture (`libgit2-x86_64/`, `mbedtls-x86_64/`, …); the arm64 trees keep their original paths so existing artifacts stay valid. Only `arm64-v8a` and `x86_64` are accepted; anything else exits with an error.

This uses the installed API 26 Native SDK/sysroot with `OHOS_COMPATIBLE_SDK_VERSION=24`; it is compile evidence, not API 24 device evidence. Both App and test HAP builds package `libgit2_napi.so` with `libgit2.so.1.9`.

The API 26 emulator Hypium suite `Git2Native` currently passes 9/9. It covers module load, HTTPS system CA clone, isolated Basic/Bearer authentication, branch and progress callbacks, byte hashes, bad-credential and unreachable-endpoint cleanup, existing-target refusal, index-write failure protection, duplicate stage/push, `.trash` exclusion, commit/fetch/push, and rejection of remote divergence. The fixture is local and disposable; no real user remote is used.

API 24 / XT2 device load and sync, production App UI end-to-end, AssetStoreKit runtime retrieval, actual provider HTTPS authentication, and pull/checkout recovery remain unverified.
