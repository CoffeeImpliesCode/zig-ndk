# zig-ndk

Android NDK sysroot facts for Zig 0.16.0, and nothing else.

**This is not a translation of the NDK's build system.** `ndk-build`, the NDK
CMake toolchain file and every Makefile fragment in between are out of scope by
decision, not by omission — reproducing them is a different project with a
different consumer. What this package is instead: a description of where an
unpacked Android NDK keeps its sysroot, the discovery that finds that tree, and
the six-field libc paths file that Zig 0.16.0 demands and cannot derive for
itself. Pure Zig, plus one bash tool and Nix/CI glue. No C, no header, no part
of the NDK redistributed.

## Status

| | |
|---|---|
| Licence | MIT (`LICENSE`), with `NOTICE.md` for provenance. **No NDK, Google or LLVM artefact is shipped in this tree** — no C, no NDK header, no vendored LLVM. One piece of Zig's MIT code *is* reproduced: `src/libc_file.zig`'s 26-line `render` template is byte-for-byte `std.zig.LibCInstallation.render`, because a generated paths file has to be indistinguishable from one Zig writes. See *Licence*. The NDK itself is unfree and under Google's Android SDK Terms, not MIT — `devenv shell` downloads one. |
| Toolchain | Zig 0.16.0 — tag `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`, on **Codeberg** (`codeberg.org/ziglang/zig`), which is the only place the 0.16.0 tag exists; `github.com/ziglang/zig` is a moved-to-Codeberg mirror whose tags stop at 0.15.2. Every `file:line` citation in this repository was verified against 0.16.0 specifically. The only machine-enforced compiler pin is CI's `ZIG_VERSION`, which the setup action resolves to that exact release; `.minimum_zig_version = "0.16.0"` in `build.zig.zon` is **advisory** — Zig parses and stores it, and no tool acts on it — so it records a floor as intent, not a refusal. |
| NDK pinned | **r29** (`29.0.14206865`), as Google's manifest states it: `Pkg.ReleaseName = r29`, `Pkg.Revision = 29.0.14206865`, archive size 783,549,481 bytes. The layout facts below were read from an unpacked r29 and are re-checkable on demand with `tools/sync-ndk.sh` against any unpacked NDK, which is the durable form of that evidence — a scratch path on one host is not. **r30 is shipped and is the current LTS**, and r29 is the first entry on Google's unsupported-downloads list, so this package is verified against a release a full major behind it. See *Which NDK* for why the bump is expected to be cheap. |
| Tests | Two roots, both wired into one step. `b.addTest` over `root.zig` compiles `src/ndk.zig` (24 tests), `src/libc_file.zig` (5) and root.zig's own unnamed `test { std.testing.refAllDecls(@This()); }`, which the runner counts like any other; a second `b.addTest` over `test/integration_test.zig` adds 13 and is wired only while that file is present — its absence is a logged warning, never a silent pass. **43 tests** in all, which is what `zig build all` reports. Command: `zig build test`, which **exits 0**. |
| Cross-compiles | `zig build ndk-abi-check` compiles one test binary per ABI and never runs it. **Exits 0** on this host. |
| Real bionic link | **Observed for two ABIs, both at API 35: `arm64-v8a` and `riscv64`.** `ANDROID_NDK_HOME=<r29> zig build ndk-link-check` exits 0, writes `zig-out/bin/ndk-link-check`, and `file(1)` reads the arm64 one as `ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked, interpreter /system/bin/linker64, for Android 35, built by NDK r29 (14206865)`. The gate installs that artefact and runs a generated `ndk-elf-check` over it, refusing anything that is not an ELF **for the ABI the gate was asked to build**: `EI_CLASS` must match, `EI_DATA` must be `2LSB`, `EI_OSABI` must be `ELFOSABI_NONE` or `ELFOSABI_ANDROID`, and `e_machine` must be the one `-Dabi=` implies. **The other three ABIs have not been observed linking**: `arm64-v8a` at 21, `armeabi-v7a` at 21 and `x86` at 21 all fail on `undefined symbol: preadv64`, and `x86_64` at 21 on `pwritev64` — bionic gained both at API 24 and Zig's default panic handler reaches them, so those legs need `-Dapi=35` or `-Doptimize=ReleaseSmall`. |
| Allocates | In the build path only. `Ndk.find`, `Ndk.open`, `Ndk.probeCandidates`, `Ndk.describeProbeFailure`, `Ndk.readVersion`, `Ndk.libcDirFor` and `Ndk.apiLevelsFor` take a caller-supplied allocator. `libcDirFor` and `apiLevelsFor` hand back a slice the caller frees; `probeCandidates` hands back a `Probes`, which *owns* its paths and is released with `Probes.deinit`. The `Ndk` value itself allocates nothing and frees nothing — see *Ownership*. |
| Runs on Android | **No claim at all.** Nothing in this package was executed on a device or an emulator. |
| NDK revisions covered | **r29 only, and r29 is behind.** r30 (`30.0.16248370`) shipped 2026-09-08 and is the current LTS; r29 is the first entry on Google's unsupported-downloads list. Nothing here was read from, or is claimed for, r30, r27 or r28. See *Which NDK* for what a bump would and would not change. |

