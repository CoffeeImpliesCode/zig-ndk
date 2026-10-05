# zig-ndk — design contract

Status: shape branch. Compiler pinned at **Zig 0.16.0** (tag
`24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`). NDK pinned at **r29**
(`29.0.14206865`), unpacked and read on this host. Every claim below carries a
proof label: **source reading**, **exercised compilation**, or **runtime
observation**.

## 1. The problem, established by execution

Zig 0.16.0 ships **zero** NDK awareness. Grepping `lib/` for `ndk` across the
whole tree finds exactly three real things: `lib/libcxx/include/__locale_dir/locale_base_api/android.h`
(upstream libc++ code, gated on `__has_include(<android/ndk-version.h>)`),
the ML-KEM `Ndk` decapsulation-key length field in `lib/std/crypto/hybrid_kem.zig`,
and a ReactOS NDIS header URL in `lib/std/os/windows.zig:5843`. Inside
`lib/std` there is no NDK support code at all, and `lib/std/Build.zig`
contains no `android` reference whatsoever.

Note the path: that libc++ file is under `lib/libcxx`, not `lib/std/libcxx`,
which does not exist. A grep rooted at `lib/std` cannot return it.

Four probes, run against Zig 0.16.0 on this host, the last of them against the
unpacked NDK r29 sysroot:

| Probe | Result | Label |
|---|---|---|
| `zig build-exe -target aarch64-linux-android` | exit 0, produces an ELF | exercised compilation |
| `zig build-exe -target aarch64-linux-android -lc` | `error: unable to provide libc for target 'aarch64-linux.5.10...6.19-android.29'` | exercised compilation |
| `--libc <sysroot>/usr/lib/aarch64-linux-android/35` | `error: unable to parse libc paths file at path ...: IsDir` | exercised compilation |
| `--libc <generated paths file> -dynamic -lc` | **exit 0** | exercised compilation |

The fourth probe's artefact, read with `file(1)`:

```
ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV),
dynamically linked, interpreter /system/bin/linker64, for Android 35,
built by NDK r29 (14206865), with debug_info, not stripped
```

That line is the whole product in one string: Zig compiled the binary, and
bionic supplied the loader, the CRT and `libc`. `/system/bin/linker64` is the
interpreter the r29 sysroot's `crtbegin_dynamic.o` asks for, and "built by NDK
r29" is recorded by the linker from the sysroot it linked against.

**Consequence.** A freestanding Android binary builds. Anything that needs
bionic — `libc.so`, `libm.so`, the CRT objects, `stdio.h` — does not build from
Zig's own resources, because Zig bundles no bionic (`lib/libc/` holds darwin,
freebsd, glibc, mingw, musl, netbsd, openbsd, wasi and include, and nothing
else). Suppointing it at the sysroot works, but only through a hand-written libc
paths file, and `LibCInstallation.parse` will not accept a directory. That gap
is what this package fills. It is the whole scope. The NDK's own build systems
(`ndk-build`, its CMake toolchain file) are explicitly **out of scope**: they
are translation systems, and translating them is a different project.

## 2. The mechanism

Zig consumes an external libc through a **libc paths file**
(`lib/std/zig/LibCInstallation.zig`, `parse` at :41, `render` at :123). Six
fields, all six mandatory, split on `\n`, `=` separating name from value,
`#` starting a comment:

```
include_dir        # dir containing stdlib.h
sys_include_dir    # dir containing sys/errno.h
crt_dir            # dir containing crt1.o / crtbegin_*.o ; required for non-Darwin
msvc_lib_dir       # Windows only; may be empty
kernel32_lib_dir   # Windows only; may be empty
gcc_dir            # Haiku only; may be empty
```

`parse` rejects the file unless every field is present (`:79-84`), and rejects
it unless `include_dir` and `sys_include_dir` are non-empty (`:85-92`) and,
for every non-Darwin target, `crt_dir` is non-empty (`:95-98`).

