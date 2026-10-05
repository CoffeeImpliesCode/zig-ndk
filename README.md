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
| Licence | MIT (`LICENSE`), with `NOTICE.md` for provenance. **No NDK, Google or LLVM artefact is shipped in this package** — no C, no NDK header, no vendored LLVM. One piece of Zig's MIT code *is* reproduced: `src/libc_file.zig`'s 26-line `render` template is byte-for-byte `std.zig.LibCInstallation.render`, because a generated paths file has to be indistinguishable from one Zig writes. See *Licence*. The NDK itself is unfree and under Google's Android SDK Terms, not MIT — you download that yourself. |
| Toolchain | Zig 0.16.0 — tag `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`, on **Codeberg** (`codeberg.org/ziglang/zig`), the only place the 0.16.0 tag exists; `github.com/ziglang/zig` is a moved-to-Codeberg mirror whose tags stop at 0.15.2. **There are two different 0.16.0 binaries here and both print `0.16.0`** — the dev shell's is a nixpkgs source build, CI installs the official prebuilt tarball; see *Two compilers, one version string*. Every `file:line` citation in this repository was verified against 0.16.0 specifically. The only machine-enforced compiler pin is CI's `ZIG_VERSION`; `.minimum_zig_version = "0.16.0"` in `build.zig.zon` is **advisory** — Zig parses and stores it, and no tool acts on it — so it records a floor as intent, not a refusal. |
| NDK pinned | **r29** (`29.0.14206865`), as Google's manifest states it: `Pkg.ReleaseName = r29`, `Pkg.Revision = 29.0.14206865`, archive size 783,549,481 bytes. The layout facts below were read from an unpacked r29 and are re-checkable on demand with `tools/sync-ndk.sh` against any unpacked NDK, which is the durable form of that evidence — a scratch path on one host is not. **r30 is shipped and is the current LTS**, and r29 is the first entry on Google's unsupported-downloads list, so this package is verified against a release a full major behind it. See *Which NDK* for why the bump is expected to be cheap. |
| Tests | Two roots, both wired into one step. The runner's own split is what matters: `run test ndk-tests` reports **35 pass**, `run test ndk-integration-tests` reports **18 pass**, **53** in all. The first root is `b.addTest` over `root.zig`, which reaches 29 test blocks in `src/ndk.zig` and 5 in `src/libc_file.zig`, plus root.zig's own unnamed `test { std.testing.refAllDecls(@This()); }`; the second is a separate `b.addTest` over `test/integration_test.zig` with 18, wired only while that file is present — its absence is a logged warning, never a silent pass. Command: `zig build test`, which **exits 0**. |
| Cross-compiles | `zig build ndk-abi-check` compiles one test binary per ABI and never runs it. **Exits 0** on this host. |
| Real bionic link | **All five ABIs, observed at API 35.** Each cell was run and each artefact verified against its own row — `armeabi-v7a` (ELF32, `e_machine` ARM 40, `PT_INTERP /system/bin/linker`), `arm64-v8a` (ELF64, AARCH64 183, `/system/bin/linker64`), `riscv64` (ELF64, RISCV 243, `/system/bin/linker64`), `x86` (ELF32, 386, `/system/bin/linker`), `x86_64` (ELF64, X86_64 62, `/system/bin/linker64`) — each with `DT_NEEDED` naming exactly `libc.so`. The gate writes `zig-out/bin/ndk-link-check-<abi>-api<level>`, so a matrix run leaves every cell it checked in `zig-out/bin` instead of five runs overwriting one name, and a generated `ndk-elf-check` reads that exact file back. It checks `EI_CLASS`, `e_machine`, `PT_INTERP` and `DT_NEEDED`; `e_machine` alone does **not** separate a host artefact from an Android one on x86_64, which is why the other three are checked. See *Gates*. |
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

### Two compilers, one version string

Both of these print `zig version` → `0.16.0`, and they are not the same file:

| | dev shell (`devenv.nix`) | CI (`.github/workflows/ci.yml`) |
|---|---|---|
| what it is | nixpkgs **source build** of 0.16.0 | official **prebuilt** tarball, `zig-x86_64-linux-0.16.0.tar.xz` |
| link | dynamically linked against nixpkgs glibc | statically linked, stripped |
| size | 219,889,568 B | 172,641,672 B |
| sha256 | `e33e6621814dfa5649acbe002b7d25dc2d3f429c505dc94cacced4944d0f6fb5` | `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |
| `zig version` | `0.16.0` | `0.16.0` |

**No gate disagrees.** `zig build all` was run under both binaries and reports
26/26 steps and 53/53 tests either way; `zig build check` with every
`ANDROID_NDK_*` unset is 12/12 and 53/53 under the shell's compiler, which is
the claim that matters for a consumer with no NDK. The gates this package
reports are therefore verified against both toolchains and hold under both.

The consequence is worth stating plainly: **a green run locally does not by
itself prove anything about CI's specific binary.** What it proves is that the
tree is consistent under a 0.16.0 source build. CI is the only place the
official prebuilt is exercised, which is why its `ZIG_VERSION` is the one
machine-enforced pin in this repository and `.minimum_zig_version` is not.

Both files are repository-only, so neither is in a fetched consumer package —
this section is about contributing, and about knowing which compiler your `zig`
is when a result surprises you.

### Other Zig packages that touch Android

Two exist upstream and neither does what this one does. Both were checked
against their own repositories and Google's release manifest rather than
against a search result:

- **`silbinarywolf/zig-android-sdk`** "allows you to setup and build an APK for
  your Android devices" — SDK and NDK acquisition, plus APK packaging. It
  registers its module as **`android`** (`b.addModule("android", …)`), not `ndk`,
  so the two packages do not collide by name at all. Its README's example pins
  `ndk_version = "29.0.13113456"`, which **is** a published revision: it is
  Google's `r29-beta1` preview (`<preview>1</preview>`, archive
  `android-ndk-r29-beta1-linux.zip`), superseded by `29.0.14206865`. Worth
  knowing if you follow its example and wonder why your revision differs.
- **`ikskuh/ZigAndroidTemplate`** is described by its own repository as "an
  example on how to create a minimal Android app in Zig" — project scaffolding.
  Its last push was 2023-12-18, before this package's NDK pin existed.

This package is the sysroot descriptor and the six-field paths file, and
nothing else: no SDK acquisition, no APK packaging, no project template. It is
not a competitor to either of those; it is the layer underneath them.

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
| libc link | `zig build ndk-link-check` | Zig links a bionic Android binary against the real sysroot, **and** the installed artefact — named for the ABI and API it was built for, `zig-out/bin/ndk-link-check-arm64-v8a-api35` by default — is read back and checked on `EI_CLASS`, `e_machine`, `PT_INTERP` and `DT_NEEDED` | **yes** | **exits 0 for all five ABIs at API 35**, each writing its own `zig-out/bin/ndk-link-check-<abi>-api35` |
| NDK drift | `zig build sync-ndk` | the release, revision, archive size, both digests and the copied ABI table still describe the NDK on disk | **yes** | **passes: `sync-ndk: pin holds`**, exit 0 — see below |
| local aggregate | `zig build check` | `test` + `ndk-abi-check`, in one run. **NDK-free by design** | no | **exits 0** |
| everything | `zig build all` | `check` + `fmt-check` + `ndk-link-check` + `sync-ndk` | **yes** | **26/26 steps, 53/53 tests** |

**CI runs five of these gates across five jobs, and never `zig build check`.**
The repository's `.github/workflows/ci.yml` — which does not ship, so this is
about the project rather than your copy — has `fmt` (`zig build fmt-check`),
`test` (`zig build test`), `cross` (`zig build ndk-abi-check`), `link` and
`licence`.
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

**What the link gate covers, and how it proves it.** All five ABIs have been
observed linking, each at API 35, and each artefact was checked against its own
`abi_gates` row: `EI_CLASS` 1 for `armeabi-v7a` and `x86` and 2 for the rest,
`e_machine` ARM 40 / AARCH64 183 / RISCV 243 / 386 / X86_64 62, `PT_INTERP`
`/system/bin/linker` for the two 32-bit ABIs and `/system/bin/linker64` for the
three 64-bit ones, and `DT_NEEDED` naming exactly `libc.so` in all five.

**`e_machine` does not do all of that work, and the x86_64 case is why.** A
glibc host PIE and a bionic Android x86_64 binary agree on `e_machine` 62,
`EI_CLASS` 2, `EI_DATA` 1 and `ELFOSABI_NONE` — so a header-only check was
blind on exactly the ABI the CI host runs. `PT_INTERP` settles it (glibc's is
under the glibc store path, never `/system/bin/`) and so does `DT_NEEDED`
(`libc.so.6` against `libc.so`). Either alone rejects a host artefact; both are
checked because the gate exists to be hard to fool.

**The API floor is a real limit and is now refused rather than discovered.**
Bionic gained `preadv64` and `pwritev64` at API 24, and Zig's default panic
handler reaches both, so a `Debug` or `ReleaseSafe` build below 24 cannot link
at any ABI. `-Doptimize=ReleaseFast` or `ReleaseSmall` links from 24 down, and
`riscv64` is refused below **its own** floor of 35 in every mode, because r29
ships no `usr/lib/riscv64-linux-android/21` to link against — the refusal names
35 rather than a remedy that cannot work there.

**One cell does not reproduce the quoted `file(1)` line.** `x86_64` in `Debug`
loses the `.note.android.ident` note, so `file -b` does not report "built by NDK
r29 (14206865)" for that artefact alone; the other four ABIs and the other three
optimisation modes keep it. The binary is a correct bionic Android PIE, and the
gate never relied on that note — it verifies `EI_CLASS`, `e_machine`, `PT_INTERP`
and `DT_NEEDED`, none of which read it. Compare artefacts on those four, not on
the note.

## Getting started

### The package

**This repository is private, and there is no published URL or package hash.**
The remote is `https://github.com/CoffeeImpliesCode/zig-ndk.git`; as of writing
GitHub returns 404 for it unauthenticated while the owner account is public, and
`zig fetch` on any archive URL for it returns `404 Not Found`. So there is no
multihash for you to copy, and a stanza with `.url = …` / `.hash = …` would be a
fiction. You need access to the repository to get this at all.