| Upstream sync | `tools/sync-ndk.sh`, also a `zig build` step (`zig build sync-ndk`) and wired into CI. **Run green**: it reports the revision matches, the SHA-256 matches, Google's published SHA-1 matches, the tree and the archive agree on r29, `abi table: 5 ABIs in src/ndk.zig match meta/abis.json exactly`, `abi enum: 5 declared tags, 5 mapped tags`, and `sync-ndk: pin holds`, exit 0. It cannot check the libc paths file format or any claim about Zig's behaviour — those are compiler facts, watched only by a compiler bump. |

### Which NDK this package is verified against

r29, and r29 is **behind**: r30 shipped 2026-09-08 and is the current LTS, and
r29 is the first entry on Google's unsupported-downloads list. Saying so is the
honest position — nothing here was read from r30 — and it is a defensible one,
because adopting r30 is expected to change very little. From r30's own
changelog:

- **Nothing relocates.** The changes listed are LLVM moving to clang-r574158c,
  simpleperf prebuilts, and "upgraded the max API to 37 for NDK sysroots". No
  directory moves and nothing is re-namespaced, so the `crt_dir` reasoning in
  *CHANGELOG* p0005 is untouched.
- **The ABI set is unchanged.** The same five `meta/abis.json` keys and the same
  five triples.
- **The API-level change is picked up automatically.** `Ndk.apiLevelsFor`
  enumerates the numeric directories on disk rather than carrying a table of
  levels, so a new maximum appears on its own.

The one number r30 does touch is the link gate's default `-Dapi=35`, and 35
still exists in r30 — so the default keeps working. A bump is then mostly
`tools/ndk.sha256` plus the two comptime pins in `root.zig`, which fail the
build if the table moved. This is stated so the decision is the reader's to
make rather than something they have to guess at.

### Other Zig packages that touch Android

Two exist and neither does what this one does, which is worth a paragraph
because one of them collides by name:

- **`silbinarywolf/zig-android-sdk`** resolves the Android SDK and NDK and
  builds APKs — acquisition and packaging. It publishes a module named `ndk`,
  but that module is Android's `log` binding, not a sysroot descriptor, so the
  shared name is a collision and not an overlap. Its README pins
  `ndk_version = "29.0.13113456"`, a revision Google does not publish; the real
  r29 is `29.0.14206865`.
- **`ikskuh/ZigAndroidTemplate`** is project scaffolding, and its last activity
  predates this package's NDK pin.

This package is the sysroot descriptor and the six-field paths file, and
nothing else: no SDK acquisition, no APK packaging, no project template.

### Gates

Every row names a step that is registered literally in `build.zig` as
`b.step(...)`, and every row carries its **observed** status. "Not established"
means the command was not run to a state that proves what the row claims — not
that it was run and failed.