For an Android NDK r29 the mapping is mechanical:

| Field | Value |
|---|---|
| `include_dir` | `<ndk>/toolchains/llvm/prebuilt/<host-tag>/sysroot/usr/include` |
| `sys_include_dir` | same directory |
| `crt_dir` | `<sysroot>/usr/lib/<triple>/<api-level>` |
| `msvc_lib_dir`, `kernel32_lib_dir`, `gcc_dir` | empty (present, valueless) |

`<triple>` and the ABI directory names are **not** Zig triples. They come from
the NDK's own `meta/abis.json`, read on this host:

| ABI dir | bitness | triple | min API |
|---|---|---|---|
| `armeabi-v7a` | 32 | `arm-linux-androideabi` | 21 |
| `arm64-v8a` | 64 | `aarch64-linux-android` | 21 |
| `x86` | 32 | `i686-linux-android` | 21 |
| `x86_64` | 64 | `x86_64-linux-android` | 21 |
| `riscv64` | 64 | `riscv64-linux-android` | 35 |

Zig's corresponding ABI tags are `.android` / `.androideabi`
(`lib/std/Target.zig` :775-776). Zig models the Android API level natively:
`std.Target.Query.android_api_level` (`lib/std/Target/Query.zig` :41-43,
parsed at :253-256, emitted into the LLVM triple at :468-473), and
`std.Target` defaults it to 29 (`lib/std/Target.zig` :484).

Zig already knows the Android CRT object names
(`lib/std/zig/LibCInstallation.zig` :737-750: `crtbegin_so.o`,
`crtbegin_dynamic.o`, `crtbegin_static.o` / `crtend_android.o`,
`crtend_so.o`). Those names exist in the r29 sysroot at
`sysroot/usr/lib/<triple>/<api>/`, so pointing `crt_dir` there is sufficient and
no manual object-file wiring is needed.

## 3. Decisions

Every contested decision carries the five-part record. Where Zig's own type
system or safety fixes the choice, the record is replaced by an obligation with
the language fact named.

### D1 — Publish the layout facts, not a hardcoded path table

- **Priority.** A consumer on a different NDK revision, host tag, or API level
  must be able to use this package without editing it.
- **Constraint.** The path map is NDK-owned and moves between revisions; the
  five ABI entries above were read from r29's `meta/abis.json`, not from a
  spec.
- **Cost on consumers.** Discovery touches the filesystem, so a missing or
  relocated NDK surfaces as a build-configuration error rather than at link
  time.
- **Counterchoice.** Hardcode the five ABIs as a comptime table. Genuinely wins
  if the package must configure with zero filesystem access, which is not this
  package's job — it configures a build, and the build already has an IO
  implementation.
- **Grade.** shape · design constraint · documented in README.

### D2 — The published module is the NDK descriptor; the build script is the build-only half

Two routes, because a consumer needs both and they have different audiences.

| Consumer need | Route |
|---|---|
| read ABI names, triples, API levels, sysroot paths from Zig code | registered module `ndk`, root `root.zig` |
| wire `-Dtarget=…-linux-android` into a compilation | `pub const` re-exports at the end of `build.zig` |

This follows the house pattern in `foundation-predicates`, where the C surface
is published as a module and the artefact is linked through it.

- **Counterchoice.** A single module that also does build wiring. Genuinely
  wins when the audience is one in-repo consumer; it loses the moment an
  out-of-tree consumer needs only the facts, because it drags `std.Build` into
  their module's imports — and a module's import table is per-module, not
  transitive, so they would have to add `std.Build`'s dependencies themselves.
- **Grade.** shape · design constraint.

### D3 — Discovery order is explicit and each source is named

`--build-file`-independent order, first hit wins:

1. `-Dndk=<path>` build option (explicit beats implicit, always)
2. `ANDROID_NDK_HOME`
3. `ANDROID_NDK_ROOT`
4. `ANDROID_NDK`