With access, clone it and depend on the clone:

```sh
gh repo clone CoffeeImpliesCode/zig-ndk          # with gh authenticated
git clone https://github.com/CoffeeImpliesCode/zig-ndk.git   # with credentials
```

Then point the dependency at that directory — the key is `zig_ndk`, underscore,
matching `b.dependency("zig_ndk", …)` and `@import("zig_ndk")`:

```zon
.dependencies = .{
    .zig_ndk = .{ .path = "path/to/zig-ndk" },
},
```

**A mistyped `.path` fails silently, and you need to know that.** Zig resolves
a path dependency on *first use*, not while parsing the manifest. A build that
never calls `b.dependency("zig_ndk", …)` therefore goes green with a `.path`
that does not exist — `zig build` alone validates nothing. The failure appears
later, and only when the dependency is actually used:

```text
unable to open '<your-project>/path/to/zig-ndk': FileNotFound
```

So if you add the stanza and `zig build` is green, that proves nothing about the
path. Add the `b.dependency` line, then build. This is the same failure class
this package exists to eliminate — a step that reports success because nothing
checked — and Zig's deferral is what puts it there.

When the repository is published, the stanza becomes:

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

**In a clone of this repository, `devenv shell` does this for you** — it fetches
the archive by pinned hash, unpacks it, and points `ANDROID_NDK_HOME` at the
result. `devenv.nix` is not in the shipped package, so if you fetched zig-ndk as
a dependency you fetch the NDK yourself from the URL above. Do this only after
reading *Licence*: downloading and unpacking the NDK is an act under Google's
Android SDK Terms, and the NDK is not MIT and not free as nixpkgs classifies it.

**What that costs before you decide.** With a warm Nix store, evaluating the dev
shell itself is about 5 seconds. The NDK is the expensive part: 783,549,481 bytes
downloaded, unpacking to roughly 2.4 GiB in the store. On a store that has never
seen it, expect **~90 seconds and ~3.2 GB** — about 25 s of download at a
measured 30.8 MB/s plus 58–71 s of unpack. If you are not going to run the link
gate, skip the dev shell and point `ANDROID_NDK_HOME` at an NDK you already have;
`zig build test`, `check`, `ndk-abi-check` and `fmt-check` need no NDK at all.

To prove the toolchain works before writing any consumer code:

```sh
ANDROID_NDK_HOME=<unpacked r29> zig build ndk-link-check
```

Then you also need to **give your compilation an Android target** — see *Use from
Zig*. `linkAndroid` refuses a host-default target at configure time with a
message naming the ABI, its sysroot triple, your actual target and the fix, so
the cause is not left for you to infer from a linker error.

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
`zig build ndk-link-check` writes `zig-out/bin/ndk-link-check-arm64-v8a-api35`, and `file(1)`
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
in this package's `build.zig`: `abi_names`, which sits above `pub fn build`, and
then `AndroidLinkOptions`, `ResolvedNdk` and `linkAndroid` after it. They are
separate on purpose: a consumer who only reads the layout should not pull
`std.Build` into their import table.

