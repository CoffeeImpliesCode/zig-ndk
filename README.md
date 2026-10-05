# zig-ndk

Android NDK sysroot facts for Zig 0.16.0, and nothing else.

**This is not a translation of the NDK's build system.** `ndk-build`, the NDK
CMake toolchain file and every Makefile fragment in between are out of scope by
decision, not by omission — reproducing them is a different project with a
different consumer. What this package is instead: a description of where an
unpacked Android NDK keeps its sysroot, the discovery that finds that tree, and
the six-field libc paths file that Zig 0.16.0 demands and cannot derive for
itself. Pure Zig. No C, no header, no part of the NDK redistributed.

## Status

| | |
|---|---|
| Licence | MIT (`LICENSE`). Nothing upstream is vendored: no C source, no header, no `UPSTREAM`/`NOTICE` file. The tree is Zig only. |
| Toolchain | Zig 0.16.0, pinned at tag `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`, and `.minimum_zig_version = "0.16.0"` in `build.zig.zon` is the same pin. See *Gates* for what has actually been run, and read that section before trusting any status in this table. |
| NDK pinned | **r29** (`29.0.14206865`), read from the `source.properties` of an unpacked copy on this host, at `/tmp/ndkx/android-ndk-r29`. Release, revision, byte size and SHA-256 are recorded in `tools/ndk.sha256`. |
| Tests | Two roots, both wired into one step. `b.addTest` over `root.zig` compiles `src/ndk.zig` (24 tests) and `src/libc_file.zig` (4 tests); a second `b.addTest` over `test/integration_test.zig` adds 13, and is wired only while that file is present — its absence is a logged warning, never a silent pass. Command: `zig build test`, which **exits 0** on this host. |
| Cross-compiles | `zig build ndk-abi-check` compiles one test binary per ABI and never runs it. **Exits 0** on this host. |
| Real bionic link | **Observed, for one ABI at one API level: `arm64-v8a` at API 35.** `ANDROID_NDK_HOME=<r29> zig build ndk-link-check` exits 0, `zig-out/bin/ndk-link-check` is written at 4,253,184 bytes, its first four bytes are `\x7fELF`, and `file(1)` reads `ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked, interpreter /system/bin/linker64, for Android 35, built by NDK r29 (14206865)`. The gate installs its artefact and then runs a generated `ndk-elf-check` that reopens the installed file and refuses unless it begins with the ELF magic, so it cannot pass without a binary — verified negatively too: pointed at a text file it fails on the magic, and with the file absent it fails on `FileNotFound`. The other four ABIs are compiled by `ndk-abi-check` but have **not** each been observed linking; run `-Dabi=<name>` to cover one. |
| Allocates | In the build path only. `Ndk.find`, `Ndk.open`, `Ndk.probeCandidates`, `Ndk.describeProbeFailure`, `Ndk.readVersion`, `Ndk.libcDirFor` and `Ndk.apiLevelsFor` take a caller-supplied allocator. `libcDirFor` and `apiLevelsFor` hand back a slice the caller frees; `probeCandidates` hands back a `Probes`, which *owns* its paths and is released with `Probes.deinit`. The `Ndk` value itself allocates nothing and frees nothing — see *Ownership*. |
| Runs on Android | **No claim at all.** Nothing in this package was executed on a device or an emulator. |
| NDK revisions covered | r29 only. r30 exists and is the current LTS; it was not read, and neither were r27 or r28. Nothing above is claimed for any other revision. |
| Upstream sync | `tools/sync-ndk.sh` — there is no upstream repository, so this is re-resolve-and-diff, not merge. It re-reads `source.properties`, hashes the archive, re-parses `meta/abis.json` and diffs it against the table in `src/ndk.zig`, exiting non-zero on any change. Run it read-only with `tools/sync-ndk.sh`; this table asserts no result for it, because no run of it was observed while this file was written. |

### Gates

Every row names a step that is registered literally in `build.zig` as
`b.step(...)`, and every row carries its **observed** status. "Not established"
means the command was not run to a state that proves what the row claims — not
that it was run and failed.

