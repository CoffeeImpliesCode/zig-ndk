# Changelog — pinned facts, and what a bump has to revisit

This package modifies no upstream C, vendors no header, and wraps nobody's
build system. What it consumes is an Android NDK directory tree, read at build
time, and a Zig compiler whose libc-hooks format it has to speak. So the house
rule for this file is not "every divergence from upstream"; it is a **ledger**.

Every entry below records a fact this package copied out of something it does
not own, says where the fact was read, and names the check that notices when it
moves. Two things follow from that, and they are the whole discipline:

- **An entry that no named check can invalidate does not belong here.** Either it
  names its enforcer, or it says in plain words that nothing enforces it and
  names the event that would.
- **Entries are invalidated by two different things.** The NDK entries move when
  Google ships r30. The compiler entries move when Zig ships 0.17. A single
  bump often touches both, and conflating them is how a stale fact survives a
  review.

Pinned compiler: **Zig 0.16.0**, tag
`24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`. Pinned NDK: **r29**
(`29.0.14206865`), unpacked and read on this host at
`/tmp/ndkx/android-ndk-r29`; release identity in `tools/ndk.sha256`. No claim
here is made about any other revision of either.

**Two entries record a fact that was wrong when first written and is now
corrected**, and both were caught by reading the sysroot on disk rather than by
any check: p0004's `sys_include_dir`, which was
`<sysroot>/usr/include/android` and is `<sysroot>/usr/include`, and p0008's
host-tag set, which was five tags and is three. p0005's claim about where the
API-agnostic archives live was wrong in the same way and is corrected there.
Each says so in its own body, because a ledger entry that silently changes its
answer is indistinguishable from one that never had one.

## Ledger

### p0001 — the package exists, and its scope is one gap

Zig 0.16.0 has no NDK awareness and bundles no bionic. A freestanding
`-target aarch64-linux-android` binary builds; the same target with `-lc` fails
with `error: unable to provide libc for target '…'`, and pointing Zig at the
sysroot with `--libc <dir>` fails with `IsDir`, because
`std.zig.LibCInstallation.parse` accepts a file and not a directory.

This package closes that gap: it describes the sysroot layout and renders the
six-field libc paths file Zig demands. That is the entire scope.

**Explicitly out of scope:** `ndk-build`, the NDK CMake toolchain file, and
translation of either. Those are translation systems, and translating them is a
different project with a different consumer. Recorded here because scope creep
is the most likely way this package could grow into something nobody reviewed.

**Enforcer: nothing, and deliberately so.** This entry is a scope decision, not
a fact read from an NDK or from Zig, so no script in this tree can invalidate
it and none is pretending to. What holds it is the rule at the top of this
file: a proposal to widen the scope has to argue this line, here, in the open,
before any code moves.

**What a bump does:** nothing. **What a proposal does:** it has to argue the scope
line above, in this file, in the open.

### p0002 — the NDK release is pinned by four facts

| Fact | Value | Read from |
|---|---|---|
| release | `r29` | `source.properties`, `Pkg.ReleaseName` |
| revision | `29.0.14206865` | `source.properties`, `Pkg.Revision` |
| size | `783549481` | `wc -c` on the zip |
| sha256 | `4abbbcdc842f3d4879206e9695d52709603e52dd68d3c1fff04b3b5e7a308ecf` | `sha256sum` on the zip |

**Enforcer:** `tools/sync-ndk.sh`. It re-resolves all four, verifies the hash
against `tools/ndk.sha256`, and exits non-zero on any change. `--accept`
re-records the hash after a human has read the diff.

**What a bump does:** run the script, read the diff, then p0003 through p0005 —
a revision that changes the ABI table or the CRT layout is not a hash edit.

### p0003 — the ABI table is derived from `meta/abis.json`

Five rows, read verbatim from `meta/abis.json` at r29:

| ABI name | sysroot triple | min API | Zig ABI |
|---|---|---|---|
| `armeabi-v7a` | `arm-linux-androideabi` | 21 | `.androideabi` |
| `arm64-v8a` | `aarch64-linux-android` | 21 | `.android` |
| `riscv64` | `riscv64-linux-android` | 35 | `.android` |
| `x86` | `i686-linux-android` | 21 | `.android` |
| `x86_64` | `x86_64-linux-android` | 21 | `.android` |