`abi_names` holds the five **`meta/abis.json` keys** — `armeabi-v7a`,
`arm64-v8a`, `riscv64`, `x86`, `x86_64` — which are also the values
`ANDROID_ABI` takes. They are **not** path components. Directories under
`sysroot/usr/lib` are spelled with the **sysroot triple**:
`arm-linux-androideabi`, `aarch64-linux-android`, `riscv64-linux-android`,
`i686-linux-android`, `x86_64-linux-android`. There is no `arm64-v8a`
directory anywhere in an NDK, so
`path.join(sysroot, "usr/lib", abi_names[i])` is a path that cannot exist. This
is why `Abi.directoryName` was renamed `Abi.name`: `HostTag.directoryName` is
still correct, because `toolchains/llvm/prebuilt/linux-x86_64` really is that
directory, and one identifier in one package was teaching the other meaning.
Use `Abi.name` for the key and `Abi.triple` for the path.

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

**`.abi` and `-Dtarget` have to agree, and neither defaults from the other.**
The snippet hardcodes `.abi = "arm64-v8a"`, so `-Dtarget=riscv64-linux-android`
on its own is **not** enough — and the configure-time refusal named in *Use from
Zig* stops it, naming both sides. To cross to another ABI, change `.abi` too:

```zig
.abi = "riscv64",     // with -Dtarget=riscv64-linux-android
.api_level = 35,      // riscv64's floor is 35, not 29 — see *Build options*
```

Both pairs were built and run to check this text: `.abi = "arm64-v8a"` with
`-Dtarget=aarch64-linux-android` and `.abi = "riscv64"` with
`-Dtarget=riscv64-linux-android` each produce a real bionic executable, and
mismatching them stops at configure time.

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
- **Set the target.** `exe` must already be the Android target for the ABI you
  asked for, and that is the consumer's job: `b.standardTargetOptions(.{})` with
  `-Dtarget=aarch64-linux-android`, or the equivalent query. Leaving the target
  at its **host default** is the single most likely first-run failure, and
  `linkAndroid` now refuses it at configure time rather than letting it reach the
  linker. It prints the ABI, that ABI's sysroot triple, the compilation's
  actual target, and the fix:

  ```text
  error: `linkAndroid` cannot wire this compilation: the requested ABI
  is arm64-v8a, whose sysroot triple is aarch64-linux-android, and the compilation's
  target is x86_64-linux-gnu.

    A bionic sysroot only satisfies an Android target for that ABI.
    …
    Set the target before wiring the compilation, so the sysroot
    and the target agree:

      zig build -Dtarget=aarch64-linux-android
  ```

  and returns `error.TargetIsNotAndroid` as well, so a build script that only
  propagates the error still fails loudly rather than silently proceeding.

  **Why the check exists** — the "before" it replaces, and what you would see
  without it, is four linker messages that name the wrong thing:

  ```text
  error: failed to open …/usr/lib/aarch64-linux-android/35/crt1.o: FileNotFound
  error: invalid ELF machine type: AARCH64
  ```

  Three `crt1.o`-class errors for CRT files that are present, and an ELF machine
  complaint about a `libc.so` that is exactly right. None of them says "you built
  this for your host", so a reader goes looking for a broken sysroot. Keep that
  symptom in mind: it is what you would see if the mismatch reached the linker,
  and recognising it is how you know the target is wrong rather than the NDK.

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

**53 tests: 35 under one `b.addTest` root, 18 under a second.** The runner's
split is the one to trust — `zig build test --summary all` prints
`run test ndk-tests 35 pass (35 total)` and
`run test ndk-integration-tests 18 pass (18 total)`. Underneath: `b.addTest`
over `root.zig` compiles every `test` block reachable from that root — 29 in
`src/ndk.zig` and 5 in `src/libc_file.zig`, both re-exported by `root.zig`, so a
`test` block added to either is picked up without a second file to keep in
sync — plus root.zig's own unnamed `test { std.testing.refAllDecls(@This()); }`,
which the runner counts like any other. 29 + 5 + 1 is that first root's 35. A
second `b.addTest` over `test/integration_test.zig` adds 18, and `build.zig` wires
it only while that file is present; its absence is a `std.log.warn`, never a
silent pass. 35 + 18 is the 53/53 `zig build all` reports. All of them run on the
host and none touches a real NDK — every tree they assert against is constructed
under a scratch directory.

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
- **The link gate was observed on all five ABIs, at API 35**, each installed
  under its own name and checked against its own row — see *Gates*. What remains
  uncovered is the API level: nothing in the gate reads it, so an artefact
  linked against a different level than `-Dapi=` asked for would pass.