| Gate | Command | What a green run establishes | Needs an NDK? | Observed |
|---|---|---|---|---|
| fmt | `zig build fmt-check` | formatting | no | **2/2 steps pass** |
| host tests | `zig build test` | libc paths file parsing and rendering, discovery order, error paths, on the host target | no | **exits 0** |
| cross compile | `zig build ndk-abi-check` | each ABI's `std.Build` target query resolves and the module compiles for it | no | **exits 0** |
| libc link | `zig build ndk-link-check` | Zig links a bionic Android binary against the real sysroot, **and** the installed artefact is read back and confirmed to be an ELF for the requested ABI | **yes** | **exits 0 and writes `zig-out/bin/ndk-link-check`**, an Android PIE with interpreter `/system/bin/linker64`, for `arm64-v8a` and for `riscv64`, both at API 35 |
| NDK drift | `zig build sync-ndk` | the release, revision, archive size, both digests and the copied ABI table still describe the NDK on disk | **yes** | **passes: `sync-ndk: pin holds`**, exit 0 — see below |
| local aggregate | `zig build check` | `test` + `ndk-abi-check`, in one run. **NDK-free by design** | no | **exits 0** |
| everything | `zig build all` | `check` + `fmt-check` + `ndk-link-check` + `sync-ndk` | **yes** | **26/26 steps, 43/43 tests** |

**CI runs five of these gates across five jobs, and never `zig build check`.**
`.github/workflows/ci.yml` has `fmt` (`zig build fmt-check`), `test`
(`zig build test`), `cross` (`zig build ndk-abi-check`), `link` and `licence`.
The `link` job provisions the NDK and then runs **two** gates: `zig build
sync-ndk` first, then `zig build ndk-link-check`. The `test` and `cross` jobs
together run exactly the two steps `zig build check` depends on, so those two
jobs equal the local aggregate — but CI splits them across two jobs and two
caches, and runs **three** gates `check` does not: `fmt-check`, `sync-ndk` and
`ndk-link-check`. So the pinned release, revision, size, both digests and the
copied ABI table *are* checked, in `sync-ndk`, and an NDK bump fails the job
before any link is attempted. `sync-ndk` is in `all` and deliberately not in
`check`, which has to stay runnable with no NDK present.

**What `sync-ndk` observed.** It passes on this host, reporting that the
revision matches, the SHA-256 matches, Google's published SHA-1 matches, the
tree and the archive agree on r29, `abi table: 5 ABIs in src/ndk.zig match
meta/abis.json exactly`, `abi enum: 5 declared tags, 5 mapped tags`, and
`sync-ndk: pin holds`. What it does **not** check is the libc paths file format
or any of this package's claims about Zig's behaviour — those are compiler
facts, watched only by a compiler bump (`CHANGELOG.md` p0004). Its run step
carries `has_side_effects = true`, so a cached second build does not skip it.

**What the link gate covers, and what it does not.** Two ABIs have been
observed linking, both at API 35: `arm64-v8a` and `riscv64`. `-Dabi=<name>` and
`-Dapi=<n>` select the rest. The three API-21 legs — `armeabi-v7a`, `x86` and
`x86_64` — have **not** been observed linking, and do not link at API 21 as the
package is configured: `armeabi-v7a`, `x86` and `arm64-v8a` fail on
`undefined symbol: preadv64`, `x86_64` on `pwritev64`. Bionic gained both at
API 24 and Zig's default panic handler reaches them, so those legs want
`-Dapi=35` or `-Doptimize=ReleaseSmall`. Until each is run, "this ABI is
covered" is a claim no run supports — while "the mechanism works against a real
r29 sysroot" is established, by the manual probe in *The problem* and by this
gate.

## Getting started

### The package

**There is no URL to fetch this from yet, and no published hash.** Its remote is
`https://github.com/CoffeeImpliesCode/zig-ndk.git`, and as of writing that
repository is not reachable unauthenticated: `zig fetch` on its archive URL
returns `404 Not Found`, and GitHub's own API returns 404 for it while the owner
account is public. There is therefore no multihash for you to copy, and a stanza
with `.url = …` / `.hash = …` would be a fiction. What works today is a local
path dependency, and this is the whole stanza:

```zon
.dependencies = .{
    .zig_ndk = .{ .path = "../zig-ndk" },
},
```

with `.zig_ndk` as the key — underscore, matching `b.dependency("zig_ndk", …)`
and `@import("zig_ndk")`. When the repository is published the stanza becomes:

```zon
.dependencies = .{
    .zig_ndk = .{
        .url = "<the published archive URL>",
        .hash = "zig_ndk-0.1.0-<multihash>",
    },
},
```

and the hash is whatever

```sh
zig fetch <the published archive URL>
```

prints — it is the first line of that command's output and must not be invented.
`.paths` in `build.zig.zon` already lists every file a consumer needs, so the
archive carries the package whole.

