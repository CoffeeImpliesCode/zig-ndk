# zig-ndk — rules for agents

Android NDK integration for the Zig 0.16 build system. Pure Zig: no C of our
own, no vendored header, no part of the NDK redistributed. This file is the
entry point for an agent that has read nothing else in the tree, so it carries
the rules with their reasons and cites paths instead of restating them.

## 1. What this package is, and what it is not

- **It is** discovery of an unpacked NDK (`Ndk.find`, `Ndk.open`) plus a
  description of its sysroot: the five ABI names, their sysroot triples,
  the API-level library directories, and the six-field libc paths file
  `std.zig.LibCInstallation.parse` demands. That is the whole product. One
  paragraph of why it exists: `README.md` §The problem.
- **It is not** a translation of `ndk-build`, of the NDK CMake toolchain file,
  or of the Makefile fragments between them. That is a decision, recorded in
  `CONTRACT.md` §1 and `CHANGELOG.md` p0001, not a gap waiting to be filled. A
  proposal to add translation has to argue that scope line in the open, in
  those files. Do not helpfully port a toolchain fragment.
- **It ships no C and vendors no NDK header.** House-contract item 3
  (`b.addTranslateC`) therefore does not apply here — there is no C artefact to
  translate (`CONTRACT.md` D5). Do not add a vendored header to make
  translate-c possible; the NDK's headers reach consumer code through the
  sysroot `include_dir` this package hands Zig, which is a link path, not a
  translation step.
- **No device, no runtime, no JNI.** Nothing in this package has executed on
  Android or an emulator and no such claim may be added. `CONTRACT.md` §5 and
  `CHANGELOG.md` §Deferred list what is not claimed; if your change invalidates
  a line in either, fix that line in the same commit.

## 2. Compiler contract — Zig 0.16.0 only

`build.zig.zon` carries `.fingerprint` and
`.minimum_zig_version = "0.16.0"`; `.name` is an enum literal, never a
string. Do not write code that happens to compile on 0.15.

- **`b.addModule("ndk", …)`, not `b.createModule`.** Only `addModule`
  registers a name in the build graph, and `Dependency.module(name)` resolves
  that table. A `createModule` module is invisible to dependents, so
  `dep.module("ndk")` fails in the *consumer's* build, not ours. Every other
  `createModule` in `build.zig` is private on purpose.
- **`b.addLibrary(.{ .linkage = … })`, not `b.addStaticLibrary`.** The
  per-linkage helpers are gone in 0.16; linkage is a field of one function.
- **`b.addInstallArtifact(art, opts)`.** This is 0.16's install entry point.
  `b.installArtifact` still exists, but it is a wrapper that calls
  `addInstallArtifact(art, .{})` and hangs the result on the *top-level*
  install step. Reach for `addInstallArtifact` when you need options or an
  install step outside the default one, and `dependOn` it yourself (trap 10 in
  the §3 list).
- **`b.addTest` paired with `b.addRunArtifact`.** Never `b.addTest` alone; see
  §3. `addTest` returns a `*Step.Compile`.
- **`b.addTranslateC`, not `@cImport`.** `@cImport` is deprecated in 0.16.0.
  Unused here by design (§1), and never to be reintroduced.
- **`callconv(.c)`, not `callconv(.C)`.** Calling-convention tags are
  lowercase in 0.16 (`.c`, `.winapi`, `.kernel`); the pre-0.14 spellings do
  not exist.

The authoritative source is the compiler tree on this host,
`~/tools/zig-0.16.0/lib/std/Build.zig` and
`lib/std/Build/Step/*.zig`. When a signature matters — especially in a doc
comment or a commit message — cite `file:line` from there rather than from
memory or a blog post.

## 3. The two traps that apply to this repo

Both are verified in the 0.16 std sources and both bit us; they are traps 1
and 6 of `foundation/research/zig-packaging-patterns.md` §8, which house
contract item 2 names.

1. **`Compile.installHeader` / `installHeadersDirectory` do not put a header on
   the library's own compile line.** They publish the staged include tree to
   *dependents* that call `linkLibrary`; std says the compile step itself does
   not depend on the write-files step. The moment this package grows a header
   or a C source of its own, its module needs `Module.addIncludePath` for that
   include root too. Today it ships no header, so this is a guard on the change
   you are about to make, not a live bug — and the trap is what makes "add a C
   wrapper" a bigger change than it looks.
2. **`b.addTest` does not run anything.** Pair it with
   `b.addRunArtifact(tests)`, set `run.has_side_effects = true` (a test runner
   declares no output arguments, so a cached second build skips it otherwise),
   and `b.step("test", …).dependOn(&run.step)`. Forget the pair and
   `zig build test` stays green forever without executing one assertion.
   `build.zig` does all three; keep them together when you add a gate.