`ANDROID_NDK_HOME` first because Google's own CMake toolchain prefers it and it
is the least surprising to a user who set it deliberately.

- **Cost on consumers.** An inherited `ANDROID_NDK_HOME` from an unrelated shell
  silently wins over a local checkout. Mitigated by the error message naming
  every path tried, in order.
- **Counterchoice.** Fail rather than read the environment. Genuinely wins in
  CI, where an inherited variable is a reproducibility hazard. Not the default:
  it makes the common single-shell case worse.
- **Grade.** shape · design constraint.

### D4 — `b.option` for NDK discovery, not a hand-rolled `-D` flag

The foundation per-fork contract item 4 names `b.systemIntegrationOption` as
the first-class mechanism and calls a hand-rolled `-D` flag a defect. That
option governs *linking a system library by name*; NDK discovery resolves a
directory tree and then synthesises a libc paths file, which is not that shape.
`b.option` is the standard-option mechanism and is used instead.

- **Grade.** shape · house constraint · `docs/01-first-wave.md` §4.3 item 4.

### D5 — No vendored C, no `addTranslateC`

The package ships Zig code that *describes* a sysroot. There is no C source of
ours and no header of ours to translate, so contract item 3
(`b.addTranslateC`) does not apply. The NDK headers are consumed by the
consumer's own code, through the sysroot `include_dir`, which is the
"shipped header plus a link path" route in the surface rules.

- **Grade.** shape · language-fixed (no C artefact exists to translate).

### D6 — `crt_dir` is the API-level directory, not the triple directory

`crt_dir` must be `usr/lib/<triple>/<api>` because the five CRT objects live
only there. Verified by listing the r29 tree: `usr/lib/aarch64-linux-android/35/`
holds `crtbegin_dynamic.o`, `crtbegin_so.o`, `crtbegin_static.o`,
`crtend_android.o`, `crtend_so.o` and `crt_pad_segment.o`, alongside the
API-level shared libraries `libc.so`, `libm.so` and the `libc++.so` / `libc++.a`
linker scripts.

The API-agnostic archives are NOT there. `libc.a`, `libc++_shared.so`,
`libc++_static.a`, `libc++abi.a`, `libm.a`, `libdl.a` and `libz.a` are siblings
of the numeric API directories, one level up in the triple directory. This is
the load-bearing consequence: `crt_dir` cannot serve a `-static` link or a
`libc++_shared` link, because neither archive is reachable from it. That is why
the link gate uses `linkage = .dynamic` and why the paths file carries no
separate library search path.

- **Counterchoice.** `usr/lib/<triple>` with an explicit API-level library path
  appended by the consumer. Genuinely wins if a future NDK moves the CRT
  objects up a level. It loses today: it makes every consumer re-derive a path
  that the sysroot already namespaces.

## 4. Published surface

Module `ndk`, root `root.zig`:

| Name | Kind | Meaning |
|---|---|---|
| `Abi` | enum | The five NDK ABI names, as `meta/abis.json` keys and `ANDROID_ABI` values |
| `Abi.name` | fn | ABI → that name. **Not** a path component of the sysroot: `usr/lib/` is namespaced by triple |
| `Abi.fromName` | fn | The inverse. Exact match only — no case folding, trimming or separator stripping |
| `Abi.triple` | fn | ABI → the sysroot triple under `usr/lib/<triple>/` |
| `Abi.minApiLevel` | fn | ABI → the NDK-declared floor, from `min_os_version` |
| `Abi.zigAbi` | fn | ABI → `std.Target.Abi` (`.android` / `.androideabi`) |
| `HostTag` | enum | The three host tags Google actually publishes: `linux-x86_64`, `darwin-x86_64`, `windows-x86_64` |
| `HostTag.directoryName` | fn | Host tag → the on-disk directory under `toolchains/llvm/prebuilt/` |
| `Ndk` | struct | A resolved installation: `root_path`, `host_tag`, `sysroot_path`, `shape` |
| `Ndk.Shape` | enum | Which of the two recognised layouts `root_path` was found under |
| `Ndk.find` | fn | Discovery over the documented env-var order |
| `Ndk.open` | fn | Open a root given explicitly |
| `Ndk.hostTag` | fn | Resolve the host tag for a target; `UnsupportedHost` where Google ships none |
| `Ndk.sysroot` | fn | Absolute sysroot path for the resolved host tag |
| `Ndk.tripleFor` | fn | ABI → NDK sysroot triple |
| `Ndk.libcDirFor` | fn | ABI + API level → `usr/lib/<triple>/<api>`, where the CRT objects are |
| `Ndk.apiLevelsFor` | fn | API levels present on disk for an ABI, sorted ascending |
| `Ndk.readVersion` | fn | `Pkg.Revision` from `source.properties`, or `VersionUnreadable` |
| `Ndk.Version` | struct | A parsed `Pkg.Revision` — the version code to pin a build against |
| `Ndk.Probes` | struct | Both layouts a candidate root was probed under, with the host tag |
| `Ndk.Probes.Entry` | struct | One probed layout: its `Shape`, the `ndk_root` it would be under, and the `sysroot` path it would resolve to |
| `Ndk.probeCandidates` | fn | Build that `Probes` value, for a diagnostic |
| `Ndk.describeProbeFailure` | fn | Render it into a caller's `std.Io.Writer`. This is how D3's promise is discharged |
| `LibcPaths` | struct | The six-field paths file Zig's `LibCInstallation.parse` demands. `forAndroid`, `render`, `deinit` |
| `Error` | error set | Every refusal a caller can act on. Six members, unchanged throughout |

Ownership is per type, and the three types differ deliberately. Getting this
wrong is a leak or a double free, so each is stated rather than implied.

| Type | Owns | Release |
|---|---|---|
| `Ndk` | nothing. Every slice it stores was **allocated from the allocator you passed** to `find` or `open` — not from your input buffer, so `root_path` never aliases what you handed in | **no `deinit`, by design** |
| `Ndk.Probes` | its paths, including each `Entry`'s | `Probes.deinit(gpa)` |
| `LibcPaths` | `include_dir`, `sys_include_dir`, `crt_dir` — `forAndroid` copies all three | `LibcPaths.deinit(gpa)` |

An `Ndk` having no `deinit` is a contract, not an omission: a caller who needs a
path after the build must copy it into storage it owns, and the absence stops a
caller believing the value owns anything.

**The one ownership trap:** `msvc_lib_dir`, `kernel32_lib_dir` and `gcc_dir` are
**borrowed, not owned**. `forAndroid` leaves them `null`, a caller that sets them
sets them to memory it owns, and `deinit` deliberately does not free them.
Freeing them would abort on a string literal, which is the natural thing to
assign on a Windows or Haiku path.

Errors are a closed set, never `anyerror`:

| Error | Meaning | Caller can act |
|---|---|---|
| `NdkNotFound` | no candidate path exists or none was set | set `-Dndk` or the env var |
| `NotAnNdk` | a candidate exists but has no `toolchains/llvm/prebuilt/<host-tag>/sysroot` | point at an unpacked NDK, not a zip or an SDK root |
| `UnsupportedHost` | this host has no NDK host tag | build on a supported host, or cross the toolchain yourself |
| `UnsupportedAbi` | the ABI is not in this NDK's `meta/abis.json` | pick a shipped ABI |
| `ApiLevelUnavailable` | no `usr/lib/<triple>/<api>` for that level | pick a level the sysroot ships |
| `VersionUnreadable` | `source.properties` absent or unparsable | still usable; only the reported version is unknown |

`VersionUnreadable` is deliberately non-fatal in the sense that the `Ndk` value
is still returned with a `null` version — it is an error only where a caller
demands the version. The reader reports it; discovery does not fail on it.