### The NDK

The toolchain is a separate download, and it is the heavy one: **783,549,481
bytes** (~783 MB), from

```sh
https://dl.google.com/android/repository/android-ndk-r29-linux.zip
```

with SHA-256 `4abbbcdc842f3d4879206e9695d52709603e52dd68d3c1fff04b3b5e7a308ecf`
and Google's own published SHA-1 `87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b`.
Those five values are pinned in `tools/ndk.sha256` and re-checked by
`zig build sync-ndk`.

**`devenv shell` does this for you** — it fetches the archive by pinned hash,
unpacks it, and points `ANDROID_NDK_HOME` at the result. Do this only after
reading *Licence*: downloading and unpacking the NDK is an act under Google's
Android SDK Terms, and the NDK is not MIT and not free as nixpkgs classifies it.

To prove the toolchain works before writing any consumer code:

```sh
ANDROID_NDK_HOME=<unpacked r29> zig build ndk-link-check
```

Then you also need to **give your compilation an Android target**. See *Use from
Zig*; leaving the target at the host default produces a `crt1.o: FileNotFound`
that does not name its cause.

## The problem

Zig 0.16.0 ships zero NDK awareness. A case-insensitive search for `ndk` across
`lib/std` returns only incidental matches: ML-KEM's `Ndk` decap-key fields in
`crypto/hybrid_kem.zig`, `BlindKeyPair` and `expandKey` in
`crypto/25519/ed25519.zig` and `crypto/aes/soft.zig`, a ReactOS NDIS header URL
at `os/windows.zig:5843`, and `FoundKey` at `zig/LibCInstallation.zig:45` —
that last only because the word contains the substring. Not one is about
Android. The libc++ header this project is really up against lives outside
`lib/std`, under `lib/libcxx/`; `lib/std` has no `libcxx` directory for a grep
to return. `lib/std/Build.zig` contains no android reference at all.

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

**That binary came from the manual `zig build-exe` probe above**, so it
evidences the *mechanism* — that Zig links bionic when handed this paths file
and this sysroot — rather than this package's wiring. The package's own gate
now produces the same artefact through `build.zig`:
`zig build ndk-link-check` writes `zig-out/bin/ndk-link-check`, and `file(1)`
reads the same ELF type, interpreter, API level and NDK revision off it. See
*Gates*.

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
in this package's `build.zig`: `abi_directory_names`, which sits above
`pub fn build`, and then `AndroidLinkOptions`, `ResolvedNdk` and `linkAndroid`
after it. They are separate on purpose: a consumer who only reads the layout
should not pull `std.Build` into their import table.

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
    //
    // `std.debug.panic`, not `@panic` with a concatenated slice: `++` on a
    // runtime `[]const u8` is not comptime-known and will not compile.
    std.debug.panic("zig-ndk: {t}", .{err});
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
const std = @import("std");
const ndk = @import("ndk");