Three things are worth writing down rather than leaving to whoever bumps this
next. First, **the left column is not a path.** Those five names are the keys
of `meta/abis.json` and the values `ANDROID_ABI` takes. Directories under
`sysroot/usr/lib` are named by the *triple* column: there is no `arm64-v8a` and
no `armeabi-v7a` directory anywhere in an NDK, and a reader who took the left
column for a path would look for two directories that do not exist. Second, the
directory names and triples are also not Zig triples: `x86` is Zig `x86`, but
the NDK calls it `i686`, and `armeabi-v7a` has no Zig spelling at all — the tag
is `arm-linux-androideabi`. Third, `riscv64` is the odd row: its floor is 35
while every other ABI is 21, which is a divergence in the NDK, not a rounding
difference. See p0006 for why that matters more than it looks.

**Enforcer:** `tools/sync-ndk.sh` diffs the table in `src/ndk.zig` against a
freshly parsed `meta/abis.json` and fails on any change to an ABI key, a
triple, or a minimum API level. It also compares the enum's own tag list with
the set of tags those three accessors map, because a tag deleted from the enum
while its switch arms stayed behind still scrapes clean and no longer compiles.
`root.zig`'s comptime block pins `abis.len == 5` and rejects a triple or key
shared by two ABIs, which is what catches a table edited into a shape the NDK
would never ship. `Abi.fromDirectoryName` is asserted to be the exact inverse
of `directoryName`, so the two halves cannot drift.

**What a bump does, in this order:** re-read `meta/abis.json`; update the table in
`src/ndk.zig`; update the two pins in `root.zig` that assume five ABIs
(`abis.len != 5` and the count of ABIs whose floor exceeds Zig's default API
level); re-run `tools/sync-ndk.sh`; add an entry here.

### p0004 — the libc paths file format is derived from Zig, not from the NDK

Six fields, all mandatory, `=` separated, `\n` split, `#` comments: the header
is `name=value`, and a field present with an empty value is a present field.
`parse` rejects the file unless all six are present, unless `include_dir` and
`sys_include_dir` are non-empty, and — for every non-Darwin target — unless
`crt_dir` is non-empty. Read at `lib/std/zig/LibCInstallation.zig`: `parse` at
:41, `render` at :123.

The mapping onto an NDK is mechanical and is the mechanism of the whole
package:

| Field | Value |
|---|---|
| `include_dir` | `<sysroot>/usr/include` |
| `sys_include_dir` | `<sysroot>/usr/include` |
| `crt_dir` | `<sysroot>/usr/lib/<triple>/<api>` |
| `msvc_lib_dir`, `kernel32_lib_dir`, `gcc_dir` | present, empty |

`sys_include_dir` is a trap worth naming, and it is a fact that **changed
during this work**. It was first written here, and implemented, as
`<sysroot>/usr/include/android`; an on-disk check of the unpacked r29 sysroot
showed that path does not hold `sys/errno.h`, and that
`<sysroot>/usr/include/sys/errno.h` does. The value is therefore
`<sysroot>/usr/include` — the same directory as `include_dir` — and it is
recorded at the top of this entry's table above.

The wrong answer is a plausible one. `sys_include_dir` is the directory holding
`sys/errno.h`, and `usr/include/android` is a real directory under
`usr/include` that looks like the platform-specific half of a POSIX sysroot and
holds no `sys/` tree at all. Nothing in Zig detects the mistake: `parse`
rejects only an *empty* `sys_include_dir`, and `usr/include/android` is not
empty, so a file written that way parses, links, and passes every gate in the
ladder while pointing at the wrong directory. Verified by listing the r29
sysroot on this host: `usr/include/sys/errno.h` exists, `usr/include/android/sys`
does not.

**Enforcer: the generated helper asserts it on disk at link-gate time.** The
paths-file helper `build.zig` generates checks `<include_dir>/stdio.h` and
`<include_dir>/sys/errno.h` with an on-disk access and fails the gate if either
is absent, so the `android/` spelling cannot survive a green
`ndk-link-check`. The *format* above — six fields, all mandatory — has **no
enforcer, by design**, and that is stated rather than left implied: it is a
compiler fact rather than an NDK fact, so `tools/sync-ndk.sh` cannot invalidate
it. What watches the format is a compiler bump: at 0.17.0, re-read
`LibCInstallation.zig` before trusting this table, and expect either a new
mandatory field or a changed comment rule. `src/libc_file.zig`'s round-trip
test holds the rendered bytes against Zig's own `render` and `parse`, which
catches a change in the format's layout but not a change in the NDK-side
values in the table.

### p0005 — `crt_dir` is the API-level directory