| Gate | Command | What a green run establishes | Needs an NDK? | Observed |
|---|---|---|---|---|
| fmt | `zig build fmt-check` | formatting | no | not established here |
| host tests | `zig build test` | libc paths file parsing and rendering, discovery order, error paths, on the host target | no | **exits 0** |
| cross compile | `zig build ndk-abi-check` | each ABI's `std.Build` target query resolves and the module compiles for it | no | **exits 0** |
| libc link | `zig build ndk-link-check` | Zig links a bionic Android binary against the real sysroot, **and** the installed artefact is read back and confirmed to be an ELF | **yes** | **exits 0 and writes `zig-out/bin/ndk-link-check`**, a 4,253,184-byte aarch64 Android PIE with interpreter `/system/bin/linker64`, for `arm64-v8a` at API 35 |
| local aggregate | `zig build check` | `test` + `ndk-abi-check`, in one run | no | **exits 0** |
| CI contents | `zig build test` **and** `zig build ndk-abi-check` | exactly what the two CI jobs run, which together equal `zig build check` | no | see *.github/workflows/ci.yml* |
| everything | `zig build all` | `check` + `fmt-check` + `ndk-link-check` | **yes** | not established here |

**CI never invokes `zig build check`.** `.github/workflows/ci.yml` splits it:
the `test` job runs `zig build test` and the `cross` job runs
`zig build ndk-abi-check`, as two jobs with two caches. The `check` step exists
for a local one-command run, and the two jobs are what CI actually executes.
There is no CI job named for `fmt-check` or `ndk-link-check` either — the
workflow has separate `fmt` and `link` jobs that do run them.

**What the link gate covers, and what it does not.** It was observed green on
one ABI at one API level: `arm64-v8a` at API 35. `-Dabi=<name>` and `-Dapi=<n>`
select the rest, and `riscv64` needs `-Dapi=35` explicitly (see *Build
options*). Until each ABI has been observed linking, "this ABI is covered" is a
claim no run supports — while "the mechanism works against a real r29 sysroot"
is established, both by the manual probe in *The problem* and by this gate.

## The problem

Zig 0.16.0 ships zero NDK awareness. A full-tree grep for `ndk` in `lib/std`
hits only `libcxx/include/__locale_dir/locale_base_api/android.h` (upstream
libc++ code) and unrelated ML-KEM `Ndk` fields; `lib/std/Build.zig` contains no
android reference at all.

Four probes, run by hand against Zig 0.16.0 on this host, the last of them
against the unpacked NDK r29 sysroot. **None of them went through this
package's `build.zig`** — each is a bare `zig build-exe`, which is what makes
them usable as evidence about the *compiler* rather than about the package:

| Probe | Result | Label |
|---|---|---|
| `zig build-exe -target aarch64-linux-android` | exit 0, produces an ELF | exercised compilation |
| `zig build-exe -target aarch64-linux-android -lc` | `error: unable to provide libc for target 'aarch64-linux.5.10...6.19-android.29'` | exercised compilation |
| `--libc <sysroot>/usr/lib/aarch64-linux-android/35` | `error: unable to parse libc paths file at path ...: IsDir` | exercised compilation |
| `--libc <generated paths file> -dynamic -lc` | **exit 0** | exercised compilation |

Three of those four lines are a refusal or a success that does not reach bionic.
The first builds, but only because nothing asks it for a libc. The second and
third are the two refusals this package exists to remove, and the third is the
instructive one: Zig was pointed straight at the sysroot, and it answered
`IsDir`, because `std.zig.LibCInstallation.parse` reads a *file*. There is no
way to hand Zig a directory and no flag that changes that.

The fourth probe's artefact, read with `file(1)`. `file(1)` prints this as one
line; it is wrapped here at the commas, and nothing else about it is edited:

```
ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV),
dynamically linked, interpreter /system/bin/linker64, for Android 35,
built by NDK r29 (14206865), with debug_info, not stripped
```

**That binary came from the manual `zig build-exe` probe above.** It did not
come from `zig build ndk-link-check`, which does not currently emit an ELF at
all — see *Gates*. Read this block as evidence that the mechanism works against
a real r29 sysroot, and as nothing at all about the package's own link gate.

That line is the whole product in one string. Zig compiled the binary, and
bionic supplied the loader, the CRT and `libc`. `/system/bin/linker64` is the
interpreter the r29 sysroot's `crtbegin_dynamic.o` asks for, and "built by NDK
r29" is recorded by the linker from the sysroot it linked against. The two
refusal strings above it are verbatim compiler output, character for character,
including the elided `...` inside the target triple, which is the compiler's
own abbreviation and not an edit made here.

**Consequence.** A freestanding Android binary builds. Anything that needs
bionic — `libc.so`, `libm.so`, the CRT objects, `stdio.h` — does not build from
Zig's own resources, because Zig bundles no bionic (`lib/libc/` holds darwin,
freebsd, glibc, mingw, musl, netbsd, openbsd, wasi and include, and nothing
else). Suppointing it at the sysroot works, but only through a hand-written libc
paths file, and `LibCInstallation.parse` will not accept a directory. That gap
is what this package fills. It is the whole scope.

