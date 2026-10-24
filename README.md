# zig-ndk

Android NDK discovery and sysroot integration for Zig 0.17.0.
The package finds an unpacked NDK, describes its ABIs, and generates the libc paths file for Android links.
It does not replace `ndk-build` or the NDK CMake toolchain.

Status: experimental. The layout baseline is NDK r29. Android device execution is not covered by the tests.

## Requirements

- Zig 0.17.0.
- An unpacked Android NDK for Android links. Host tests and ABI compile checks need no NDK.
- Bash, jq, unzip, and standard Unix text and hash tools for `sync-ndk`.

NDK r29 (`29.0.14206865`) remains pinned to preserve the package's existing ABI and layout baseline.
It is an unsupported NDK release. Other revisions are not covered by the pin or drift check.
The optional devenv shell downloads r29 and provides the development tools.

## Build and test

```sh
zig build
zig build test
zig build check
zig build fmt-check
```

The default build registers the package and installs nothing.
`test` runs the unit and consumer-shaped integration tests.
`check` also compiles the package for all five Android ABIs without running Android binaries.
A non-native `-Dtarget` makes `test` compile-only.

With an unpacked NDK:

```sh
zig build ndk-link-check -Dndk=/path/to/android-ndk-r29
zig build sync-ndk -Dndk=/path/to/android-ndk-r29
zig build all -Dndk=/path/to/android-ndk-r29
```

`ndk-link-check` links a bionic executable and checks its ELF architecture, interpreter, and `libc.so` dependency.
It does not run the executable. Defaults are `arm64-v8a` and API 35.
Use `-Dabi=<name>`, `-Dapi=<level>`, and `-Doptimize=<mode>` to select another configuration.
The modes are `debug`, `safe`, `fast`, and `small`.
The build rejects API levels below 24 in `debug` and `safe` because their panic path needs newer bionic functions.
`riscv64` requires API 35 in every mode.

`sync-ndk` checks the pinned archive, revision, and ABI metadata.
Keep the original r29 archive beside the unpacked directory, or supply `--zip` when invoking `tools/sync-ndk.sh` directly.
`all` combines `check`, `fmt-check`, `ndk-link-check`, and `sync-ndk`.
Use `zig build fmt` to format the source files.

## Use as a dependency

Place a checkout inside your project, for example at `vendor/zig-ndk`.
Zig 0.17 rejects path dependencies outside the project root.
Add this entry to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_ndk = .{ .path = "vendor/zig-ndk" },
},
```

For an application with `src/main.zig`, use this build script:

```zig
const std = @import("std");
const zig_ndk = @import("zig_ndk");

pub fn build(b: *std.Build) !void {
    const dep = b.dependency("zig_ndk", .{});
    const exe = b.addExecutable(.{
        .name = "app",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .android,
                .android_api_level = 35,
            }),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    exe.root_module.addImport("ndk", dep.module("ndk"));
    _ = try zig_ndk.linkAndroid(dep.builder, dep.module("ndk"), exe, .{
        .abi = "arm64-v8a",
        .api_level = 35,
    });
    b.installArtifact(exe);
}
```

Set `ANDROID_NDK_HOME` to the unpacked NDK before building.
Discovery checks an explicit `.ndk` option first, then `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, and `ANDROID_NDK`.
Missing environment paths fall through. An explicit path does not fall through.
The module `ndk` exposes `Abi`, `HostTag`, `Ndk`, `LibcPaths`, and `Error` for application code.
Call `linkAndroid` once per compilation. It sets the libc file and libc linkage, but leaves executable linkage to the caller.

## Layout and ownership

- `root.zig`: public module.
- `src/ndk.zig`: ABI facts, discovery, and sysroot paths.
- `src/libc_file.zig`: Zig's seven-field libc paths format.
- `build.zig`: build integration and checks.
- `test/integration_test.zig`: consumer-shaped tests with temporary NDK directory trees.
- `tools/`: NDK archive pin and drift check.

`Ndk` borrows its root and sysroot strings. Follow each path method's allocator contract.
`LibcPaths.forAndroid` copies three paths. Release them with `deinit` and the same allocator.
See [CONTRACT.md](CONTRACT.md) for discovery, ABI, and linkage rules.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for Zig attribution.
The package contains no NDK binaries or headers.
The NDK is a separate Google download subject to the [Android SDK terms](https://developer.android.com/studio/terms).