- **`ndk-elf-check` checks four fields, and two of them are past the header.**
  `EI_CLASS` and `e_machine` against the requested ABI, plus `PT_INTERP` naming
  the Android linker and a `DT_NEEDED` naming exactly `libc.so`. That is enough
  to refuse a host executable and a bionic binary for a different ABI, and it is
  more than it looks: the two header fields alone would not refuse a host
  artefact on x86_64. What is *not* checked is anything else — `libm.so`, the
  NDK revision, the API level — which is where `file(1)` earns its keep, and no
  gate runs it.
- **`EI_OSABI` does not separate bionic from glibc on its own.** NDK r29 stamps
  `ELFOSABI_NONE` (0) on every `libc.so` for all five ABIs and every API level —
  verified by reading them — so the checker accepts 0 or 97 and refuses
  everything else, including glibc's GNU value. `EI_CLASS` and `e_machine`
  separate one ABI from another; `PT_INTERP` and `DT_NEEDED` are what separate a
  host artefact from an Android one, and on x86_64 no header field separates
  them at all.
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

This block describes the **repository**, which is a superset of what you get.
`build.zig.zon`'s `.paths` names thirteen individual files and nothing else —
no directory wildcards — so a fetched consumer receives exactly these:

```z
build.zig                Zig 0.16 build: the public `ndk` module, the gate steps,
                         and the build half (`abi_names`, `AndroidLinkOptions`,
                         `ResolvedNdk`, `linkAndroid`)
build.zig.zon            package manifest; `.name = .zig_ndk`, `.fingerprint`
root.zig                 the module a dependent imports; re-exports Abi,
                         HostTag, Ndk, Error and LibcPaths, and pins the ABI
                         table with comptime assertions
src/ndk.zig              Abi, HostTag, Ndk, Error: discovery and the sysroot map
src/libc_file.zig        the six-field libc paths file, rendered and parsed back
test/integration_test.zig consumer-shaped tests: the same published module a
                         dependent imports, reached by name and never by a
                         relative path. The second `b.addTest` root in the
                         `test` step, wired only while the file is present
tools/sync-ndk.sh        re-resolve the pinned NDK, verify the hash, diff the
                         ABI table. Ships, because `zig build sync-ndk` runs it
tools/ndk.sha256         the release identity: release, revision, size, SHA-256
                         and SHA-1. This is where a consumer's NDK facts live
README.md  CHANGELOG.md  CONTRACT.md  LICENSE  NOTICE.md
```

**Repository only — not in the shipped package**, because `.paths` does not
name them. You will not have these in a fetched copy; they are listed so
someone reading the repository knows what is in it:

```z
devenv.nix               zig 0.16 plus an NDK, with ANDROID_NDK_HOME pointed at
                         it. The pinned NDK hash it carries is also in
                         tools/ndk.sha256, which does ship
devenv.lock              freezes the nixpkgs revision the dev shell resolves
.envrc                   loads the dev shell through direnv
.github/workflows/ci.yml the fmt, test, cross, link and licence jobs
AGENTS.md                the rules an agent working in this tree reads first
```

So `devenv shell` is a **repository** convenience: in a fetched consumer
package there is no `devenv.nix` to run. Fetch the NDK yourself using the URL in
*Getting started*, or point `ANDROID_NDK_HOME` at one you already have.

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
which is why this repository's `devenv.nix` fetches the published zip by pinned
hash instead of going through `pkgs.androidndkPkgs_*`. Three things in this
repository download and unpack NDK r29 under those terms: `devenv.nix`, the CI
`link` job, and you. The first two are development-only and do not ship; the
third is you, and `devenv.nix` additionally runs `chmod -R u+w` across the
unpacked tree, so entering that dev shell is itself an event under the terms.
Read them at <https://developer.android.com/studio/terms> before you accept
one. This package does not restate what they permit or forbid — nobody working
on it has read them — and it makes no claim about them beyond the fact that it
downloads them.