## Use from Zig

The published module is the **facts half**: ABI names, sysroot triples, API
levels and sysroot paths, readable from your own Zig code. The **build half** —
turning those facts into a compiled Android binary — is four `pub` declarations
at the end of this package's `build.zig`: `abi_directory_names`,
`AndroidLinkOptions`, `ResolvedNdk` and `linkAndroid`. They are separate on
purpose: a consumer who only reads the layout should not pull `std.Build` into
their import table.

**The dependency is named `zig_ndk`, with an underscore.** `build.zig.zon`
declares `.name = .zig_ndk`, an enum literal, and 0.16 takes the package name
from that literal: `"zig-ndk"` is not a valid dependency here and
`b.dependency("zig-ndk", …)` panics with *no dependency named 'zig-ndk'*. The
underscore spelling is what appears in your `.dependencies`, in
`b.dependency`, and in `@import`.

In your build.zig, all of it:

```zig
const ndk_dep = b.dependency("zig_ndk", .{});
const zig_ndk = @import("zig_ndk");

// Facts, for your own Zig code: Abi, HostTag, Ndk, Error.
exe.root_module.addImport("ndk", ndk_dep.module("ndk"));

// Wiring, for a compilation.
exe.linkage = .dynamic; // emits -dynamic; bionic supplies the interpreter
const resolved = zig_ndk.linkAndroid(ndk_dep.builder, ndk_dep.module("ndk"), exe, .{
    .abi = "arm64-v8a",
    .api_level = 35,
    // .ndk = null -> ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_NDK, in
    // that order
}) catch |err| {
    // linkAndroid returns `Error!ResolvedNdk`. A build script's `build`
    // function returns `void`, so `try` cannot be used here: catch the
    // failure and turn it into whatever your build does about bad config.
    @panic("zig-ndk: " ++ @errorName(err));
};
std.debug.print("linking against {s}\n", .{resolved.root});
```

Note the `catch`, not `try`: a build script's `build` function returns `void`,
so an uncaught `try` out of `linkAndroid` is a compile error (*function cannot
return an error*), not a runtime path. `linkAndroid`'s signature is
`fn (*std.Build, *std.Build.Module, *std.Build.Step.Compile, AndroidLinkOptions) !ResolvedNdk`,
and `ResolvedNdk` has exactly two fields, `root` and `libc_file`.

The dependency takes no options: the module it publishes pins no target and no
optimisation mode, because a consumer supplies both for its own code.
`ndk_dep.builder` is the *zig-ndk package's* `*std.Build`, not yours: the
paths-file helper step it creates belongs to that package's graph, which is why
you hand it that rather than the `b` already in scope.

In your own Zig code, the facts half — `Abi`, `HostTag`, `Ndk`, `Error`, and
`LibcPaths` for when you render the paths file yourself:

```zig
const ndk = @import("ndk");

pub fn main() void {
    inline for (std.enums.values(ndk.Abi)) |abi| {
        std.debug.print("{s} {s} {d}\n", .{
            abi.directoryName(),
            abi.triple(),
            abi.minApiLevel(),
        });
    }

    // The inverse mapping, so a name from a `-Dabi=` or an `ANDROID_ABI`
    // becomes an `Abi` without the caller carrying its own five-entry table.
    if (ndk.Abi.fromDirectoryName("arm64-v8a")) |abi| {
        std.debug.print("{s} is {s}\n", .{ abi.directoryName(), abi.triple() });
    }
}
```

### What `linkAndroid` does, and what it refuses to do

It runs discovery, writes the six-field libc paths file into the build cache,
and sets `compile.root_module.link_libc` so the build runner emits `-lc`. It
returns the generated paths file and the root it was computed from, so you can
name the installation in your own diagnostics.

**Read that last sentence as a mechanism, not as a claim that the link
happens.** `link_libc = true` selects the libc *installation* — the paths file
Zig reads for headers and CRT objects. It does not put `libc.so` on the link
line; that needs `compile.linkSystemLibrary("c")`, which `linkAndroid` does not
call today. A dynamic link with lld and no shared library at all does not fail,
it produces no binary — which is exactly what `zig build ndk-link-check` does
now. A consumer who calls `linkAndroid` and wants a real bionic binary must
add the `libc` system library themselves until this package does it:

```zig
exe.linkSystemLibrary("c");
```

Three things it deliberately does not do:

- **Call it twice for one compilation.** The second call builds a second
  paths-file helper against the same module, and Zig 0.16 reports duplicate
  module instances: `file exists in modules 'x' and 'x0'`.
- **Pass `--sysroot`.** `b.sysroot` is a field on the whole `Build`, so setting
  it would leak this NDK into every other compilation in your build. The
  sysroot is fully expressed by the paths file, whose `crt_dir` the ELF linker
  turns into `-L` on its own.
- **Set `linkage`.** `exe.linkage = .dynamic` is yours. It is what emits
  `-dynamic`, and bionic supplies `/system/bin/linker64` as the interpreter
  through `crtbegin_dynamic.o`.

Inside this package, the gates are driven by `-Dabi=`, `-Dapi=` and `-Dndk=` —
see *Build options*. **A consumer's build has no such options**: `-Dndk`,
`-Dabi` and `-Dapi` are registered by *this* package's `build.zig`, so a
consumer's `zig build -Dndk=…` fails with *invalid option: -Dndk*. A consumer
points at an NDK by exporting one of the three environment variables, or by
passing `.ndk` to `linkAndroid`:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk-r29 zig build -Dtarget=aarch64-linux-android
```

The work behind `linkAndroid` is mechanical, and it is worth stating plainly
because it is the whole product: for ABI `arm64-v8a` at API level 35 it
resolves `<ndk>/toolchains/llvm/prebuilt/<host-tag>/sysroot`, renders a libc
paths file whose `include_dir` and `sys_include_dir` are both
`<sysroot>/usr/include` and whose `crt_dir` is
`<sysroot>/usr/lib/aarch64-linux-android/35`, and hands that to Zig. That
directory holds the five CRT objects and the API-level shared libraries;
`libc.a` and `libc++_shared.so` are one level up, in the triple directory beside
the API-level directories, so `crt_dir` cannot serve a static or
`libc++_shared` link. That is why the gate is dynamic.

### Discovery order

First hit wins, and the order is the same in both halves: `-Dndk=<path>` when
`b.option` returned one, then the environment variables in the order below.
`build.zig`'s `ndk_env_vars` array and `Ndk.find`'s candidate array are the two
copies, and they hold the same three names in the same order:

1. `-Dndk=<path>` — the build option. Explicit beats implicit, always.
2. `$ANDROID_NDK_HOME`
3. `$ANDROID_NDK_ROOT`
4. `$ANDROID_NDK`

`ANDROID_NDK_HOME` is first among the variables, and the reason is recorded
rather than incidental: Google's own CMake toolchain prefers it, so it is the
one a user who set it deliberately is most likely to have set. CONTRACT.md D3
carries the same four entries and the same reason.

This order names two different things, and a caller wants different things from
each. `Ndk.find` returns a bare `error.NdkNotFound`, because it cannot know
which of the four the caller had set — the four are the caller's, one a `-D`
option and three an environment map. What it can tell you is what it probed
under one root: `Ndk.probeCandidates` returns that as a `Probes` value, and
`Ndk.describeProbeFailure` writes it into any writer as prose naming the host
tag and both on-disk layouts in probe order. On the build side, `build.zig`
carries its own `NdkNotFound` message listing all four sources with `(unset)` /
`(empty)` markers, because a build script may print and a returned error may
not.

The known cost, stated rather than discovered later: an `ANDROID_NDK_HOME`
inherited from an unrelated shell silently wins over a local checkout. That is
the price of not failing outright on a bad environment, which is the right
default for a single-shell developer and the wrong one for CI. If you want the
CI behaviour, pass the NDK explicitly — `-Dndk` inside this package, or the
`.ndk` field to `linkAndroid` in a consumer.

## Build options

Three of this package's own, plus the two standard options every Zig build
script has. All five are registered by **this** package's `build.zig`; none of
them exists in a consumer's build, and passing one there fails with *invalid
option*.

| Option | Type | Default | What it does | What happens when it is wrong |
|---|---|---|---|---|
| `-Dndk=<path>` | `[]const u8` | unset | The NDK root to read, bypassing discovery entirely. | If the path is not an unpacked NDK, the paths-file helper logs `'<path>' does not resolve to an unpacked Android NDK: NotAnNdk` and the gate fails. A zip fails the same way — unpack it first. If *no* source is set at all, `ndk-link-check` depends on a failing step carrying the ordered list of the four it tried. |
| `-Dabi=<name>` | `[]const u8` | unset → `arm64-v8a` | The ABI the link gate builds for. One of `armeabi-v7a`, `arm64-v8a`, `riscv64`, `x86`, `x86_64` — these are the keys r29's `meta/abis.json` uses and the values `ANDROID_ABI` takes, **not** directory names. Directories under `sysroot/usr/lib` are named by *triple*: `arm-linux-androideabi`, `aarch64-linux-android`, `riscv64-linux-android`, `i686-linux-android`, `x86_64-linux-android`. There is no `arm64-v8a` directory anywhere in the sysroot. | `ndk-link-check` refuses at configure time with a failing step naming the five; `linkAndroid` returns `UnsupportedAbi`. Neither falls back to the default, because a misspelled ABI that silently fell back would build the wrong architecture and say nothing about it. |
| `-Dapi=<level>` | `u32` | unset → 35 | The Android API level the link gate builds for. | The helper logs `no usr/lib/<triple>/<level> in this sysroot: ApiLevelUnavailable`. For `riscv64` this option is **not optional in practice**: see below. |
| `-Dtarget=<triple>` | standard | host | The target this package's own test binaries are compiled for. Under a non-native `-Dtarget` they are compiled but not run, because this host cannot execute them. | An unknown triple fails in Zig's own standard-option parsing, before any of this package's code runs. |
| `-Doptimize=<mode>` | standard | `Debug` | Optimisation mode for this package's own test binaries, and for the generated paths-file helper, which always runs on the build host. | Nothing. It does not affect what any published declaration promises. |

**`riscv64` and the API level.** Zig resolves a bare
`-target riscv64-linux-android` to Android API level **29**
(`lib/std/Target.zig` :484, `.android = 29`), and r29 ships no
`usr/lib/riscv64-linux-android/29` — the floor for that ABI is 35. So a
`riscv64` consumer must pass the level explicitly, as `.api_level` or as
`riscv64-linux-android.35` in the target triple. The other four ABIs ship 29
and need nothing. `root.zig` pins this at comptime as `above_default != 1`: a
second ABI above Zig's default floor fails the build there rather than later as
a directory that is not there.

## Ownership

An `Ndk` is a **borrowed view of a directory tree**. It owns no memory. Every
path it hands back is either a slice you supplied or a slice whose lifetime is
the build run.

There is no `deinit`. That absence is the contract, not an omission: a type
that cannot be freed cannot be believed to own anything, so a caller who needs
a path after the run has to copy it into storage it owns. Verified against
`src/ndk.zig`: the struct declares `root_path`, `host_tag`, `sysroot_path` and
`shape`, and no `deinit`.

Three things in this package are **not** borrowed, and the asymmetry is
deliberate:

- **`Ndk.libcDirFor` and `Ndk.apiLevelsFor`** return a slice the caller frees
  with the allocator it passed in. They are paths the function built.
- **`Ndk.probeCandidates`** returns a `Probes`, which owns every path in it and
  is released with `Probes.deinit(gpa)`. It exists to be freed on a failure
  branch, and an `Ndk` is only ever constructed on success — which is why one
  can afford to own nothing and the other cannot. `Ndk.describeProbeFailure`
  builds one internally and frees it before returning.
- **`LibcPaths`**, re-exported from `root.zig`, owns its three paths.
  `forAndroid` copies what you hand it and `deinit(gpa)` releases the copies,
  so a `LibcPaths` outlives the strings it was built from. `Ndk.Version` is a
  value type: it owns nothing and has no `deinit`.

## What the tests do, and what they do not

**41 tests, 28 of them under one `b.addTest` root and 13 under a second.**
`b.addTest` over `root.zig` compiles every `test` block reachable from that
root, which is `src/ndk.zig` (24) and `src/libc_file.zig` (4) — both are
re-exported by `root.zig`, so a `test` block added to either is picked up
without a second file to keep in sync. A second `b.addTest` over
`test/integration_test.zig` adds 13, and `build.zig` wires it only while that
file is present; its absence is a `std.log.warn`, never a silent pass. All of
them run on the host and none touches a real NDK — every tree they assert
against is constructed under a scratch directory.

Covered, for the libc paths file: that `forAndroid` copies its paths rather than
borrowing the caller's literals; that `render` writes all six keys, with the
three Android-irrelevant ones present and empty; that the output is
byte-for-byte the layout `std.zig.LibCInstallation.render` itself writes; and
that `std.zig.LibCInstallation.parse` — the parser that will actually read the
file — accepts the rendered text for a real `aarch64-linux-android` target, so
the round trip is checked against Zig's parser rather than against a second
copy of the expectation. The integration suite repeats that round trip from a
resolved synthetic sysroot, which is the load-bearing test in the package.

Covered, for the descriptor: that each `Abi` tag maps to its `meta/abis.json`
key, sysroot triple and `min_os_version`; that `Abi.fromDirectoryName` is the
exact inverse and answers `null` for the Zig-tag spellings (`arm64_v8a`) and for
case variants; that only 32-bit ARM is `.androideabi` and every other ABI is
`.android`; that the three `HostTag`s all end in `_x86_64` and that a host Google
publishes no NDK package for — `aarch64-linux` included — is refused as
`UnsupportedHost` rather than as a missing directory, while `aarch64-macos`
still resolves to `darwin_x86_64`; that both on-disk layouts resolve, Google's
direct `toolchains/llvm/prebuilt/…` and nixpkgs' one-level-down `ndk-bundle`,
and that a direct root wins over a nested one; that `source.properties` parses,
tolerates odd spacing, and refuses junk; that discovery takes the build option
first and then the variables in the order above; that `apiLevelsFor` returns
only numeric directories in ascending order and skips a plain file named like a
level; and that `libcDirFor` finds each one and refuses a level the tree does
not carry. The refusals name what they probed: `probeCandidates` is asserted
against the paths discovery actually walks, and `describeProbeFailure` is
asserted to carry the host tag and both layouts.

Not covered, and stated rather than implied:

- **Nothing was run on a device or an emulator.** No runtime behaviour on
  Android is claimed anywhere in this package. The linked binary in *The
  problem* was never executed — it cannot be, on this host — and everything
  said about it is what `file(1)` reads out of its headers.
- **The bionic link was exercised once, by a manual `zig build-exe`, for
  `aarch64-linux-android` at API 35.** It was not exercised through this
  package's own `build.zig`, and it was not exercised for the other four ABIs or
  their API levels. `ndk-link-check` exists to close exactly that gap and does
  not yet close it — it exits 0 while emitting no ELF. See *Gates*.
- **No test asserts that a binary came out.** There is no gate that reads an
  artefact back, so a `linkAndroid` that silently stopped linking would still
  leave `test`, `check` and `ndk-abi-check` green.
- **Every NDK layout fact here was read from r29.** Not from a specification,
  not from another revision, and not from a device. `tools/sync-ndk.sh` is the
  thing that turns "read once" into "checked on demand".
- **There is no fuzzing harness and no coverage measurement.** And a green
  suite means nothing contradicted the code, not that the code is right for
  inputs nobody imagined.

## Layout

```
root.zig                 the module a dependent imports; re-exports Abi,
                         HostTag, Ndk, Error and LibcPaths, and pins the ABI
                         table with comptime assertions