## 5. What is not claimed

- **The bionic link through `build.zig` is observed, for two ABIs, both at
  API 35.** `zig build ndk-link-check` with `ANDROID_NDK_HOME` set exits 0 and
  writes `zig-out/bin/ndk-link-check`, which the gate's own ELF check reads
  back and which `file(1)` reports as an aarch64 Android PIE with interpreter
  `/system/bin/linker64`, for Android 35, built by NDK r29. Measured matrix:

  | ABI | API | Result |
  |---|---|---|
  | `arm64-v8a` | 35 | links |
  | `riscv64` | 35 | links |
  | `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64` | 21 | **`undefined symbol: preadv64` / `pwritev64`** |

  That API-21 failure is **bionic plus Zig's default panic handler, not the NDK
  wiring**: the libc paths file resolves and the paths-file helper succeeds at
  every level, and the boundary is the API level rather than the ABI — the same
  ABI is green at 35 and red at 21. bionic gained `preadv64` and `pwritev64` at
  API 24, and Zig's default panic path reaches `std.Io.Threaded`, which calls
  both. `ReleaseSmall` and `ReleaseFast` drop that reference and do link at 21.

  So the usable floor for a Debug build is **API 24**, not the 21 the NDK
  declares for four of the five ABIs. That gap is recorded rather than worked
  around: forcing the gate to `ReleaseSmall` would silently discard the
  caller's `-Doptimize` and hide Debug link failures, which is a worse gate
  than a red one with a known cause. The other three ABIs at API 24 or above
  have **not** been observed linking.
- **No claim about any other NDK revision.** r29 was read, and r29 is now on
  Google's unsupported-downloads list. r30 is the current LTS at
  `30.0.16248370`, tagged 2026-09-08; its changelog changes only the LLVM
  version and the maximum API, so this pin is behind rather than chosen — but
  the bump has not been made or verified here. r27/r28 were not read.
- **No claim about `ndk-build` or the CMake toolchain file**, by scope.
- **No speed, size, or throughput claim.** Nothing here was measured.
- **No runtime observation.** The linked Android binary was never executed; it
  cannot be, on this host. Everything claimed of it is what `file(1)` reads
  from its headers.
- **The compiler record is 0.16.0, and it is no longer the newest.** Zig 0.17.0
  shipped 2026-10-01. `.minimum_zig_version` is advisory in 0.16.0 and enforces
  nothing, so nothing here would refuse a 0.17 build — and every `file:line`
  citation in this document is anchored to 0.16.0 and has not been re-checked
  against 0.17.0.

## 6. Gate ladder

Per the foundation per-fork contract §4.3, adapted: this package has no C of its
own, so items 2, 3 and 6 apply in their Zig-only form. The `libffi` `abicheck/`
pattern has no direct analogue here, because there is no vendored C whose layout
could drift from a header: the thing that can drift is the **NDK's own layout
facts**, and those are guarded by `tools/sync-ndk.sh` (which diffs `src/ndk.zig`
against a real NDK's `meta/abis.json`) and by `ndk-link-check`, which fails
unless a real bionic binary for the selected ABI comes out the other end.

| Gate | Command | What a green run establishes |
|---|---|---|
| fmt | `zig build fmt-check` | formatting |
| host tests | `zig build test` | parsing, discovery ordering, error paths, on the host target |
| cross compile | `zig build ndk-abi-check` | each ABI's `std.Build` target query resolves and the module compiles for it |
| libc link | `zig build ndk-link-check` | Zig links a bionic Android binary against the real sysroot |

`ndk-link-check` is the gate that decides whether this package is useful, and it
is the only one that reads an artefact back — an install plus an ELF identity
check, so a compile that emits nothing fails rather than passing. It was
observed green for `arm64-v8a` and `riscv64` at API 35; see §5 for the full
matrix and the API-24 floor.
