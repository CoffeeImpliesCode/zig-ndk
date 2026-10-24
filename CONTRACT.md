# zig-ndk design contract

## 1. Scope

The package discovers an unpacked Android NDK and connects its sysroot to Zig 0.17.0.
It contains no NDK headers, binaries, C translation, or replacement for the NDK build systems.
NDK r29 (`29.0.14206865`) is the layout baseline. Other NDK revisions need a separate compatibility check.

## 2. Sysroot mapping

Zig reads a libc paths file with seven mandatory keys.
`LibcPaths.render` matches `std.zig.LibCInstallation.render`, including its comment block and trailing newline.

| Key | Android value |
|---|---|
| `include_dir` | `<sysroot>/usr/include` |
| `sys_include_dir` | `<sysroot>/usr/include` |
| `cc_dir` | `<sysroot>/usr/lib/<triple>/<api>` |
| `crt_dir` | `<sysroot>/usr/lib/<triple>/<api>` |
| `msvc_lib_dir` | empty |
| `kernel32_lib_dir` | empty |
| `darwin_sdk_dir` | empty |

The sysroot is `<ndk>/toolchains/llvm/prebuilt/<host-tag>/sysroot`.
Discovery also accepts the nixpkgs wrapper layout under `libexec/android-sdk/ndk-bundle`.

| ABI | Sysroot triple | Minimum API |
|---|---|---|
| `armeabi-v7a` | `arm-linux-androideabi` | 21 |
| `arm64-v8a` | `aarch64-linux-android` | 21 |
| `riscv64` | `riscv64-linux-android` | 35 |
| `x86` | `i686-linux-android` | 21 |
| `x86_64` | `x86_64-linux-android` | 21 |

ABI names are NDK metadata keys. They are not sysroot directory names.
The supported host directories are `linux-x86_64`, `darwin-x86_64`, and `windows-x86_64`.
Apple Silicon uses the Darwin directory. Unsupported hosts return `UnsupportedHost`.

## 3. Decisions

### D1: Layout facts

`Abi` supplies names, triples, and API floors. `Ndk` resolves paths against an installation.
The drift script compares the ABI table with the NDK's `meta/abis.json`.
The build checks its ABI expectations against the module before linking.

### D2: Separate module and build integration

The published `ndk` module contains `Abi`, `HostTag`, `Ndk`, `Error`, and `LibcPaths`.
It does not set a target or optimization mode.
The package's build script exports `abi_names`, `AndroidLinkOptions`, `ResolvedNdk`, and `linkAndroid`.
Consumers import that build script through `@import("zig_ndk")`.

### D3: Discovery order

1. Explicit `.ndk` path, or this package's `-Dndk` option.
2. `ANDROID_NDK_HOME`.
3. `ANDROID_NDK_ROOT`.
4. `ANDROID_NDK`.

Trim leading and trailing whitespace. Preserve interior whitespace.
An explicit path is a pin. Do not replace it with another candidate after a failure.
Skip absent environment candidates. Stop at an existing candidate, including an invalid installation.
Diagnostics identify the source and attempted paths.

### D4: Build options

NDK discovery uses `b.option`, because it selects a directory rather than a named system library.
The build registers its checks even when no NDK exists. NDK-dependent checks then fail with discovery instructions.
Configure-time file probes declare their metadata dependencies.

### D5: No vendored C

The package describes an external sysroot. Applications handle their own C source and translation needs.
The NDK remains a separate download under Google's terms.

### D6: API-specific CRT directory

Use `usr/lib/<triple>/<api>` for both CRT fields. The numeric directory contains the Android CRT objects and linker scripts.
API-independent archives, including `libc.a` and `libc++_shared.so`, live in the parent directory.
The supported build integration uses dynamic bionic linkage.

## 4. Ownership and linkage

`Ndk` borrows its root and sysroot strings. Allocator-taking path methods return owned allocations unless their API states otherwise.
`LibcPaths.forAndroid` owns copies of three paths. `cc_dir` borrows its owned `crt_dir` value.
Optional field overrides remain borrowed. `deinit` frees only the three original owned fields.
`render` allocates nothing and does not flush the writer.

`linkAndroid` takes the dependency builder, the published module, a compilation, and options.
It generates a libc paths file and sets the compilation's libc linkage.
The caller sets the Android target, API level, optimization mode, and dynamic executable linkage.
A target/ABI mismatch, conflicting optimization mode, or second call on one compilation returns an error.
The build refuses API levels below 24 in `debug` and `safe`, and `riscv64` below API 35.
The generated libc file and resolved root live for the build run.

## 5. Checks and limits

- `test`: unit tests and consumer-shaped tests with temporary directory trees.
- `ndk-abi-check`: compile-only checks for all five Android ABIs, without an NDK.
- `ndk-link-check`: a real bionic link and ELF architecture, interpreter, and `libc.so` checks.
- `sync-ndk`: archive digests, revision, layout, and ABI metadata against the recorded r29 pin.
- `fmt-check`: source formatting.
- `check`: `test` and `ndk-abi-check`.
- `all`: every check above.

A successful ABI compile does not establish a bionic link.
A successful link does not establish Android device execution.
No device or emulator runner forms part of this package.