pub fn main() void {
    inline for (std.enums.values(ndk.Abi)) |abi| {
        std.debug.print("{s} {s} {d}\n", .{
            abi.name(),
            abi.triple(),
            abi.minApiLevel(),
        });
    }

    // The inverse mapping, so a name from a `-Dabi=` or an `ANDROID_ABI`
    // becomes an `Abi` without the caller carrying its own five-entry table.
    if (ndk.Abi.fromName("arm64-v8a")) |abi| {
        std.debug.print("{s} is {s}\n", .{ abi.name(), abi.triple() });
    }
}
```

### What `linkAndroid` does, and what it refuses to do

It runs discovery, writes the six-field libc paths file into the build cache,
and sets `compile.root_module.link_libc` so the build runner emits `-lc`. It
returns the generated paths file and the root it was computed from, so you can
name the installation in your own diagnostics.

**It wires a compilation; it does not produce a binary, and that is not a libc
problem.** A `Step.Compile` nobody consumes emits nothing: the build runner
passes `-fno-emit-bin` while `generated_bin` is null
(`lib/std/Build/Step/Compile.zig:1406`), so the compile step succeeds having
written no file anywhere. Something has to allocate that field — a
`b.addInstallArtifact`, a `b.addRunArtifact`, or a caller that consumes the
artefact. A consumer who wants the binary needs one of those:

```zig
const installed = b.addInstallArtifact(exe, .{});
```

Nothing is missing from the *link* side, and adding a `c` system library would
be a no-op: `Module.linkSystemLibrary("c", …)` never reaches the library list,
because the name is intercepted first and rewritten to `m.link_libc = true`
(`lib/std/Build/Module.zig:371-374`) — which `linkAndroid` already sets, and
`link_libc` is what puts `-lc` on the command line
(`Step/Compile.zig:1355-1356`). This is the failure the whole package exists to
prevent: a green build step that proves nothing, because nothing read back what
it produced.

Four things it deliberately does not do:

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
- **Set the target.** `exe` must already be an Android target, and that is the
  consumer's job: `b.standardTargetOptions(.{})` with `-Dtarget=aarch64-linux-android`,
  or the equivalent query. Leaving the target at its **host default** is the
  single most likely first-run failure, and the message does not name its cause:
  the compile is an x86-64 Linux binary pointed at an aarch64 Android sysroot, so
  it fails with

  ```text
  error: failed to open …/usr/lib/aarch64-linux-android/35/crt1.o: FileNotFound
  error: invalid ELF machine type: AARCH64
  ```

  Neither line says "you built this for your host". A reader who has never seen
  it will go looking for a broken sysroot. Check the `-Dtarget=` on your build
  command first.

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

An `Ndk` is a **borrowed view of a directory tree**. It owns no memory and has
no `deinit`, and that absence is the contract rather than an omission: a type
that cannot be freed cannot be believed to own anything, so a caller who needs
a path after the build run has to copy it into storage it owns.

**Every slice an `Ndk` stores was allocated from the allocator you passed to
`find` or `open`** — `root_path`, `sysroot_path` and the `Probes` paths alike.
Nothing it holds aliases your input buffer, and nothing it holds is a
build-runner slice it happened to be handed; in a build script that allocator
is the build runner's, whose lifetime is the build. Verified against
`src/ndk.zig`: `Ndk` declares `root_path`, `host_tag`, `sysroot_path` and
`shape`, no `deinit`, and `resolve` allocates every path it stores.

Three things in this package are **not** borrowed, and the asymmetry is
deliberate:

- **`Ndk.libcDirFor` and `Ndk.apiLevelsFor`** return a slice the caller frees
  with the allocator it passed in. They are paths the function built.
- **`Ndk.probeCandidates`** returns a `Probes`, which owns every path in it and
  is released with `Probes.deinit(gpa)`. It exists to be freed on a failure
  branch, and an `Ndk` is only ever constructed on success — which is why one
  can afford to own nothing and the other cannot. `Ndk.describeProbeFailure`
  builds one internally and frees it before returning.
- **`LibcPaths`**, re-exported from `root.zig`, owns three of its six fields.
  `forAndroid` copies `include_dir`, `sys_include_dir` and `crt_dir`, and
  `deinit(gpa)` releases exactly those three, so a `LibcPaths` outlives the
  strings it was built from. `Ndk.Version` is a value type: it owns nothing and
  has no `deinit`.

**The trap is the three fields `LibcPaths.deinit` deliberately does not touch.**
`msvc_lib_dir`, `kernel32_lib_dir` and `gcc_dir` are **borrowed**: `forAndroid`
leaves them `null`, a caller that sets one sets it to memory it owns, and
`deinit` never frees them. That is not an oversight. All three are `null` for
every Android target, so `forAndroid` never takes them, and freeing a borrowed
slice would abort on the string literal a caller naturally writes into
`.gcc_dir = "/some/path"` on a Haiku build.

## What the tests do, and what they do not

**43 tests: 30 under one `b.addTest` root, 13 under a second.** `b.addTest`
over `root.zig` compiles every `test` block reachable from that root — 24 in
`src/ndk.zig`, 5 in `src/libc_file.zig`, both re-exported by `root.zig`, so a
`test` block added to either is picked up without a second file to keep in
sync — plus root.zig's own unnamed `test { std.testing.refAllDecls(@This()); }`,
which the runner counts like any other. A second `b.addTest` over
`test/integration_test.zig` adds 13, and `build.zig` wires it only while that
file is present; its absence is a `std.log.warn`, never a silent pass. 24 + 5 +
1 + 13 is the 43/43 `zig build all` reports. All of them run on the host and
none touches a real NDK — every tree they assert against is constructed under a
scratch directory.

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
key, sysroot triple and `min_os_version`; that `Abi.fromName` is the
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
- **The link gate was observed on two ABIs, both at API 35.** `arm64-v8a` and
  `riscv64` linked, were installed, and passed the header check. `ndk-abi-check`
  *compiles* the other three, which is a different claim from having watched each
  one link. Per-ABI coverage remains open for `armeabi-v7a`, `x86` and
  `x86_64`, and at API 21 for `arm64-v8a` too — see *Gates* for why.
- **`ndk-elf-check` reads the ELF header, not the link.** It confirms
  `EI_CLASS`, `EI_DATA`, `EI_OSABI` and `e_machine` against the requested ABI,
  so a host executable or a bionic binary for a different ABI is refused. It
  does not parse the program headers or the dynamic section: that the artefact
  links `libc.so` and `libm.so`, carries interpreter `/system/bin/linker64`, and
  records the NDK revision is established by reading it with `file(1)`, which
  no gate in this tree does.
- **`EI_OSABI` does not separate bionic from glibc on its own.** NDK r29 stamps
  `ELFOSABI_NONE` (0) on every `libc.so` for all five ABIs and every API level —
  verified by reading them — so the checker accepts 0 or 97 and refuses
  everything else, including glibc's GNU value. `e_machine` is what separates a
  host artefact from an Android one.
- **No test asserts a bionic *symbol* was resolved.** The link gate's generated
  main calls `puts`, so a link that ignored it would fail, but nothing inspects
  the dynamic section for `libc.so` or `libm.so`.
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
devenv.lock              freezes the nixpkgs revision the dev shell resolves
.envrc                   loads the dev shell through direnv
.github/workflows/ci.yml fmt, test, cross, link and licence jobs; none of them
                         invokes `zig build check`, and it says so in its header
AGENTS.md                the rules an agent working in this tree reads first
CHANGELOG.md             the pinned-facts ledger: what an NDK bump must revisit
CONTRACT.md              the design contract this package was built against
LICENSE                  MIT
NOTICE.md                provenance: the one reproduced piece of Zig, and the
                         NDK's licence status
```