`crt_dir` must be `<sysroot>/usr/lib/<triple>/<api>` and not
`<sysroot>/usr/lib/<triple>`, because the CRT objects live **only** in the
API-level directory. Verified by listing the r29 tree on this host:
`sysroot/usr/lib/aarch64-linux-android/35/` holds the five CRT objects —
`crtbegin_dynamic.o`, `crtbegin_so.o`, `crtbegin_static.o`, `crtend_android.o`,
`crtend_so.o`, plus `crt_pad_segment.o` — alongside that level's shared
libraries, `libc.so` and `libm.so`, and the `libc++.so` / `libc++.a` linker
scripts.

**The API-agnostic archives are not there, and an earlier version of this entry
said they were.** `libc.a`, `libc++_shared.so`, `libc++_static.a`,
`libc++abi.a`, `libm.a`, `libdl.a` and `libz.a` are **siblings of the numeric
API directories, one level up** in the triple directory. This is the
load-bearing consequence, and it was wrong here before: `crt_dir` **cannot**
serve a `-static` link or a `libc++_shared` link, because neither archive is
reachable from the API-level directory. That is why the link gate uses
`linkage = .dynamic`, and why the paths file carries no separate library search
path. A consumer who needs `libc++_shared` must add
`<sysroot>/usr/lib/<triple>` to its own link line; this package will not guess
it for them.

Zig already knows the Android object names it looks for —
`crtbegin_so.o`, `crtbegin_dynamic.o`, `crtbegin_static.o`, `crtend_android.o`,
`crtend_so.o`, at `lib/std/zig/LibCInstallation.zig` :737-750 — and those names
are present in the r29 sysroot. That is why no manual object wiring exists in
this package.

**Enforcer: none for the object names, and stated here rather than left
implied.** `tools/sync-ndk.sh` does not list them. A bump that moves the CRT
objects is caught by `zig build ndk-link-check` **once that gate actually
emits a binary**, and by nothing else today — it exits 0 while producing no
ELF, so at the time of writing it would not catch this either. That gap is the
reason the gate is the one this package cannot ship without, and the reason its
current status is recorded as not established in `README.md` §Gates.

**Counterchoice, recorded so the next reader does not re-derive it:** pointing
`crt_dir` at the triple directory and letting each consumer append its own API
level. That wins if a future NDK hoists the CRT objects one level up, and it is
also the only choice that reaches the API-agnostic archives, since they live
there. It loses today for two reasons: it makes every consumer re-derive a path
the sysroot already namespaces, and it points `crt_dir` at a directory holding
no CRT object at all, which is the thing `crt_dir` is for.

### p0006 — Zig's default Android API level, and why `riscv64` breaks it

Zig resolves a bare `-target <abi>-linux-android` to Android API level **29**:
`lib/std/Target.zig` :484, `.android = 29`, reached as
`target.os.version_range.linux.android`.

For four of the five ABIs that is a level r29 ships. For `riscv64` it is not —
the floor is 35 (p0003) — so `usr/lib/riscv64-linux-android/29` does not exist
and a `riscv64` target built without an explicit API level resolves to a
directory that is not there. Consumers must pass the level:
`-target riscv64-linux-android -Dapi=35`, or `zig build-exe … -target
riscv64-linux-android.35` through this package's build wiring.

**Enforcer:** the `above_default != 1` count pinned in `root.zig`'s `comptime`
block. A second high-floor ABI, or a floor that moves, fails the build there
instead of failing later as a missing directory. The literal `29` is a
compiler fact, pinned with its `lib/std` citation in the same block, and it is
re-read at a compiler bump.

### p0007 — discovery order

`-Dndk=<path>`, then `ANDROID_NDK_HOME`, then `ANDROID_NDK_ROOT`, then
`ANDROID_NDK`. First hit wins; an explicit option beats an inherited
environment variable. `ANDROID_NDK_HOME` is first among the variables because
Google's own CMake toolchain prefers it, and because it is the one a user who
set it deliberately is most likely to have set.

This is our decision, not a fact copied from anyone, so no upstream bump
invalidates it. It is in the ledger because it has a cost that is easy to
rediscover the hard way: an inherited `ANDROID_NDK_HOME` from an unrelated
shell silently wins over a local checkout.

**Enforcer: the unit test named below, at `zig build test`,** plus
`build.zig`'s own refusal message. `src/ndk.zig` asserts that `Ndk.find` returns
the `-Dndk` root when the option is set even with all three variables pointing
elsewhere, that it returns the variable root when the option is absent, that a
variable naming a path that is not on disk is skipped for the next one, and that
a path which exists but is not an NDK stops discovery instead of falling through
to a worse answer. `build.zig`'s `ndkNotFoundMessage` prints all four sources
with `(unset)` / `(empty)` markers, which is the mitigation for the cost above
and is a build-script string, so nothing checks its wording — a reader does. The
cost is stated in `CONTRACT.md` D3 as well, and neither copy is derived from the
other.