Read the full list of twelve before touching `build.zig`:
`zig-packaging-patterns.md` §8.

## 4. Pinned NDK facts, and the check that notices when they move

- The five-ABI table, the sysroot triple spellings and the six-field libc paths
  file format are **derived facts, not design**. Their single home is
  `CONTRACT.md` §2 for the citations, `src/ndk.zig` and `src/libc_file.zig` for
  the implementation, and `CHANGELOG.md` for the ledger entry with its enforcer
  named. Do not copy them into a new file, a doc comment, or this one. That is
  how a second source of truth starts, and it is how a stale fact survives a
  review.
- Every one of them was read from **NDK r29 (`29.0.14206865`) on one x86_64
  Linux host** — not from a specification, not from r27/r28/r30. Anything you
  derive from them inherits that label and must say so.
- `tools/sync-ndk.sh` is the enforcer for the NDK-owned facts: it re-resolves
  the release identity, verifies the SHA-256 in `tools/ndk.sha256`, and diffs
  `src/ndk.zig`'s table against a freshly parsed `meta/abis.json`, exiting
  non-zero on any change. Run it read-only before and after touching that
  table, or run `zig build sync-ndk`, which is the same script as a gate and
  is what CI runs.
  `--accept` re-records the hash and **does not** update `src/ndk.zig` or
  `root.zig` — that work is yours. It cannot check the libc paths file format;
  that is a compiler fact, watched only by a compiler bump (`CHANGELOG.md`
  p0004).