`src/libc_file.zig` is reached from `root.zig` as `LibcPaths` — the whole file
is re-exported as that one name, rather than its private `LibcPaths` alias,
because a private container declaration cannot be reached through `@import`.
The type is the same either way.

## Licence

MIT; see `LICENSE`, and `NOTICE.md` for provenance. **The tree ships no NDK,
Google or LLVM artefact** — no C, no NDK header, no vendored LLVM, nothing
783 MB. The NDK is read at build time from wherever the consumer's NDK lives,
and nothing this package produces is redistributed by it.

Upstream code *is* reproduced in one place, and it is worth naming rather than
rounding away: the 26-line template in `src/libc_file.zig`'s `render` is
byte-for-byte `std.zig.LibCInstallation.render`, comment block and all, from
Zig's `lib/std/zig/LibCInstallation.zig`. That is deliberate — a file written
here has to be indistinguishable from one Zig writes itself, and `src/libc_file.zig`
says so at its `render` doc comment — and it is MIT, so it is redistribution
under a compatible licence rather than a defect. It matters because those
comment lines are **written into the generated paths file**: a user who opens
`ndk-libc.txt` in their build cache reads Zig's words with no attribution in the
file. `NOTICE.md` names the Zig contributors, MIT, and the file they came from.
One line of `test/integration_test.zig` is likewise identical to
`LibCInstallation.zig:62`.

**The NDK is not free software and is not MIT.** Google distributes it under the
Android SDK Terms, not an OSI licence, and nixpkgs classifies it as unfree —
which is why `devenv.nix` fetches the published zip by pinned hash instead of
going through `pkgs.androidndkPkgs_*`. `devenv.nix` and the CI `link` job both
download and unpack NDK r29 under those terms, and `devenv.nix` runs `chmod -R
u+w` across the unpacked tree, so entering the dev shell is itself an event
under them. Read them at
<https://developer.android.com/studio/terms> before you accept one. This
package does not restate what they permit or forbid — nobody working on it has
read them — and it makes no claim about them beyond the fact that it downloads
them.