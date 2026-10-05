# zig-ndk — rules for agents

Android NDK integration for the Zig 0.16 build system. Pure Zig: no C of our
own, no vendored header, no part of the NDK redistributed. This file is the
entry point for an agent that has read nothing else in the tree, so it carries
the rules with their reasons and cites paths instead of restating them.

## 1. What this package is, and what it is not

- **It is** discovery of an unpacked NDK (`Ndk.find`, `Ndk.open`) plus a
  description of its sysroot: the five ABI directories, their sysroot triples,
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
`/home/janis/tools/zig-0.16.0/lib/std/Build.zig` and
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
  non-zero on any change. Run it read-only before and after touching that table.
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
  under the name a dependent imports it by. Needs no NDK.
- **cross compile — `zig build ndk-abi-check`.** Establishes that every ABI's
  `std.Target.Query` resolves and the package compiles for it. The binaries
  are never run. Needs no NDK.
- **libc link — `zig build ndk-link-check`.** Establishes that Zig links a
  real bionic Android executable against a real sysroot. **Needs an NDK.**
- **what CI runs — `zig build check`.** `test` plus `ndk-abi-check`. Needs no
  NDK.
- **everything — `zig build all`.** The above, plus `fmt-check` and the
  bionic link. Needs an NDK.

**Hard rule: `test` and `check` must pass on a machine with no NDK installed and
no `ANDROID_NDK_*` set.** A consumer who fetches this package may have neither,
and a host gate that needs a sysroot is a gate nobody can run. Only
`ndk-link-check` may require an NDK, and a missing NDK must not abort
configuration. Every test builds the tree it asserts against; no test may
require a real NDK installation, and none may skip itself silently either.

`zig build test -Dtarget=<foreign>` compiles the tests and does not run them;
the build prints that it is doing so. `ndk-abi-check` is the cross-target gate.

`ndk-link-check` is the gate that decides whether this package is worth
anything; everything else proves the description is internally consistent. Run
it per ABI when you touch path construction — `-Dabi=<name>`, and
`-Dapi=35` for `riscv64` (`CHANGELOG.md` p0006). Until it is green for an ABI,
"it works" means "the mechanism is not a prediction", which `CONTRACT.md` §1
established by probe, and not "this ABI is covered".

After any change to `build.zig`, `src/*.zig` or `root.zig`: `zig build check`
and `zig build fmt-check`, plus `tools/sync-ndk.sh` if the ABI table moved.

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
- No hidden allocation. `Ndk` allocates nothing and frees nothing; the
  path-building functions (`Ndk.libcDirFor`, `Ndk.apiLevelsFor`) take a
  caller-supplied allocator and return a slice the caller frees.
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
  allowlisted licence name. This package ships MIT, so the gate is green, and
  a relicensing pull request now fails in CI rather than in nobody's review.
- **Item 5, cross-compilation — partly discharged.** Gated today:
  `x86_64-linux`, the `fmt`/`test`/`licence` jobs' own runner, natively; and
  the five Android ABIs, one `cross` matrix leg each, through
  `ndk-abi-check`, which resolves a target query and compiles the package for
  it but never runs it. The `link` job adds the claim no other job makes: that
  Zig links a real bionic executable against a real sysroot.
- **The gap, named.** The house contract's Tier-2 host triples
  `aarch64-linux`, `aarch64-macos`, `x86_64-windows` and `wasm32-wasi` are
  not gated as *host* targets, and `riscv64-linux` is not either: the
  `riscv64` `cross` leg is an Android ABI, a different OS, which `ci.yml`'s
  own header says. Closing that needs a compile-only cross step in `build.zig`
  for a non-Android host triple, and no such step exists. `zig build` exposes
  `install`, `uninstall`, `fmt`, `fmt-check`, `test`, `ndk-abi-check`,
  `ndk-link-check`, `check` and `all`, and the only target any of them takes
  is `-Dtarget`, which selects the target the *tests* compile for, not a host
  cross gate. The nearest thing that exists is the `test` step degrading to
  compile-only under a foreign `-Dtarget`; it is wired to no job and has never
  run green for any of those triples. Do not give it a step name in a commit
  message: there is none to give.
- **CI runs the two halves of `check` separately**, never `zig build check`
  itself — `zig build fmt-check` is the `fmt` job, `zig build test` the `test`
  job, `zig build ndk-abi-check` the `cross` job. Four of the five jobs
  provision no NDK and assert nothing about one, so their green runs are the
  evidence that the sysroot stays optional and that a red CI is not a broken
  package. Only `link` fetches the NDK.