build.zig                Zig 0.16 build: the public `ndk` module, the gate steps,
                         and the build half (`abi_directory_names`,
                         `AndroidLinkOptions`, `ResolvedNdk`, `linkAndroid`)
build.zig.zon            package manifest; `.name = .zig_ndk`, `.fingerprint`
src/ndk.zig              Abi, HostTag, Ndk, Error: discovery and the sysroot map
src/libc_file.zig        the six-field libc paths file, rendered and parsed back
test/integration_test.zig consumer-shaped tests: the same published module a
                         dependent imports, reached by name and never by a
                         relative path. The second `b.addTest` root in the
                         `test` step, wired only while the file is present
tools/sync-ndk.sh        re-resolve the pinned NDK, verify the hash, diff the table
tools/ndk.sha256         the release identity: release, revision, size, SHA-256
devenv.nix               zig 0.16 plus an NDK, with ANDROID_NDK_HOME pointed at it
.github/workflows/ci.yml fmt, test, cross, link and licence jobs; none of them
                         invokes `zig build check`, and it says so in its header
AGENTS.md                the rules an agent working in this tree reads first
CHANGELOG.md             the pinned-facts ledger: what an NDK bump must revisit
CONTRACT.md              the design contract this package was built against
LICENSE                  MIT
```

`src/libc_file.zig` is reached from `root.zig` as `LibcPaths` — the whole file
is re-exported as that one name, rather than its private `LibcPaths` alias,
because a private container declaration cannot be reached through `@import`.
The type is the same either way.

## Licence

MIT. See `LICENSE`. No upstream code is redistributed: this package ships Zig
only, no C and no NDK headers, and the NDK is read at build time from wherever
the consumer's NDK lives.