- When a fact moves, follow the ordered procedure in `CHANGELOG.md` p0003. The
  comptime pins in `root.zig` (five ABIs; exactly one ABI whose floor exceeds
  Zig's default API level) move with the table, or the build fails there
  instead of failing later as a missing directory.

## 5. Verification

Gates are owned by `build.zig` and documented in `README.md` §Gates.

- **fmt — `zig build fmt-check`.** Establishes that every path in this
  package is formatted. Needs no NDK.
- **host tests — `zig build test`.** Establishes that the paths file parses
  and renders, that discovery order holds, and that every error path fires,
  all on the host target. Two `b.addTest` roots hang off this one step: the
  unit tests in `src/`, reached through `root.zig`, and
  `test/integration_test.zig`, reached through the published `ndk` module
  under the name a dependent imports it by. Counted on 2026-10-05 that is 53
  test blocks — 35 unit (29 in `src/ndk.zig`, 5 in `src/libc_file.zig`, 1 in
  `root.zig`) and 18 in the integration file — but a count written in a
  document is the one number here that rots; `zig build test` prints the real
  one. Needs no NDK.
- **cross compile — `zig build ndk-abi-check`.** Establishes that every ABI's
  `std.Target.Query` resolves and the package compiles for it. The binaries
  are never run. Needs no NDK.
- **libc link — `zig build ndk-link-check`.** Establishes that Zig links a
  real bionic Android executable against a real sysroot, and then reads the
  installed artefact back and checks four things about it: `EI_CLASS`,
  `e_machine`, `PT_INTERP` and `DT_NEEDED`. A green compile is not a proof, so
  the readback is the proof. **Needs an NDK.** The artefact is installed as
  `zig-out/bin/ndk-link-check-<abi>-api<level>` — one file per cell, so five
  ABI runs no longer overwrite each other and the directory is the record of
  what was linked. `PT_INTERP` and `DT_NEEDED` are not decoration: on x86_64,
  this gate's own CI architecture, a host glibc PIE and a bionic Android
  binary agree on `e_machine`, `EI_CLASS`, `EI_DATA` and `ELFOSABI_NONE`, and
  `e_machine` alone cannot tell them apart. `PT_INTERP` must name
  `/system/bin/linker` or `/system/bin/linker64` by class, and `DT_NEEDED`
  must name `libc.so` where glibc names `libc.so.6`. Do not "simplify" the
  readback to a header check; a header check is what this gate already had,
  and it was green on a host binary.
- **pin check — `zig build sync-ndk`.** Establishes that the release
  identity, the archive hash and the copied ABI table still describe the NDK
  in front of it (§4). **Needs an NDK**: finding none, the step depends on a
  failing step naming every source it tried, exactly as the link gate does.
- **local aggregate — `zig build check`.** `test` plus `ndk-abi-check`. Needs
  no NDK. **CI does not run this step** (§8): the workflow runs those two
  halves as two jobs, because one job per gate is one red gate per failure.
- **everything — `zig build all`.** `check`, plus `fmt-check`, the bionic link
  and the pin check. Needs an NDK.

Every row above was observed on this host on 2026-10-05 against NDK r29. The
per-gate figures and the link artefact are recorded in `README.md` §Gates;
that table is the measurement and this list is only its summary, so a re-run
supersedes it rather than this paragraph.

**Hard rule: `test` and `check` must pass on a machine with no NDK installed and
no `ANDROID_NDK_*` set.** A consumer who fetches this package may have neither,
and a host gate that needs a sysroot is a gate nobody can run. Only
`ndk-link-check` and `sync-ndk` may require an NDK, and a missing NDK must not
abort configuration — both hang a failing `Step.Fail` carrying the ordered
list of sources they tried, so `zig build all` still configures and still
refuses. Every test builds the tree it asserts against; no test may require a
real NDK installation, and none may skip itself silently either.

`zig build test -Dtarget=<foreign>` compiles the tests and does not run them;
the build prints that it is doing so. `ndk-abi-check` is the cross-target gate.

`ndk-link-check` is the gate that decides whether this package is worth
anything; everything else proves the description is internally consistent. Run
it per ABI when you touch path construction — `-Dabi=<name>`, and
`-Dapi=35` for `riscv64` (`CHANGELOG.md` p0006). Until it is green for an ABI,
"it works" means "the mechanism is not a prediction", which `CONTRACT.md` §1
established by probe, and not "this ABI is covered".

After any change to `build.zig`, `src/*.zig` or `root.zig`: `zig build check`
and `zig build fmt-check`. If the ABI table moved, also `zig build sync-ndk`,
which is the same script as a gate and needs an NDK — on a host that has none,
run `tools/sync-ndk.sh` directly instead.

## 6. Style

- `camelCase` functions, `PascalCase` types, `snake_case` for C names and for
  locals that mirror them. 100-column soft limit.
- Explicit public error sets; never `anyerror`. `Error` in `root.zig` is the
  closed set and every member's meaning is tabulated in `CONTRACT.md` §4.
  Adding a member is a public API change: update that table in the same commit.
- `///` on every public item, stating the **contract** — what the caller may
  rely on, what is borrowed, which error means what — never a restatement of
  the implementation. `Ndk` has no `deinit` because it is a borrowed view of a
  directory tree; say so where a reader would otherwise look for one.
- Comments say **why**. A comment that repeats the next line is deleted. A
  decision with a counterchoice somebody might re-litigate belongs in
  `CONTRACT.md` §3 or `CHANGELOG.md`, not in a trailing comment.
- No hidden allocation, and the asymmetry is the half to remember. Seven
  public entry points take a caller-supplied allocator, and they do not agree
  on who frees what. `Ndk.libcDirFor` and `Ndk.apiLevelsFor` return a slice
  the caller frees. `Ndk.probeCandidates` returns a `Probes` that the caller
  MUST release with `Probes.deinit`. `Ndk.find` and `Ndk.open` return an `Ndk`
  whose slices come from that same allocator and are nobody's to free.
  `Ndk.describeProbeFailure` builds and frees its own `Probes` and returns
  `void`. `Ndk.readVersion` returns a `Version`, a value type that owns
  nothing. An `Ndk` value itself allocates nothing and has deliberately no
  `deinit`. Two values here DO own their paths and MUST be released:
  `Ndk.Probes`, which exists only to be freed on a discovery failure, and
  `LibcPaths`, whose `deinit` frees exactly the three paths `forAndroid`
  copied. **No `deinit` means "owns nothing", never "nothing to free."**
- **Test with `std.testing.allocator`, not an arena, whenever the question is
  a `free`.** The two catch different bugs. The checking allocator catches
  leaks *and* size mismatches; an arena swallows a short free silently,
  because `free` on arena-backed memory is a no-op, so an all-arena suite
  cannot see one at all. `Ndk.probeCandidates` freed its canonical root one
  byte short on every call where the root existed on disk — `realPathFileAlloc`
  returns `[:0]u8`, allocating n+1 bytes, and the `[]u8` peer is handed the
  peeled length — and every call site here used an arena, so it stayed green.
  Use an arena only where leaking is the point; the one place that earns it is
  `std.zig.LibCInstallation`, whose `deinit` is broken at this compiler line
  (`parseRendered` in `src/libc_file.zig`).
- Match the code that is there. `src/` has one house style; do not introduce a
  second one inside one file.

## 7. Version control

- **jj colocated with git**: `.jj/` holds the git object backend. Use `jj`
  commands. Reaching for `git` puts you one step from writing an object the
  backend does not track.
- **Commits are the integration owner's job only.** Do not commit, describe,
  amend, rebase, split or abandon anything. Leave the change in the working
  copy, with a `CHANGELOG.md` ledger entry when a pinned fact or a public
  decision moved.
- **Never leave a red tree.** House-contract item 7: every commit builds.
  `zig build check` and `zig build fmt-check` green before anything is
  committed. A commit that needs a follow-up to fix is a broken history entry.

## 8. House contract — what is satisfied, and what is not

`foundation/docs/01-first-wave.md` §4.3, items 1–8. This package is Zig-only,
so items 2, 3 and 6 have no C to act on (`CONTRACT.md` §6) and item 4 is
satisfied by `b.option` for NDK *discovery*, by decision D4:
`b.systemIntegrationOption` governs linking a system library by name, which is
a different shape. Items 1 and 7 are obligations on every change: nothing is
fetched at build time (§1), and no commit is red (§7).

Items 5 and 8 are obligations on a CI workflow, and
`.github/workflows/ci.yml` is that workflow: five jobs — `fmt`, `test`,
`cross`, `link`, `licence` — on push, pull_request and workflow_dispatch.
One of the two items it owed is discharged. The other is not.

- **Item 8, the licence gate — discharged.** The `licence` job requires a
  non-empty `LICENSE`, hard-rejects GPL/LGPL/AGPL by abbreviation *and* by
  spelled-out title, rejects `NOASSERTION`, then requires at least one
  allowlisted licence name. This package ships MIT, so the gate is written to
  pass — the licence it will pass on is a prediction, not a run (see the last
  bullet). What the job removes is the review blind spot: a relicensing pull
  request stops depending on somebody reading the diff.
- **Item 5, cross-compilation — partly discharged.** Gated today:
  `x86_64-linux`, the `fmt`/`test`/`licence` jobs' own runner, natively; and
  the five Android ABIs, by the `cross` job. That job is one command, not a
  matrix: `ndk-abi-check` takes no ABI selector, loops its own five-entry
  table internally and hangs five compile steps off the single step, so a
  green `cross` is the claim for all five at once. It resolves a target query
  per ABI and compiles; it never runs the binaries and never reads a sysroot.
  The `link` job adds the claim no other job makes: that Zig links a real
  bionic executable against a real sysroot.
- **The gap, named.** The house contract's Tier-2 host triples
  `aarch64-linux`, `aarch64-macos`, `x86_64-windows` and `wasm32-wasi` are
  not gated as *host* targets, and `riscv64-linux` is not either: what covers
  riscv64 is an entry of `ndk-abi-check`'s table, an Android ABI, a different
  OS, which `ci.yml`'s own header says. Closing the gap needs a compile-only
  cross step in `build.zig` for a non-Android host triple, and no such step
  exists. `zig build` exposes, in build.zig's declaration order, `install`,
  `uninstall`, `test`, `ndk-abi-check`, `ndk-link-check`, `sync-ndk`, `fmt`,
  `fmt-check`, `check` and `all` — only `ndk-link-check` and `sync-ndk` want an
  NDK — and the only target any of them takes is `-Dtarget`, which selects the
  target the *tests* compile for, not a host cross gate. The nearest thing
  that exists is the `test` step degrading to compile-only under a foreign
  `-Dtarget`; it is wired to no job and has never run green for any of those
  triples. Do not give it a step name in a commit message: there is none to
  give.
- **The second gap, per-ABI observation.** `cross` compiles all five ABIs in
  one job, so a failure there names a job and not an ABI. And `link` runs
  `ndk-link-check` with neither `-Dabi` nor `-Dapi`, so it links only the
  defaults — `arm64-v8a` at API 35 — and the other four ABIs are never linked
  by anything CI runs. The capability exists, because `ndk-link-check` takes
  `-Dabi=` (§5), but nothing in the workflow varies it. Do not read the
  `cross` job's coverage as link coverage: compiling for an ABI and linking
  against its sysroot paths are the two claims this package keeps apart
  everywhere else.
- **CI runs five gate steps across five jobs, never `zig build check` itself.**
  `fmt-check` is the `fmt` job, `test` the `test` job, `ndk-abi-check` the
  `cross` job, and `link` runs two — `sync-ndk`, then `ndk-link-check`, in
  that order, because the pin is only worth checking against the sysroot the
  link will then use. Three of those five are gates `check` does not contain:
  `fmt-check`, `sync-ndk` and `ndk-link-check`. Four of the five jobs provision
  no NDK and assert nothing about one; only `link` fetches it. The fifth job,
  `licence`, is item 8's shell gate and runs no build step at all.
- **Every gate has been observed locally; CI itself never has.** This is the
  distinction worth keeping and the easy one to get backwards. Observed on
  this host on 2026-10-05 against NDK r29: every row of `README.md` §Gates
  exits 0, and the link gate installs
  `zig-out/bin/ndk-link-check-<abi>-api<level>` —
  `ndk-link-check-arm64-v8a-api35` for the default cell — which
  `file(1)` reads as an aarch64 Android PIE with interpreter
  `/system/bin/linker64`, built by NDK r29. The bionic link is established,
  not predicted. That table is the record: re-read it rather than re-deriving
  it, and re-run a gate rather than quoting this paragraph, which summarises
  one morning and will go stale. **Not** observed: CI. This repository has
  never been pushed through the workflow, so write "CI runs `X`", never "CI is
  green".