### p0008 — the host-tag set is three tags, all of them x86_64

`linux-x86_64`, `darwin-x86_64`, `windows-x86_64`. That is all Google
publishes: r29's repository manifest offers `android-ndk-r29-linux.zip`,
`-darwin.zip` and `-windows.zip` plus their betas, with `<host-os>` of `linux`,
`macosx` and `windows` respectively, and no arm package on any host. The host
table at <https://developer.android.com/ndk/guides/other_build_systems> agrees,
three rows. The r29 tree unpacked on this host agrees, with a single prebuilt
directory: `toolchains/llvm/prebuilt/linux-x86_64`.

**This is a fact that changed during this work.** The set was five for a while:
the three above plus `linux-aarch64` and `darwin-arm64`. Neither of the two
extra tags corresponds to a package Google has ever shipped. The three above
are the corrected set, and `src/ndk.zig` and `root.zig` already carry it.

The trap is that `linux-aarch64` and `darwin-arm64` look obviously necessary.
Neither exists, and carrying them turned a host with no NDK into a user-facing
`error.NotAnNdk` about a path they had configured correctly — "that is not an
NDK" is the wrong problem and invites the wrong fix. A host that cannot be
served has to fail as `error.UnsupportedHost`, which names a different remedy:
cross the toolchain yourself. `aarch64-macos` is the exception and does resolve,
because it runs the `darwin-x86_64` package under Rosetta.

**Enforcer: no comptime check, and none possible from `tools/sync-ndk.sh`,
because the manifest is not in the NDK tree and the script only reads files
under the NDK root.** What enforces this is unit tests in `src/ndk.zig`, and
they enforce it at `zig build test`, not at configure time. Three assertions:
`std.enums.values(HostTag).len` must equal the length of the hosts the test's
own cases table lists, so a fourth tag fails; every tag must end in
`_x86_64`, so an arm tag fails; and every host Google publishes no package for
must come back `error.UnsupportedHost` and never `error.NotAnNdk`. The same
table's `aarch64-macos` row pins the Rosetta case to `darwin_x86_64`.
`root.zig`'s `HostTag` doc comment repeats the set, but as a comment it
enforces nothing. A plain `zig build` notices none of this. Re-read the manifest
at an NDK bump.

## Deferred, with reasons

Known, and not done. Recording them is more useful than leaving them implied.

- **No per-ABI link proof for any of the five ABIs, and not even one through
  this package's own build.** The bionic link was exercised once, by a manual
  `zig build-exe` against the r29 sysroot, for `aarch64-linux-android` at API 35.
  `ndk-link-check` exists to cover the rest and **does not yet**: it resolves the
  NDK, runs the paths-file helper, compiles the generated main, and emits no
  ELF. `linkAndroid` sets `link_libc`, which selects the libc *installation*,
  but nothing puts `libc.so` on the link line, and a dynamic link with no shared
  library succeeds without producing a binary. The gap is
  `compile.linkSystemLibrary("c")`. Until that is added and a run is observed to
  emit an Android ELF, per-ABI coverage is the open question, not the mechanism,
  and the gate's exit code must not be read as a pass.
- **Nothing reads a build artefact back.** No gate asserts that a file exists
  after a compile step, so a silent regression in `linkAndroid` would leave
  `test`, `check` and `ndk-abi-check` green. That is why the missing
  `linkSystemLibrary("c")` survived a green `ndk-link-check`.
- **No `-static` or `libc++_shared` link is supported.** `crt_dir` is the
  API-level directory, and the API-agnostic archives live one level up (p0005),
  so nothing this package hands Zig can reach `libc.a`.
- **No claim about r30.** r30 exists and is the current LTS; it was not read on
  this host. r27 and r28 were not read either. `tools/sync-ndk.sh` is the thing
  that turns "not read" into "read and diffed".
- **Two real on-disk root shapes exist.** Google's zip unpacks to
  `<ndk>/toolchains/llvm/prebuilt/<host-tag>/sysroot`, and nixpkgs' Android SDK
  puts the bundle under `libexec/android-sdk/ndk-bundle`. Both are handled;
  neither is the only case a consumer may hit, and `Ndk.Shape` is what records
  which one was found.
- **No vendored C, so no `b.addTranslateC`.** The package ships Zig that
  describes a sysroot. It has no C source and no header of its own to
  translate. The NDK's headers reach a consumer's code through the sysroot
  `include_dir` this package hands to Zig, which is a link path and not a
  translation step.