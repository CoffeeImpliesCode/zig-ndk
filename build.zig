//! zig-ndk — Android NDK integration for Zig 0.16.
//!
//! Zig 0.16.0 ships no NDK awareness at all. `zig build-exe -target
//! aarch64-linux-android` succeeds; the same command with `-lc` fails with
//! "unable to provide libc for target ...". This package closes that gap and
//! nothing else. The authoritative design is CONTRACT.md; the notes below
//! record only the Zig 0.16.0 mechanics this script depends on, each one
//! verified against `lib/std` at tag `0.16.0`.
//!
//!   * `b.addModule` publishes a module to dependents, `b.createModule` does
//!     not (Build.zig:906-920). CONTRACT.md D2 wants the published half to
//!     carry no `target` and no `optimize`, because the consumer supplies both
//!     and a pinned value is a value the consumer cannot override.
//!   * `b.addTest` only compiles. `Step.Run` runs it, and only if it declares
//!     `has_side_effects` or inherits stdio, otherwise it is skipped as cached
//!     on the second build.
//!   * A `Step.Run` fails its step on any non-zero exit when its stdio is
//!     `.inherit`, whether it got there by inference or by assignment:
//!     `runCommand` falls through to `handleChildProcessTerm`
//!     (Step/Run.zig:1497-1510), which fails on every code but zero
//!     (Step.zig:726-729). A `Step.Run` carrying no output argument also
//!     already counts as having side effects (`hasSideEffects`,
//!     Step/Run.zig:707-715), so the build runner never caches it away. Those
//!     two facts are the whole mechanism behind `zig build sync-ndk`: they are
//!     what make a shell script a gate rather than a command this build runs
//!     and reports success on either way.
//!   * `Step.Compile.linkage = .dynamic` is what emits `-dynamic`
//!     (Step/Compile.zig:1487-1490) and `Module.link_libc = true` is what
//!     emits `-lc` (Step/Compile.zig:1055, :1355-1357). Bionic needs both.
//!   * A `Step.Compile` nobody asked to produce emits nothing, and says so
//!     successfully: the build runner passes `-fno-emit-bin` while
//!     `generated_bin` is null (Step/Compile.zig:1406), and only installing or
//!     running the artefact allocates it. A gate over such a step is green and
//!     proves nothing, so `ndk-link-check` installs its executable and then
//!     reads the installed file back.
//!   * `Compile.setLibCFile` is the only way to hand Zig an external libc
//!     (Step/Compile.zig:829); `LibCInstallation.parse` (zig/LibCInstallation.zig:41)
//!     rejects a directory, so the value must be a libc paths file. That
//!     format has one home, `LibcPaths` in `src/libc_file.zig`: this file
//!     spells none of its fields and repeats none of its layout, because a
//!     second spelling is a second thing to update when Zig changes a parser
//!     this package cannot see.
//!   * A build script cannot `@import` a module it published. The build script
//!     compilation only receives `@build`, `@dependencies`, `root` and `std`
//!     (src/main.zig:5463-5516), so `b.addModule` is a runtime registry for
//!     `dep.module("ndk")` and not a source import. Every NDK path therefore
//!     gets computed by a generated helper that is handed the published module
//!     as an import; this file deliberately knows no NDK layout at all.

const std = @import("std");

/// One NDK ABI and the Zig target query that builds for it.
///
/// These five entries are the gate's enumeration of the ABI set, transcribed
/// from CONTRACT.md §2, which reads NDK r29's own `meta/abis.json`. They are
/// not the library's ABI table and must never be treated as one: the
/// `ndk-link-check` helper re-derives every one of them from the `ndk` module
/// and fails the gate on any disagreement, so the two cannot drift apart
/// silently.
const AbiGate = struct {
    /// NDK ABI name: a `meta/abis.json` key, and the value `ANDROID_ABI` takes.
    /// NOT a path component. `sysroot/usr/lib/` is namespaced by the sysroot
    /// triple, so no `arm64-v8a` or `x86` directory exists anywhere under it;
    /// `triple` below is what a path under `usr/lib` is spelled with.
    name: []const u8,
    /// NDK sysroot triple, which is not a Zig triple.
    triple: []const u8,
    /// Zig C ABI tag for that triple.
    zig_abi: std.Target.Abi,
    /// Zig CPU architecture tag for that triple.
    cpu_arch: std.Target.Cpu.Arch,
    /// Lowest API level the NDK declares for that ABI.
    min_api_level: u32,
    /// ELF `EI_CLASS` value an artefact for this ABI carries, from
    /// `std.elf.CLASS`. `-Dabi=` can select `armeabi-v7a` and `x86`, which are
    /// 32-bit, so the link gate's ELF check takes the class it demands from
    /// here. Writing 64 into the check instead would be a second unearned
    /// pass: `x86` would then be verified against a check written for the
    /// other three, and the gate would be green on a 32-bit `e_machine` it
    /// never looked at.
    elf_class: std.elf.CLASS,
    /// ELF `e_machine` value an artefact for this ABI carries, from
    /// `std.elf.EM`. This one separates a bionic binary for a different ABI
    /// from the one asked for: those share the magic, the class and the
    /// OS/ABI and differ here.
    ///
    /// It does NOT separate a HOST artefact from an Android one, which is what
    /// this field's doc used to claim. On x86_64 — the ABI this build host is
    /// — a host glibc PIE carries the same `e_machine` (62), `EI_CLASS` (2),
    /// `EI_DATA` (1) and `ELFOSABI_NONE` (0) as a bionic x86_64 binary, and the
    /// link gate accepted one with exit 0. What separates them is after the
    /// header: the Android program interpreter, and a `DT_NEEDED` naming
    /// `libc.so` where glibc names `libc.so.6`. Both are checked now, and
    /// neither is a field here: the soname is one string for all five ABIs and
    /// the interpreter is decided by `elf_class`, which is the field above.
    elf_machine: std.elf.EM,
};

const abi_gates = [_]AbiGate{
    .{
        .name = "armeabi-v7a",
        .triple = "arm-linux-androideabi",
        .zig_abi = .androideabi,
        .cpu_arch = .arm,
        .min_api_level = 21,
        .elf_class = .@"32",
        .elf_machine = .ARM,
    },
    .{
        .name = "arm64-v8a",
        .triple = "aarch64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .aarch64,
        .min_api_level = 21,
        .elf_class = .@"64",
        .elf_machine = .AARCH64,
    },
    .{
        .name = "riscv64",
        .triple = "riscv64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .riscv64,
        .min_api_level = 35,
        .elf_class = .@"64",
        .elf_machine = .RISCV,
    },
    .{
        .name = "x86",
        .triple = "i686-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86,
        .min_api_level = 21,
        .elf_class = .@"32",
        .elf_machine = .@"386",
    },
    .{
        .name = "x86_64",
        .triple = "x86_64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86_64,
        .min_api_level = 21,
        .elf_class = .@"64",
        .elf_machine = .X86_64,
    },
};

/// The five NDK ABI names, for a consumer that iterates every ABI.
pub const abi_names = blk: {
    var names: [abi_gates.len][]const u8 = undefined;
    for (abi_gates, 0..) |gate, i| names[i] = gate.name;
    break :blk names;
};

/// Discovery order from CONTRACT.md D3, first hit wins.
///
/// `ANDROID_NDK_HOME` is first because Google's own CMake toolchain prefers it,
/// so it is the least surprising variable for a user who set it deliberately.
/// The order is duplicated here, outside the library, on purpose: the refusal
/// message CONTRACT.md D3 requires has to name every source it tried, and only
/// this file can print it. `Ndk.find` walks the same list for library callers.
const ndk_env_vars = [_][]const u8{
    "ANDROID_NDK_HOME",
    "ANDROID_NDK_ROOT",
    "ANDROID_NDK",
};

/// ABI the link gate uses when `-Dabi=` is not given: `aarch64-linux-android`
/// at API 35, the exact combination proven against NDK r29 in CONTRACT.md §1.
const default_link_abi = "arm64-v8a";

/// API level the link gate uses when `-Dapi=` is not given.
const default_link_api_level: u32 = 35;

/// Lowest API level a bionic link can carry in `Debug` or `ReleaseSafe`, for
/// every ABI.
///
/// Measured, not guessed. bionic gained `preadv64` and `pwritev64` at API 24,
/// and Zig's default panic handler reaches `std.Io.Threaded`, which calls both,
/// so a `Debug` build below 24 resolves the NDK wiring perfectly and then fails
/// in `ld.lld` with `undefined symbol: preadv64` and a note offering
/// `pread64` — naming a substitute symbol, and neither `-Dapi` nor
/// `-Doptimize`, because neither is what the reader has to change to make it
/// link. A floor nobody can see is a floor nobody can obey. See
/// `AndroidLinkOptions.api_level`, which is where the measurement is recorded.
const min_link_api_level: u32 = 24;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----------------------------------------------------------------------
    // Published module.
    //
    // Registered with b.addModule so `b.dependency("zig_ndk", …).module("ndk")`
    // resolves. No target and no optimize: CONTRACT.md §4 makes the consumer
    // responsible for both, and a value pinned here is a value the consumer
    // cannot override.
    // ----------------------------------------------------------------------
    const ndk_module = b.addModule("ndk", .{
        .root_source_file = b.path("root.zig"),
    });

    // ----------------------------------------------------------------------
    // Build options.
    //
    // b.option returns `?T`, so the declared type is the payload type. Passing
    // `?[]const u8` would be a compile error: Build.typeToEnum (Build.zig:1617)
    // switches on `@typeInfo(T)` for `.int/.float/.bool/.@"enum"/.pointer` and
    // has no `.optional` arm.
    // ----------------------------------------------------------------------
    // The usage strings are one line each on purpose: `zig build --help` prints
    // them verbatim, and an indented multi-line literal leaks its own source
    // indentation into the help output.
    const ndk_option = b.option(
        []const u8,
        "ndk",
        "Unpacked Android NDK root, the directory holding source.properties and toolchains/. Overrides ANDROID_NDK_HOME, ANDROID_NDK_ROOT and ANDROID_NDK.",
    );
    const abi_option = b.option(
        []const u8,
        "abi",
        "NDK ABI name (a meta/abis.json key, the value ANDROID_ABI takes) the ndk-link-check gate links for: armeabi-v7a, arm64-v8a, riscv64, x86 or x86_64. Not a sysroot directory: usr/lib is namespaced by triple. Defaults to arm64-v8a.",
    );
    const api_option = b.option(
        u32,
        "api",
        "Android API level the ndk-link-check gate links for. Defaults to 35. The sysroot must ship usr/lib/<triple>/<api>.",
    );

    // ----------------------------------------------------------------------
    // Gate: unit tests.
    //
    // Rooted at root.zig so the package's published surface is what is
    // compiled and run, and so any `test` block the sources add is picked up
    // without a second file to keep in sync.
    //
    // The target is `target.result`, NOT `b.graph.host`, and that is the whole
    // point of the branch below. Pinning the host here made
    // `zig build test -Dtarget=wasm32-wasi` compile for x86_64-linux, print
    // "compiles the tests for wasm32 and does not run them", and exit 0: a
    // green gate that cross-compiled nothing, which is the same unearned pass
    // as the `-fno-emit-bin` case above. A consumer wiring a foreign
    // `-Dtarget` as a compile-only gate gets what it asked for or a failure.
    // `standardTargetOptions` resolves to the host when `-Dtarget` is absent,
    // so the default run is unchanged.
    // ----------------------------------------------------------------------
    const host_tests = b.addTest(.{
        .name = "ndk-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_host_tests = b.addRunArtifact(host_tests);
    // A test runner declares no output arguments, so without this the step is
    // cached away on the second build and the tests silently stop running.
    run_host_tests.has_side_effects = true;

    const test_step = b.step("test", "Run the host unit tests");
    if (target.query.isNative()) {
        test_step.dependOn(&run_host_tests.step);
    } else {
        // `-Dtarget=aarch64-linux-android` produces a binary this host cannot
        // execute. Compile it — for that target, not for the host — and say
        // plainly that it was not run rather than failing on a foreign
        // executable.
        test_step.dependOn(&host_tests.step);
        // The whole resolved triple, not the CPU architecture alone:
        // `wasm32-wasi` and `wasm32-freestanding` print identically as "wasm32",
        // so a reader could not tell which target they got or reproduce the
        // run they are looking at.
        const wanted = b.fmt("{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        });
        const here = b.fmt("{s}-{s}", .{
            @tagName(b.graph.host.result.cpu.arch),
            @tagName(b.graph.host.result.os.tag),
        });
        std.log.warn(
            "-Dtarget is not native: `zig build test` compiles the tests for {s} " ++
                "and does not run them, because this host ({s}) cannot execute " ++
                "that target. Re-run the same cross build with -Dtarget={s}.",
            .{ wanted, here, wanted },
        );
    }

    // The integration test imports the library the way a consumer does, so it
    // gets the published module under the same name. It is wired only when
    // the file is present, and the absence is reported, so a missing file can
    // never read as "the integration tests passed".
    if (fileExists(b, "test/integration_test.zig")) {
        const integration_module = b.createModule(.{
            .root_source_file = b.path("test/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_module.addImport("ndk", ndk_module);

        const integration_tests = b.addTest(.{
            .name = "ndk-integration-tests",
            .root_module = integration_module,
        });
        const run_integration_tests = b.addRunArtifact(integration_tests);
        run_integration_tests.has_side_effects = true;

        if (target.query.isNative()) {
            test_step.dependOn(&run_integration_tests.step);
        } else {
            test_step.dependOn(&integration_tests.step);
        }
    } else {
        std.log.warn(
            "test/integration_test.zig is not present: `zig build test` is running " ++
                "only the root.zig tests, and the consumer-shaped integration test " ++
                "is not being compiled. Check that build.zig.zon's `.paths` lists " ++
                "`test/`, or that this checkout has the whole directory: the cause " ++
                "is always a `.paths` omission or a partial checkout, and a " ++
                "package fetched without `test/` silently runs fewer tests than it " ++
                "reports.",
            .{},
        );
    }

    // ----------------------------------------------------------------------
    // Gate: per-ABI cross compile.
    //
    // Each ABI gets its own `std.Target.Query` and its own test binary. These
    // are compiled and never run: an Android binary cannot execute on the
    // build host, and running one would prove nothing this gate is about.
    // ----------------------------------------------------------------------
    const abi_check_step = b.step("ndk-abi-check", "Resolve a target query and compile the package for every NDK ABI");
    for (abi_gates) |gate| {
        const abi_test = b.addTest(.{
            .name = b.fmt("ndk-{s}", .{gate.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("root.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = gate.cpu_arch,
                    .os_tag = .linux,
                    .abi = gate.zig_abi,
                    .android_api_level = gate.min_api_level,
                }),
                .optimize = optimize,
            }),
        });
        abi_check_step.dependOn(&abi_test.step);
    }

    // ----------------------------------------------------------------------
    // Gate: the bionic link.
    //
    // Everything here is conditional on an NDK having been found, and its
    // refusal is a `Step.Fail` carrying the full list of sources tried. A
    // consumer with no NDK, and CI without one, must still be able to run
    // `test`, `ndk-abi-check` and `check`, so a missing NDK must not abort
    // configuration.
    // ----------------------------------------------------------------------
    const link_check_step = b.step("ndk-link-check", "Link a bionic Android executable against a real NDK sysroot");

    link_check: {
        const abi_name = abi_option orelse default_link_abi;
        const api_level = api_option orelse default_link_api_level;

        const gate = gateFor(abi_name) orelse {
            const refuse = std.Build.Step.Fail.create(b, b.fmt(
                \\`ndk-link-check` was asked for the NDK ABI '{s}', which is
                \\not one of the five ABIs this gate knows:
                \\
                \\  {s}
                \\
                \\Pass one of those names to -Dabi=, for example
                \\
                \\  zig build ndk-link-check -Dabi=arm64-v8a
                \\
                \\Those five names live in one place, `abi_names` in
                \\this package's build half, reached as `zig_ndk.abi_names`
                \\from a dependent's build script and as `zig_ndk.Abi` at run time.
                \\A `linkAndroid` caller that gets `error.UnsupportedAbi` is
                \\looking at the same five.
                \\
            , .{ abi_name, joinGateNames(b) }));
            link_check_step.dependOn(&refuse.step);
            break :link_check;
        };

        // Before the NDK is looked for, and not after: an API level and an
        // optimization mode are the reader's own two flags, while a missing
        // NDK is a fact about their machine. Whichever fires first should be
        // the one they can act on without looking anything up. `linkAndroid`
        // refuses the same pair with `error.ApiBelowLinkFloor`, so the library
        // and this gate cannot answer differently.
        if (linksBelowApiFloor(api_level, optimize, gate)) {
            const refuse = std.Build.Step.Fail.create(
                b,
                apiBelowFloorMessage(b, "ndk-link-check", api_level, optimize, gate),
            );
            link_check_step.dependOn(&refuse.step);
            break :link_check;
        }

        const resolved_root = resolveNdkRoot(b, ndk_option) catch |err| switch (err) {
            // Before the discovery walk, and refused on its own: no `-Dndk`
            // value and no environment variable can conjure an NDK package
            // Google does not publish for this machine, so the four-source
            // message below would send the reader through four sources that
            // cannot possibly resolve.
            error.UnsupportedHost => {
                const refuse = std.Build.Step.Fail.create(b, unsupportedHostMessage(b, "ndk-link-check"));
                link_check_step.dependOn(&refuse.step);
                break :link_check;
            },
            error.NdkNotFound => {
                const refuse = std.Build.Step.Fail.create(
                    b,
                    ndkNotFoundMessage(b, "ndk-link-check", ndk_option),
                );
                link_check_step.dependOn(&refuse.step);
                break :link_check;
            },
        };
        const ndk_root = resolved_root.path;

        const link_target = b.resolveTargetQuery(.{
            .cpu_arch = gate.cpu_arch,
            .os_tag = .linux,
            .abi = gate.zig_abi,
            .android_api_level = api_level,
        });

        // The artefact is named for the ABI AND the API it was built for.
        // A fixed name meant a matrix run over five ABIs resolved all five to
        // one path in `zig-out/bin`, each overwriting the last, so the tree
        // left behind was whichever ran last and said nothing about the other
        // four. That is an evidential defect rather than a false green — the
        // readback below still checked every artefact — but four documents
        // point at that path as the evidence, and it could not carry it. With
        // the ABI and API in the name, `zig-out/` IS the coverage record.
        const link_artefact_name = b.fmt("ndk-link-check-{s}-api{d}", .{ gate.name, api_level });
        const link_exe = b.addExecutable(.{
            .name = link_artefact_name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.addWriteFiles().add(
                    "ndk_link_check_main.zig",
                    link_check_main_source,
                ),
                .target = link_target,
                .optimize = optimize,
            }),
        });

        // The libc paths file is produced by a helper that imports the
        // published module, so the paths come from `Ndk.libcDirFor` and the
        // text from `LibcPaths.render` — not from a second copy of the NDK
        // layout, or of the file format, living in this file.
        _ = linkAndroid(b, ndk_module, link_exe, .{
            .ndk = ndk_root,
            .abi = gate.name,
            .api_level = api_level,
            .optimize = optimize,
            .check_abi_gates = true,
        }) catch |err| switch (err) {
            // Named in full rather than left to `{t}`: this one is a misuse of
            // this package's API and not a configuration problem, and a bare
            // error name reads as the latter. The gate below wires exactly one
            // compilation exactly once, so this arm states the contract a
            // consumer copies rather than a path it can reach today.
            error.AlreadyLinked => {
                const refuse = std.Build.Step.Fail.create(b,
                    \\`ndk-link-check` wired one compilation twice, which
                    \\linkAndroid refuses with error.AlreadyLinked:
                    \\
                    \\Compile.setLibCFile is last-call-wins, so a second call
                    \\silently replaces the sysroot the compile is linked
                    \\against. Wire one compilation once.
                    \\
                );
                link_check_step.dependOn(&refuse.step);
                break :link_check;
            },
            // One arm, and no `else`. Each of these five was already decided
            // above, on these same values, before this call: the ABI name
            // against `abi_gates`, the API level and optimization mode
            // against `min_link_api_level`, the root against the discovery
            // order, and the target query against that same `abi_gates` row.
            // There is no reader mistake left to explain, so what this arm
            // says is what IS true — zig-ndk's own two decisions
            // disagree — rather than a bare error name that reads as a
            // configuration problem the reader caused.
            //
            // The exhaustiveness is the point, and it is why there is no
            // catch-all: the day `linkAndroid` grows another error, this
            // switch stops compiling here, which is the first place that needs
            // to know. The arm that was `else` printed `{t}` and nothing else,
            // in a build with no NDK diagnostics at all.
            error.NdkNotFound,
            error.UnsupportedHost,
            error.UnsupportedAbi,
            error.ApiBelowLinkFloor,
            error.OptimizeMismatch,
            error.TargetIsNotAndroid,
            => {
                const refuse = std.Build.Step.Fail.create(b, b.fmt(
                    \\`ndk-link-check` reached a refusal it had already passed: {t}
                    \\
                    \\  linkAndroid decided {t} again, on the values this gate
                    \\  checked above and passed in. That is zig-ndk's own
                    \\  wiring disagreeing with itself, not a configuration
                    \\  problem in the invocation: the ABI name was matched
                    \\  against abi_gates, the API level and -Doptimize against
                    \\  min_link_api_level, the root against the D3
                    \\  discovery order, and the target query against the same
                    \\  abi_gates row, all before this call.
                    \\
                , .{ err, err }));
                link_check_step.dependOn(&refuse.step);
                break :link_check;
            },
        };

        // Installing is what makes the binary exist. Until something asks for
        // the artefact, `Step.Compile` is handed `-fno-emit-bin`
        // (Step/Compile.zig:1406) and the compile succeeds without emitting
        // anything at all. It also puts the executable where a reader can look
        // at it, `zig-out/bin/ndk-link-check`, instead of only inside a hash
        // directory in the cache.
        const install_link = b.addInstallArtifact(link_exe, .{});
        link_check_step.dependOn(&install_link.step);

        // The part of the gate that can fail. A green build step is not a
        // proof, so the installed file is read back and checked as the ELF it
        // was asked to be. Magic bytes alone would not do: `\x7fELF` opens
        // every ELF on every OS and every architecture, so a host executable,
        // or a bionic binary for the wrong ABI, would pass it and turn a
        // silent regression of the ABI wiring below into a green gate. The
        // ELF class and machine come from the same `AbiGate` entry that chose
        // the target query above, so nothing here is hardcoded in the checker
        // and `-Dabi=` decides both.
        const elf_check = b.addExecutable(.{
            .name = "ndk-elf-check",
            .root_module = b.createModule(.{
                .root_source_file = b.addWriteFiles().add("ndk_elf_check.zig", elf_check_source),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        const run_elf_check = b.addRunArtifact(elf_check);
        run_elf_check.addArgs(&.{
            "--abi",     gate.name,
            "--class",   b.fmt("{d}", .{@intFromEnum(gate.elf_class)}),
            "--machine", b.fmt("{d}", .{@intFromEnum(gate.elf_machine)}),
        });
        // The WHOLE table, not just this row, and for a reason: the checker
        // validates its two expectation values against these rows, so the set
        // of pairs it accepts is the one `abi_gates` holds. A set of five
        // pairs written into the checker's own source would be a second table,
        // which is the failure this gate exists to make impossible.
        addGateRows(b, run_elf_check);
        // The path is the last argument, after the flags, the way the libc
        // paths helper takes its output path.
        run_elf_check.addArg(b.getInstallPath(
            install_link.dest_dir orelse .bin,
            install_link.dest_sub_path,
        ));
        // This run's argument is a path somebody else produced, not an output
        // argument of this run, so the build runner is free to cache the run
        // away and stop checking. See AGENTS.md §3 trap 2.
        run_elf_check.has_side_effects = true;
        run_elf_check.step.dependOn(&install_link.step);
        link_check_step.dependOn(&run_elf_check.step);
    }

    // ----------------------------------------------------------------------
    // Gate: the pinned NDK facts.
    //
    // tools/sync-ndk.sh is the only thing in this repository that notices when
    // the pin in tools/ndk.sha256 or the ABI table src/ndk.zig copied out of
    // the NDK stops describing the NDK, and nothing else here can: the NDK
    // does not announce that it moved, `ndk-abi-check` compiles the table this
    // package holds — so a stale table still compiles — and `ndk-link-check`
    // links against whatever sysroot is on disk, so a stale pin still links.
    // Before this step the enforcer existed in the form and void in the force.
    //
    // `tools/` is in build.zig.zon's `.paths`, so a consumer who fetches this
    // package HAS the script — but their build must not run it. This is this
    // repository's gate on its own pinned facts: a dependent has no NDK, and
    // has no business re-checking or rewriting somebody else's pin. So it is
    // wired into `all` and nothing else, and in particular NOT into `check`,
    // which is the CI gate and stays green with no NDK. Do not helpfully hang
    // this off `check`.
    //
    // The NDK root is resolved here, by `resolveNdkRoot`, and handed over as
    // `--ndk`. That is the same resolver, the same precedence and the same
    // four-source refusal `ndk-link-check` uses, so one mental model covers
    // both gates, and `-Dndk=` is honoured rather than silently ignored. The
    // script carries its own copy of that discovery order and would use it
    // when `--ndk` is absent (tools/sync-ndk.sh:269-300); naming the resolved
    // root makes the two agree by construction rather than by agreement. The
    // child inherits the runner's environment unchanged
    // (Step/Run.zig:1241-1244), so NDK_ZIP and the three ANDROID_NDK_*
    // variables reach the script on every route.
    //
    // The exit status is the gate. See the `Step.Run` bullet in the header
    // comment for the mechanism: `.inherit` stdio turns a non-zero script exit
    // into a failed step. `Step.Fail`, the other refusal this file uses, is a
    // configure-time message and cannot see a script's exit status at all, so
    // it is the wrong tool for the half of this gate that can fail.
    //
    // `--accept` is unreachable from this step, deliberately. It re-records
    // tools/ndk.sha256, and a build flag that can rewrite a tracked file is a
    // bad idea even for the person who means to use it: re-recording a pin is
    // a human decision made after reading a diff, and no option in this file
    // can be the thing that makes it. `argv` is handed over as an array and
    // never through a shell, so no value of `-Dndk=` can become a flag
    // either — a root called `--accept` is consumed as `--ndk`'s operand.
    // ----------------------------------------------------------------------
    const sync_ndk_step = b.step("sync-ndk", "Run tools/sync-ndk.sh: fail if the pinned NDK facts or the copied ABI table have moved");

    sync_ndk: {
        // The refusal is `ndkNotFoundMessage` reused whole, not a second
        // rendering of the same four sources: two spellings of one discovery
        // order is a second thing to update when it changes. It is rendered
        // with THIS step's name, so the message and the step summary agree:
        // `sync-ndk` used to print a refusal that named `ndk-link-check` three
        // times and offered, as its one copy-pasteable remedy, a step that
        // fails in exactly the same way as the one that had just failed.
        const resolved_root = resolveNdkRoot(b, ndk_option) catch |err| switch (err) {
            error.UnsupportedHost => {
                const refuse = std.Build.Step.Fail.create(b, unsupportedHostMessage(b, "sync-ndk"));
                sync_ndk_step.dependOn(&refuse.step);
                break :sync_ndk;
            },
            error.NdkNotFound => {
                const refuse = std.Build.Step.Fail.create(
                    b,
                    ndkNotFoundMessage(b, "sync-ndk", ndk_option),
                );
                sync_ndk_step.dependOn(&refuse.step);
                break :sync_ndk;
            },
        };
        const ndk_root = resolved_root.path;

        // `bash` by name rather than executing the script directly: the
        // script's own dependency guard requires bash and dies naming it when
        // it is absent (tools/sync-ndk.sh:86-90), and asking for that name is
        // one step earlier than the runner's own exec failure.
        //
        // `b.pathFromRoot`, never a cwd-relative path. When zig-ndk is
        // consumed as a dependency the cwd is the CONSUMER's root, and a
        // relative `tools/sync-ndk.sh` would then be the consumer's file.
        // `pathFromRoot` joins `b.build_root` (Build.zig:1769-1772), which is
        // the directory holding THIS build.zig.
        const run_sync = b.addSystemCommand(&.{ "bash", b.pathFromRoot("tools/sync-ndk.sh") });
        run_sync.addArgs(&.{ "--ndk", ndk_root });
        // Both halves are stated rather than inferred. `.inherit` is the mode
        // std documents as failing on a non-zero exit, which is the property
        // the whole gate rests on, and `has_side_effects` keeps a run with no
        // output argument from being cached away on the second build. The same
        // trap the test runner and the ELF check above set it for.
        run_sync.stdio = .inherit;
        run_sync.has_side_effects = true;
        sync_ndk_step.dependOn(&run_sync.step);
    }

    // ----------------------------------------------------------------------
    // Gate: formatting, and the aggregate steps.
    // ----------------------------------------------------------------------
    const fmt_paths = [_][]const u8{
        "build.zig",
        "build.zig.zon",
        "root.zig",
        "src",
        "test",
        "tools",
    };

    const fmt_step = b.addFmt(.{ .paths = &fmt_paths });
    b.step("fmt", "Format this package's own sources in place")
        .dependOn(&fmt_step.step);

    const fmt_check_step = b.addFmt(.{ .paths = &fmt_paths, .check = true });
    b.step("fmt-check", "Fail if any of this package's sources are unformatted")
        .dependOn(&fmt_check_step.step);

    const check_step = b.step("check", "Run the host unit tests and cross compile every ABI (the CI gate)");
    check_step.dependOn(test_step);
    check_step.dependOn(abi_check_step);

    const all_step = b.step("all", "Run every gate, including the bionic link");
    all_step.dependOn(check_step);
    all_step.dependOn(&fmt_check_step.step);
    all_step.dependOn(link_check_step);
    all_step.dependOn(sync_ndk_step);
}

/// One NDK ABI, as a Zig target query, for `ndk-abi-check` and the link gate.
fn gateFor(name: []const u8) ?AbiGate {
    for (abi_gates) |gate| {
        if (std.mem.eql(u8, gate.name, name)) return gate;
    }
    return null;
}

fn joinGateNames(b: *std.Build) []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(b.allocator);
    for (abi_gates, 0..) |gate, i| {
        if (i != 0) joined.appendSlice(b.allocator, ", ") catch @panic("OOM");
        joined.appendSlice(b.allocator, gate.name) catch @panic("OOM");
    }
    return joined.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The first candidate in CONTRACT.md D3's order that is on disk.
///
/// The walk is `Ndk.find`'s, and it is duplicated here for one reason: D3's
/// refusal message has to name every source and what each one read, and only
/// this file can render the build runner's environment. `Ndk.find` renders
/// nothing, so it cannot discharge that half.
///
/// The duplication copies the rule and not the knowledge, and that is what
/// makes it safe. `Ndk.find` (src/ndk.zig:512-523) returns `error.FileNotFound`
/// out of `resolve` for exactly one reason — the candidate path itself is not
/// there (src/ndk.zig:898-901); every other failure is a decision the caller
/// has to see and stops the walk. "Is this path on disk" is therefore the
/// whole of the selection, and a candidate that exists but is not an NDK
/// stops here exactly as it stops there. Nothing below probes a sysroot, so
/// this file still knows no NDK layout.
///
/// Without the existence test the two answers diverge. With
/// `ANDROID_NDK_HOME=/gone` and `ANDROID_NDK_ROOT=<an unpacked r29>`,
/// `Ndk.find` walks past `/gone` and a library consumer links against r29,
/// while this function handed `/gone` to the generated helper, which refused
/// with `NotAnNdk`: same shell, same package, two answers, and the gate the
/// package is named after was the one that was wrong.
///
/// An explicit `-Dndk` is a PIN and not a candidate, which is the other half of
/// that same agreement. It is this build script's own option, named on a
/// command line by the person running it, so a value that is not there is an
/// error to report rather than a source to walk past, and `Ndk.find` reads the
/// explicit path the same way.
///
/// The host is resolved before the walk, and refused on its own.
/// `error.UnsupportedHost` says Google publishes no NDK package for the
/// machine the build runs on, and that is not a fact about any path.
/// `Ndk.find` calls `Ndk.hostTag` ahead of its candidate loop for the same
/// reason (src/ndk.zig:503). Returning "not found" here instead would send the
/// reader through four sources that cannot resolve, and then blame the four
/// paths for a machine that has no package at all.
fn resolveNdkRoot(b: *std.Build, explicit: ?[]const u8) error{ NdkNotFound, UnsupportedHost }!ResolvedRoot {
    const host_tag = try hostTagDir(b);
    if (explicit) |path| {
        const wanted = trimEnds(path);
        if (wanted.len != 0) return .{ .path = wanted, .host_tag = host_tag };
    }
    for (ndk_env_vars) |name| {
        const value = b.graph.environ_map.get(name) orelse continue;
        if (value.len == 0) continue;
        const wanted = trimEnds(value);
        if (isOnDisk(b, wanted)) return .{ .path = wanted, .host_tag = host_tag };
    }
    return error.NdkNotFound;
}

/// What `resolveNdkRoot` resolved: the root to hand the helper, and the host
/// tag it resolved that root for.
///
/// The tag comes back rather than being recomputed at the point of use, so the
/// value handed to the helper is provably the one the refusal above was decided
/// on rather than a second call that could disagree with it.
const ResolvedRoot = struct {
    path: []const u8,
    host_tag: []const u8,
};

/// The NDK host tag this build host resolves to, by on-disk directory name.
///
/// `Ndk.hostTag`'s rule, spelled here because a build script cannot `@import`
/// the module it publishes: the refusal below is a configure-time message,
/// rendered by `build()` long before the generated helper that CAN import the
/// module exists. The helper re-derives the same answer from the module and is
/// handed this one as `--resolved-host`, so the copy cannot drift: a host this
/// build script maps wrongly fails `ndk-link-check` with a named message
/// instead of being discovered by a reader on the wrong machine.
fn hostTagDir(b: *std.Build) error{UnsupportedHost}![]const u8 {
    const host = b.graph.host.result;
    return switch (host.os.tag) {
        .linux => if (host.cpu.arch == .x86_64)
            "linux-x86_64"
        else
            error.UnsupportedHost,
        .macos => if (host.cpu.arch == .x86_64 or host.cpu.arch == .aarch64)
            "darwin-x86_64"
        else
            error.UnsupportedHost,
        .windows => if (host.cpu.arch == .x86_64)
            "windows-x86_64"
        else
            error.UnsupportedHost,
        else => error.UnsupportedHost,
    };
}

/// The NDK host tags this build script can name, for a refusal that has to say
/// what would have worked.
///
/// Written here rather than read from the module for the reason `hostTagDir`
/// states: a configure-time message has no module to read. Every entry is
/// handed to the helper as `--host-tag`, which compares the list with
/// `std.enums.values(ndk.HostTag)`, so these three strings cannot quietly
/// become four, or become three different three.
const ndk_host_tag_dirs = [_][]const u8{
    "linux-x86_64",
    "darwin-x86_64",
    "windows-x86_64",
};

/// `ndk_host_tag_dirs` on one line, for the one message that mentions them
/// inside a sentence. Build-allocator owned, like every string rendered here.
fn joinHostTagDirs(b: *std.Build) []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(b.allocator);
    for (ndk_host_tag_dirs, 0..) |dir, i| {
        if (i != 0) joined.appendSlice(b.allocator, ", ") catch @panic("OOM");
        joined.appendSlice(b.allocator, dir) catch @panic("OOM");
    }
    return joined.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Whether `api_level` and `optimize` together cannot link at `gate`.
///
/// Deliberately narrow, and deliberately in this order of concerns: only
/// `Debug` and `ReleaseSafe` carry the panic handler that reaches `preadv64`,
/// and only below `min_link_api_level` does bionic lack it. That floor is the
/// API LEVEL and not one ABI's, because the cause is bionic's libc.
///
/// The second half of the comparison is the ABI's OWN floor, and it is not
/// optional. riscv64 declares 35, so a 21-floor guard fires for riscv64 at
/// 21-23 and tells the reader to raise `-Dapi` to 24 — which riscv64 also
/// does not have, so both remedies it names dead-end in `ApiLevelUnavailable`.
/// Suppressing the refusal there hides the one message that would have been
/// right. So the guard fires only below whichever floor is HIGHER: the
/// generic 24, or this ABI's own.
fn linksBelowApiFloor(
    api_level: u32,
    optimize: std.builtin.OptimizeMode,
    gate: AbiGate,
) bool {
    if (api_level >= @max(min_link_api_level, gate.min_api_level)) return false;
    return switch (optimize) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
}

/// Why an API level and an optimization mode cannot be combined, and the two
/// ways out of it.
///
/// Both spellings of both knobs are named, because this message has two
/// audiences. A `zig build` user typed `-Dapi=` and `-Doptimize=`; a
/// `linkAndroid` caller typed `.api_level` and their module's `.optimize` in
/// their own build script, where no `-D` flag of this package exists and
/// cannot be reached at all.
fn apiBelowFloorMessage(
    b: *std.Build,
    step_name: []const u8,
    api_level: u32,
    optimize: std.builtin.OptimizeMode,
    gate: AbiGate,
) []const u8 {
    // An ABI whose own floor is above the generic one gets its own message.
    // The generic text says "bionic gained preadv64 at API 24" and offers
    // `-Dapi=24`, and for riscv64 both are wrong: 24 is below its floor of 35,
    // so the ld.lld transcript it quotes is unreachable and the remedy it
    // prints cannot work. Naming the real floor is the only honest remedy.
    if (gate.min_api_level > min_link_api_level) {
        return b.fmt(
            \\`{s}` was asked for API level {d} in a {s} build, and {s} cannot
            \\link at that level at any optimization mode.
            \\
            \\This ABI's floor is higher than bionic's generic one. r29 declares
            \\{d} as the lowest API level it ships for {s}, so the sysroot has no
            \\usr/lib/{s}/{d} directory to link against:
            \\
            \\  error: no usr/lib/{s}/{d} in this sysroot: ApiLevelUnavailable
            \\
            \\The generic floor this check would otherwise name is API {d}, which
            \\this ABI does not ship either, so that number is no remedy here.
            \\Its real floor:
            \\
            \\  zig build {s} -Dapi={d}
            \\
            \\A `linkAndroid` caller sets the same value as `.api_level` on the
            \\options handed to linkAndroid.
            \\
        , .{
            step_name,
            api_level,
            @tagName(optimize),
            gate.name,
            gate.min_api_level,
            gate.name,
            gate.triple,
            api_level,
            gate.triple,
            api_level,
            min_link_api_level,
            step_name,
            gate.min_api_level,
        });
    }
    return b.fmt(
        \\`{s}` was asked for API level {d} in a {s} build, and no Android NDK
        \\can link that combination at any ABI.
        \\
        \\bionic gained `preadv64` and `pwritev64` at API 24, and Zig's default
        \\panic handler reaches `std.Io.Threaded`, which calls both. Below 24 the
        \\NDK wiring resolves correctly and the link then fails in ld.lld:
        \\
        \\  error: ld.lld: undefined symbol: preadv64
        \\  note: did you mean: pread64
        \\  note: defined in: .../sysroot/usr/lib/{s}/{d}/libc.so
        \\
        \\which names a substitute symbol and neither of the two knobs that
        \\decide it. Two ways out, either one:
        \\
        \\  zig build {s} -Dapi={d} -Doptimize=ReleaseSmall   (or ReleaseFast)
        \\  zig build {s} -Dapi={d}
        \\
        \\A `linkAndroid` caller sets the same two values in their own build
        \\script, where no -D flag exists: `.api_level` on the options handed to
        \\linkAndroid, and `.optimize` on the module being wired.
        \\
    , .{
        step_name,
        api_level,
        @tagName(optimize),
        gate.triple,
        api_level,
        step_name,
        min_link_api_level,
        step_name,
        min_link_api_level,
    });
}

/// Whether a path names something that is there.
///
/// `statFile` and not `access`, and only `FileNotFound` counts as absent: a
/// path that exists and cannot be read is still the candidate `Ndk.find` stops
/// on and hands to `Ndk.open` to refuse by name. Treating that as absent
/// would turn a diagnosable refusal here into a silent fall-through to the
/// next source.
fn isOnDisk(b: *std.Build, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(b.graph.io, path, .{}) catch |err| {
        return err != error.FileNotFound;
    };
    return true;
}

/// The path `Ndk.find` would probe for a value that came from a build option
/// or an environment variable.
///
/// Ends only. `export ANDROID_NDK_HOME=$(cat file)` leaves a trailing newline,
/// and probing the untrimmed value refuses a directory that is sitting right
/// there. Interior whitespace is left alone: a POSIX directory name may
/// legally contain a newline, and refusing one would turn a real path into a
/// refusal. What a diagnostic prints is escaped separately, in
/// `escapeForDisplay`.
fn trimEnds(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

/// Every control byte in a value a shell produced, spelled `\xNN`.
///
/// A newline inside a path is legal and is not something to reject; it is
/// something to render, so the message keeps its own line structure instead of
/// breaking mid-path and showing the reader a path nobody probed. Every other
/// byte passes through, so the path stays readable.
fn escapeForDisplay(b: *std.Build, text: []const u8) []const u8 {
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            out.writer.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
        } else {
            out.writer.writeByte(byte) catch @panic("OOM");
        }
    }
    return out.written();
}

/// One environment source as a refusal message shows it, in the same
/// `(unset)` / `(empty)` vocabulary `explicitOrUnset` uses for the option.
fn envOrUnset(b: *std.Build, name: []const u8) []const u8 {
    const value = b.graph.environ_map.get(name) orelse return "(unset)";
    const trimmed = trimEnds(value);
    if (trimmed.len == 0) return "(empty)";
    return escapeForDisplay(b, trimmed);
}

/// CONTRACT.md D3's refusal, named for the step that printed it.
///
/// `step_name` is a parameter because `sync-ndk` prints this same message from
/// its own step, and three misdirections came of the hard-coded spelling. The
/// first line called this "the libc link gate", which is not the gate that
/// ran; the second named `ndk-link-check` under a step summary that says
/// `sync-ndk`; and the only copy-pasteable line re-ran `ndk-link-check`, a step
/// that fails in exactly the same way as the one that just failed. One
/// message, one spelling, and the remedy names the step the reader just ran.
///
/// The four sources are rendered here rather than by the library because a
/// build script cannot `@import` the module it publishes: this is a
/// configure-time message, printed before any compiled program exists. The
/// library's own rendering of the same walk is `Ndk.describeDiscoveryFailure`,
/// and `Ndk.find` is the code both spellings follow.
fn ndkNotFoundMessage(b: *std.Build, step_name: []const u8, explicit: ?[]const u8) []const u8 {
    return b.fmt(
        \\no Android NDK was found, so `{s}` cannot run.
        \\
        \\`{s}` looks for an NDK in this order and stops at the first
        \\source that is set AND on disk. Each of them read:
        \\
        \\  1. the -Dndk build option           {s}
        \\  2. the ANDROID_NDK_HOME environment {s}
        \\  3. the ANDROID_NDK_ROOT environment {s}
        \\  4. the ANDROID_NDK environment      {s}
        \\
        \\-Dndk is a PIN, not a candidate: you named it on the command line, so
        \\a value that is not there stops the walk instead of handing the turn
        \\to the next source, which is how `Ndk.find` reads the same option. The
        \\three variables are candidates and are walked in order, so a stale
        \\ANDROID_NDK_HOME hands the turn to the next source rather than failing
        \\the gate.
        \\
        \\If every one of those is unset or names nothing on disk, point one of
        \\them at an unpacked NDK, the directory holding `source.properties`
        \\and `toolchains/`:
        \\
        \\  zig build {s} -Dndk=/path/to/android-ndk-r29
        \\
        \\One cause is not a path at all. Google publishes NDK host tags for:
        \\
        \\  {s}
        \\
        \\and for no other host, so on any other build machine no value above
        \\can satisfy this gate. That case is refused before this message is
        \\reached, by its own refusal naming the host it could not resolve.
        \\
    , .{
        step_name,
        step_name,
        explicitOrUnset(b, explicit),
        envOrUnset(b, "ANDROID_NDK_HOME"),
        envOrUnset(b, "ANDROID_NDK_ROOT"),
        envOrUnset(b, "ANDROID_NDK"),
        step_name,
        joinHostTagDirs(b),
    });
}

/// What to do when this build host has no NDK package at all.
///
/// The message `tools/sync-ndk.sh` prints for the same condition
/// (tools/sync-ndk.sh:286-293), because the two refuse the same host for the
/// same reason and a reader who has run both should not learn two vocabularies.
/// No path is offered: `error.UnsupportedHost` is not a claim about any path,
/// so offering one would blame the reader for something they cannot change.
/// That it is unreachable here is structural — this build host is x86_64 Linux,
/// one of the three tags — so the proof for this text is by reading.
fn unsupportedHostMessage(b: *std.Build, step_name: []const u8) []const u8 {
    const host = b.graph.host.result;
    return b.fmt(
        \\this build host has no Android NDK toolchain, so `{s}` cannot run.
        \\
        \\  b.graph.host: {s}-{s}
        \\  (operating system {s}, CPU architecture {s})
        \\
        \\`Ndk.hostTag` refuses this host with error.UnsupportedHost, which no
        \\-Dndk value and no ANDROID_NDK_HOME, ANDROID_NDK_ROOT or ANDROID_NDK
        \\value can fix: it says Google publishes no NDK package with a prebuilt
        \\toolchain for this machine, not that a path you named is wrong. The
        \\host tags this package serves:
        \\
        \\  linux-x86_64
        \\  darwin-x86_64
        \\  windows-x86_64
        \\
        \\Run this gate on a host Google ships an NDK for, or cross the NDK
        \\toolchain by hand.
        \\
    , .{
        step_name,
        @tagName(host.os.tag),
        @tagName(host.cpu.arch),
        @tagName(host.os.tag),
        @tagName(host.cpu.arch),
    });
}

/// Render the `-Dndk` option for the refusal message, in the same
/// `(unset)` / `(empty)` vocabulary `envOrUnset` uses for the environment
/// variables, and trimmed and escaped the same way. A named function rather
/// than an inline `if` because an unannotated `if` expression handed to
/// `b.fmt`'s `anytype` varargs infers `void` for the else branch.
fn explicitOrUnset(b: *std.Build, explicit: ?[]const u8) []const u8 {
    if (explicit) |path| {
        const trimmed = trimEnds(path);
        if (trimmed.len != 0) return escapeForDisplay(b, trimmed);
        return "(empty)";
    }
    return "(unset)";
}

/// Whether a path relative to THIS package's root exists right now.
///
/// Used only to decide whether the integration test is wired in. Every NDK
/// path check goes through the `ndk` module instead, so that this file keeps
/// no NDK layout knowledge at all.
///
/// Resolved against `b.pathFromRoot`, never against the process working
/// directory. When zig-ndk is consumed as a dependency the cwd is the
/// CONSUMER's root, so a cwd-relative probe asks the wrong tree twice over:
/// zig-ndk's own `test/integration_test.zig` is not found and the gate quietly
/// degrades to running less than it claims to, and a consumer who happens to
/// have a file at that same relative path gets THEIR file compiled as
/// zig-ndk's integration test. `b.pathFromRoot` (lib/std/Build.zig:1770) joins
/// `b.build_root`, which is the root of whichever package this build script
/// belongs to. `b.path` is the other primitive and is not interchangeable: it
/// hands out a `LazyPath` this script owns and compiles, which is what the
/// compilations above want, and probing wants a plain path.
fn fileExists(b: *std.Build, sub_path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, b.pathFromRoot(sub_path), .{}) catch return false;
    return true;
}

/// Knobs for `linkAndroid`.
pub const AndroidLinkOptions = struct {
    /// NDK root to use. `null` runs the CONTRACT.md D3 discovery order. The
    /// value is borrowed for the build run; nothing here owns memory.
    ndk: ?[]const u8 = null,
    /// NDK ABI name: a `meta/abis.json` key, `ANDROID_ABI`'s value, and not a
    /// path component — `sysroot/usr/lib/` holds triples. `armeabi-v7a`,
    /// `arm64-v8a`, `riscv64`, `x86` or `x86_64`; anything else is refused
    /// rather than guessed at.
    abi: []const u8 = default_link_abi,
    /// Android API level. The sysroot must ship `usr/lib/<triple>/<api>`.
    ///
    /// Measured floor, not a guess: bionic gained `preadv64`/`pwritev64` at
    /// API 24, and Zig's default panic handler reaches `std.Io.Threaded`,
    /// which calls both. So a `Debug` or `ReleaseSafe` build at 21 resolves the
    /// NDK wiring perfectly and then fails in `ld.lld` with exactly
    /// `undefined symbol: preadv64`. Confirmed on r29: `arm64-v8a` is green at
    /// API 24 and red at 21, and `ReleaseSmall` is green at 21. That is a
    /// property of bionic and of Zig's panic handler, not of the NDK wiring,
    /// which resolves at every level, and it is `min_link_api_level`'s reason
    /// to exist.
    ///
    /// Both ways of spelling the two knobs, because both audiences hit this:
    ///
    ///   * `zig build ndk-link-check -Dapi=21` links at
    ///     `-Doptimize=ReleaseSmall` (or `ReleaseFast`), or at `-Dapi=24` and
    ///     up in any mode.
    ///   * A `linkAndroid` caller sets `.api_level` here and `.optimize` on
    ///     their own module. Neither is a `-D` flag: this package's build
    ///     options do not exist in a dependent's build at all, so a caller
    ///     told to pass `-Dapi=24` is being told to type a flag that cannot be
    ///     typed there.
    ///
    /// The combination that cannot link is refused up front with
    /// `error.ApiBelowLinkFloor` rather than left to the linker.
    api_level: u32 = default_link_api_level,
    /// Optimization mode for the generated paths-file helper, which always
    /// runs on the build host.
    ///
    /// NOT the mode of the Android compilation being wired. That mode lives on
    /// the module, at `compile.root_module.optimize`, and the API floor guard
    /// reads it from there — a value set here cannot change what reaches the
    /// linker, so it cannot decide that guard either.
    ///
    /// It is optional rather than defaulted, because a default here is a claim.
    /// `.Debug` used to be the default, and a caller who set the module to
    /// `.ReleaseSmall` and left this alone was refused with
    /// `error.ApiBelowLinkFloor` for exactly the configuration the refusal's
    /// own text tells them to use — it named `-Doptimize=ReleaseSmall` as the
    /// way out and then refused to take it. `null` means "whatever the module
    /// says", which is the only answer that cannot be wrong.
    ///
    /// A value that DISAGREES with `compile.root_module.optimize` is refused
    /// with `error.OptimizeMismatch`, naming both. Silently preferring either
    /// one would be a side effect the caller did not ask for, and a refusal
    /// that names the disagreement is more honest than a precedence rule
    /// nobody can see.
    optimize: ?std.builtin.OptimizeMode = null,
    /// Opt into the ABI-table cross-check, and only that.
    ///
    /// When true, this build script hands its own `abi_gates` table to the
    /// generated helper, which re-derives every row from the `ndk` module and
    /// refuses the build on any disagreement — so a table that no longer
    /// describes the module fails there rather than silently building for the
    /// wrong ABI. The check exists exactly when a caller claims to hold a
    /// table, and the helper is told so explicitly: with `false` no rows are
    /// passed and no check runs, which is the right answer for a consumer who
    /// has no table of their own and must not be told to go and find one.
    ///
    /// A `pub` field that changes whether a build succeeds, and the default is
    /// the safe one: leaving it `false` skips the check and changes nothing
    /// else about the paths file that is produced. Only this package's own
    /// `ndk-link-check` gate holds a table, so it is the only caller that sets
    /// it.
    check_abi_gates: bool = false,
};

/// The NDK root that was resolved for a configured Android compilation.
///
/// Returned so a caller can name the installation in its own diagnostics.
pub const ResolvedNdk = struct {
    /// The root the build will link against, exactly as supplied by `-Dndk` or
    /// by one of the environment variables. Borrowed, not owned.
    root: []const u8,
    /// The generated libc paths file, rendered by `LibcPaths`. The build
    /// runner owns the cache directory behind it; the slice stays valid for
    /// the whole run.
    libc_file: std.Build.LazyPath,
};

/// Wire `compile` so that it links bionic from a real NDK sysroot.
///
/// Discovery, the libc paths file and the `-lc` requirement are all handled
/// here. `compile.root_module.link_libc` is set, which makes the build runner
/// emit `-lc` (Step/Compile.zig:1355) — without it no bionic symbol is
/// required and the link proves nothing. Set `compile.linkage = .dynamic` too
/// if it is not already; bionic supplies `/system/bin/linker64` as the
/// interpreter through `crtbegin_dynamic.o`.
///
/// No `--sysroot` is passed. `b.sysroot` is a `Build` field, so setting it
/// would leak this NDK into every other compilation in the same build; and the
/// sysroot is fully expressed by the libc paths file, whose CRT directory the
/// ELF linker turns into `-L` on its own (src/link/Elf.zig:1042-1046).
///
/// Refuses on the second call for the same `compile`, with
/// `error.AlreadyLinked`, before it looks at an NDK at all: a caller who
/// wired one compilation twice must be told that, and not handed
/// `NdkNotFound` for a misconfigured NDK instead. The reason is not tidiness.
/// `setLibCFile` assigns `compile.libc_file` unconditionally
/// (Step/Compile.zig:829), so a second call is not an error this compiler
/// reports: it is last-call-wins, and the `ResolvedNdk` this function returns
/// the second time then names one sysroot while the compile line carries the
/// other's `--libc` file. The mismatch surfaces much later, as an undefined
/// symbol out of the linker (`statx`, `copy_file_range`) when the CRT
/// directory's API level and the target's disagree, with nothing in the
/// failure pointing back here. A silent replacement is worse than a wrong
/// one. One compilation, one paths file, one API level.
///
/// Refuses `error.TargetIsNotAndroid` when `compile`'s target is not an Android
/// target for the requested `.abi`, before it touches anything. A bionic
/// sysroot only satisfies one such target, and handing it a host compilation
/// fails in the LINKER with four messages and not one of them names the
/// cause: three `failed to open .../usr/lib/<triple>/<api>/crt1.o:
/// FileNotFound` for CRT files that are present, and `invalid ELF machine
/// type: AARCH64` for the libc.so that is exactly right. A reader sent to the
/// NDK to look for a broken sysroot is being sent to look for the bug in
/// their own build command, so the message here says both sides and says what
/// to change. The compilation is left untouched: this refusal happens before
/// `setLibCFile`, so a caller that catches it can still build the host
/// binary it wanted instead.
///
/// Wiring a compilation is not the same as producing one. The artefact is
/// emitted only once something asks for it — `b.addInstallArtifact`,
/// `b.addRunArtifact`, a caller that consumes it — and until then the build
/// runner passes `-fno-emit-bin` and the compile step succeeds with no output
/// anywhere (Step/Compile.zig:1406). A caller who wants a linked Android
/// binary and never installs or runs it gets a green build and no binary;
/// that is a property of `Step.Compile`, not of this function.
///
/// Returns the generated paths file and the root it was computed from.
pub fn linkAndroid(
    b: *std.Build,
    ndk_module: *std.Build.Module,
    compile: *std.Build.Step.Compile,
    options: AndroidLinkOptions,
) !ResolvedNdk {
    if (compile.libc_file != null) return error.AlreadyLinked;
    // The two refusals that need no filesystem, before anything that does:
    // each is a fact about the two values the caller handed in, so each is
    // answered before it can be masked by an NDK that is missing, a path that
    // is wrong, or a host with no package at all.
    const gate = gateFor(options.abi) orelse return error.UnsupportedAbi;
    // The mode that reaches the linker is the MODULE's, not the option's.
    // `Compile` builds with `root_module.optimize` (lib/std/Build/Module.zig
    // :580, Step/Compile.zig:396), so reading `options.optimize` here decided
    // the guard on a value that never reaches the linker. Both failure
    // directions were reachable: a `.ReleaseSmall` module with the default
    // `.Debug` option was refused for exactly the configuration the refusal's
    // own text offers as the remedy, and a `.Debug` module with a
    // `.ReleaseSmall` option passed the guard and then died in ld.lld with
    // `undefined symbol: preadv64`, which is the one failure this guard exists
    // to refuse up front.
    const module_optimize = compile.root_module.optimize orelse std.builtin.OptimizeMode.Debug;
    if (options.optimize) |claimed| {
        if (claimed != module_optimize) {
            std.log.err(
                \\`linkAndroid` was handed two different optimization modes for
                \\the same compilation: `.optimize` on AndroidLinkOptions says
                \\{s}, and `compile.root_module.optimize` says {s}.
                \\
                \\The module's value is the one that reaches the linker, so the
                \\option cannot be taken as the answer. Leave `.optimize` unset
                \\to take the module's, or set the two to the same value:
                \\
                \\  .optimize = null,                         // use the module's
                \\  .optimize = .ReleaseSmall,                // and set the module
                \\  compile.root_module.optimize = .ReleaseSmall;
                \\
            , .{ @tagName(claimed), @tagName(module_optimize) });
            return error.OptimizeMismatch;
        }
    }
    if (linksBelowApiFloor(options.api_level, module_optimize, gate)) return error.ApiBelowLinkFloor;
    // The target and the sysroot have to be the same Android target, or the
    // linker produces four errors that name a missing file and a bad ELF
    // machine and never name the mismatch. Printed AND returned: a build
    // script that only propagates the error would hand the reader a bare
    // `error.TargetIsNotAndroid` with no path, no triple and no remedy, which
    // is the defect this check exists to remove.
    if (compile.root_module.resolved_target) |target| {
        const compilation = target.result;
        if (compilation.cpu.arch != gate.cpu_arch or compilation.os.tag != .linux or
            compilation.abi != gate.zig_abi)
        {
            std.log.err(
                \\`linkAndroid` cannot wire this compilation: the requested ABI
                \\is {s}, whose sysroot triple is {s}, and the compilation's
                \\target is {s}-{s}-{s}.
                \\
                \\  A bionic sysroot only satisfies an Android target for that ABI.
                \\  Handing it any other target fails in the LINKER with three
                \\  "failed to open .../usr/lib/{s}/{d}/crt1.o: FileNotFound"
                \\  messages for CRT files that are present, plus "invalid ELF
                \\  machine type" for the libc.so that is exactly right — and
                \\  none of those names the cause, which is in this build
                \\  script rather than in the NDK.
                \\
                \\  Set the target before wiring the compilation, so the sysroot
                \\  and the target agree:
                \\
                \\    zig build -Dtarget={s}
                \\
                \\  or, in a build script, on the module the compilation is made
                \\  from:
                \\
                \\    .target = b.resolveTargetQuery(.{{
                \\        .cpu_arch = .{s},
                \\        .os_tag = .linux,
                \\        .abi = .{s},
                \\        .android_api_level = {d},
                \\    }})
                \\
            , .{
                options.abi,
                gate.triple,
                @tagName(compilation.cpu.arch),
                @tagName(compilation.os.tag),
                @tagName(compilation.abi),
                gate.triple,
                options.api_level,
                gate.triple,
                @tagName(gate.cpu_arch),
                @tagName(gate.zig_abi),
                options.api_level,
            });
            return error.TargetIsNotAndroid;
        }
    }

    const resolved = try resolveNdkRoot(b, options.ndk);
    const root = resolved.path;

    const gen = b.addWriteFiles();
    const helper_module = b.createModule(.{
        .root_source_file = gen.add("ndk_libc_file.zig", libc_file_helper_source),
        .target = b.graph.host,
        .optimize = options.optimize orelse std.builtin.OptimizeMode.Debug,
    });
    // The helper is the only thing in the build that may see the published
    // module, and it is the reason this file needs to know no NDK layout.
    helper_module.addImport("ndk", ndk_module);

    const helper = b.addExecutable(.{
        .name = "ndk-libc-file",
        .root_module = helper_module,
    });

    const run_helper = b.addRunArtifact(helper);
    run_helper.addArgs(&.{
        "--ndk", root,
        "--abi", options.abi,
        "--api", b.fmt("{d}", .{options.api_level}),
    });
    // The claim "this build script holds an ABI table" is made EXPLICITLY,
    // because the check is only meaningful when it is true. Without the flag
    // the helper cannot tell a caller with no table from a caller with an
    // empty one, and it read the second as the first: `check_abi_gates`
    // defaulted to false, no rows were passed, and the row-count comparison
    // refused every consumer who took the documented default, with "the build
    // script's ABI table has 0 rows and the zig-ndk module has 5 ABIs" —
    // naming a file the consumer does not have and a table they never
    // claimed. `linkAndroid` with default options now links.
    if (options.check_abi_gates) {
        addGateRows(b, run_helper);
    } else {
        run_helper.addArg("--no-gate-table");
    }
    addHostTagArgs(run_helper, resolved.host_tag);
    // The helper takes its output path as the last argument, because
    // `addPrefixedOutputFileArg` concatenates the prefix and the path with no
    // separator and would produce `--out<path>`.
    const libc_file = run_helper.addOutputFileArg("ndk-libc.txt");

    compile.setLibCFile(libc_file);
    compile.root_module.link_libc = true;

    return .{ .root = root, .libc_file = libc_file };
}

/// The ABI table, one `--gate` row per entry, for either generated program.
///
/// One function for both because the row is a positional seven-tuple: written
/// twice, the two programs could disagree about which field holds the
/// `e_machine`, and the ELF checker would then validate its expectations
/// against a different table than the paths helper validated its rows against.
///
/// Every field of the entry goes over, not a subset: `cpu_arch` decides what
/// gets built and `elf_class`/`elf_machine` decide what the link gate then
/// accepts, so a typo in any of the three has to fail in the check rather than
/// in the one gate that needs an NDK. The helper re-derives all of them from
/// the module and checks the row count as well, so a deleted row fails as
/// loudly as a mistyped one.
fn addGateRows(b: *std.Build, run: *std.Build.Step.Run) void {
    for (abi_gates) |gate| {
        run.addArgs(&.{
            "--gate",
            gate.name,
            gate.triple,
            @tagName(gate.zig_abi),
            b.fmt("{d}", .{gate.min_api_level}),
            @tagName(gate.cpu_arch),
            b.fmt("{d}", .{@intFromEnum(gate.elf_class)}),
            b.fmt("{d}", .{@intFromEnum(gate.elf_machine)}),
        });
    }
}

/// This build script's host tags, and the one it resolved for this host.
///
/// Handed on every run, because a configure-time message cannot read the
/// module and the helper can: the helper compares the list against
/// `std.enums.values(ndk.HostTag)` and the resolved one against
/// `Ndk.hostTag(builtin.target)`. That is what makes `hostTagDir`'s copy of
/// the rule checkable at all.
fn addHostTagArgs(run: *std.Build.Step.Run, resolved: []const u8) void {
    run.addArgs(&.{ "--resolved-host", resolved });
    for (ndk_host_tag_dirs) |dir| {
        run.addArgs(&.{ "--host-tag", dir });
    }
}

/// The program the link gate builds for one ABI.
///
/// It calls `puts`, so `libc.so` has to resolve a symbol the binary really
/// uses. Without that reference `-lc` would be satisfied by an unreferenced
/// shared object and the gate would prove nothing.
const link_check_main_source =
    \\// Generated by zig-ndk's build.zig. Do not edit.
    \\//
    \\// Linked against a real NDK sysroot by `zig build ndk-link-check`. The
    \\// binary cannot run on the build host; the gate is that it links at all,
    \\// against bionic, at the requested API level.
    \\extern fn puts(s: [*:0]const u8) callconv(.c) c_int;
    \\
    \\pub fn main() void {
    \\    _ = puts("zig-ndk");
    \\}
;

/// The program that refuses a link gate which produced the wrong binary, or
/// no binary at all.
///
/// `ndk-link-check` ends in a `Step.Compile`, and a compile that emits nothing
/// is a successful one. This program is the part of the gate that can fail, so
/// it reads the artefact back instead of trusting the step summary.
///
/// `\x7fELF` opens every ELF file on every operating system and every
/// architecture, so a magic check on its own cannot tell a bionic binary for
/// `arm64-v8a` from a host x86-64 executable or from bionic for a different
/// ABI. Both of those are silent regressions of the ABI wiring above, and a
/// gate that cannot see them is not the gate this package needs.
///
/// The header is read far enough to check `EI_CLASS`, `EI_DATA`, `EI_OSABI` and
/// `e_machine`, each against the ABI the gate was asked to build. Those four
/// are NOT enough, and the header alone was not: on x86_64 a host glibc PIE
/// agrees with a bionic one on all four, and this gate accepted one with exit
/// 0. So the file is read WHOLE and two checks past the header are made as
/// well — `PT_INTERP` must name the Android linker for the class, and a
/// `DT_NEEDED` must name `libc.so` where glibc names `libc.so.6`. Neither is a
/// per-ABI field: the soname is one string for all five, and the interpreter
/// follows from the class, which is already tied to the ABI row.
///
/// It prints one line naming the ABI, the class, the machine, the interpreter,
/// the soname and the path when it passes. A gate that says nothing on success
/// leaves no record, which is how a five-ABI matrix run ends with one
/// ambiguous artefact and nothing saying the other four were checked.
///
/// Invoked as
///
///     ndk-elf-check --abi <name> --class <EI_CLASS> --machine <e_machine> <path>
///
/// The three expectation arguments are arguments rather than constants for one
/// reason: `-Dabi=` selects the ABI, and two of the five are 32-bit. The
/// caller fills them from the same `AbiGate` entry that chose the target
/// query, so this program carries no ABI table of its own to drift.
const elf_check_source =
    \\// Generated by zig-ndk's build.zig. Do not edit.
    \\const std = @import("std");
    \\
    \\const magic = "\x7fELF";
    \\
    \\/// `ELFOSABI_NONE`, spelled out so the diagnostics can name it.
    \\const osabi_none: u8 = @intFromEnum(std.elf.OSABI.NONE);
    \\/// `ELFOSABI_ANDROID`, which is 97 (`0x61`). `std.elf.OSABI` has no
    \\/// `ANDROID` member: it spells this same value `ARM` (elf.zig:1700), the
    \\/// ARM EABI slot that Android reuses. Named here under the name the
    \\/// diagnostic has to use.
    \\const osabi_android: u8 = 97;
    \\
    \\const e_ident_len = std.elf.EI.NIDENT;
    \\const e_machine_offset = @offsetOf(std.elf.Elf64.Ehdr, "machine");
    \\/// The FULL header, not `e_ident` plus `e_type` plus `e_machine`.
    \\///
    \\/// This gate used to read twenty bytes and stop, which is exactly why it
    \\/// was blind: `e_machine` cannot separate a host artefact from an Android
    \\/// one on x86_64, because a host x86_64 glibc PIE and a bionic x86_64
    \\/// binary carry the same `e_machine`, `EI_CLASS`, `EI_DATA` and
    \\/// `ELFOSABI_NONE`. Everything that does separate them lives AFTER the
    \\/// header, in the program headers and the dynamic segment. So the whole
    \\/// header is read, and then the file is read whole.
    \\const e_header_len = @sizeOf(std.elf.Elf64.Ehdr);
    \\const e_header_len_32 = @sizeOf(std.elf.Elf32.Ehdr);
    \\/// Upper bound on the artefact this gate will read into memory. A linked
    \\/// Android binary is a few megabytes; 256 MiB is far past any of them and
    \\/// keeps a malformed `e_phoff` from asking for an allocation the size of
    \\/// the machine.
    \\const max_artefact_bytes = 256 * 1024 * 1024;
    \\
    \\comptime {
    \\    // Every index and offset below is taken from `std.elf` rather than
    \\    // written out here, and these are what make that safe: a compiler
    \\    // that moves a field fails to compile this check instead of quietly
    \\    // reading the wrong byte and passing a wrong artefact.
    \\    if (@offsetOf(std.elf.Elf64.Ehdr, "ident") != 0 or
    \\        @offsetOf(std.elf.Elf32.Ehdr, "ident") != 0)
    \\        @compileError("e_ident is no longer the first member of the ELF header");
    \\    // 16 bytes of e_ident and a 16-bit e_type put `e_machine` at 18 in
    \\    // both the 32-bit and the 64-bit header, so one offset serves both
    \\    // classes and the class check does not have to come first.
    \\    if (e_machine_offset != 18 or @offsetOf(std.elf.Elf32.Ehdr, "machine") != 18)
    \\        @compileError("e_machine is no longer at offset 18 of the ELF header");
    \\    if (std.elf.EI.CLASS >= e_ident_len or std.elf.EI.DATA >= e_ident_len or
    \\        std.elf.EI.OSABI >= e_ident_len)
    \\        @compileError("an EI_* index now falls outside e_ident");
    \\    // The program-header walk below reads `e_phoff`, `e_phentsize` and
    \\    // `e_phnum` by offset, so those offsets are pinned too. A moved field
    \\    // has to fail here rather than send the walk off the header.
    \\    if (@offsetOf(std.elf.Elf64.Ehdr, "phoff") != 32 or
    \\        @offsetOf(std.elf.Elf64.Ehdr, "phentsize") != 54 or
    \\        @offsetOf(std.elf.Elf64.Ehdr, "phnum") != 56)
    \\        @compileError("the 64-bit ELF header's program-header fields moved");
    \\    if (@offsetOf(std.elf.Elf32.Ehdr, "phoff") != 28 or
    \\        @offsetOf(std.elf.Elf32.Ehdr, "phentsize") != 42 or
    \\        @offsetOf(std.elf.Elf32.Ehdr, "phnum") != 44)
    \\        @compileError("the 32-bit ELF header's program-header fields moved");
    \\    if (@offsetOf(std.elf.Elf64.Phdr, "type") != 0 or
    \\        @offsetOf(std.elf.Elf64.Phdr, "offset") != 8 or
    \\        @offsetOf(std.elf.Elf64.Phdr, "vaddr") != 16 or
    \\        @offsetOf(std.elf.Elf64.Phdr, "filesz") != 32 or
    \\        @offsetOf(std.elf.Elf32.Phdr, "offset") != 4 or
    \\        @offsetOf(std.elf.Elf32.Phdr, "vaddr") != 8 or
    \\        @offsetOf(std.elf.Elf32.Phdr, "filesz") != 16)
    \\        @compileError("an ELF program header's fields moved");
    \\    if (@offsetOf(std.elf.Elf64_Dyn, "d_tag") != 0 or
    \\        @offsetOf(std.elf.Elf64_Dyn, "d_val") != 8 or
    \\        @offsetOf(std.elf.Elf32_Dyn, "d_tag") != 0 or
    \\        @offsetOf(std.elf.Elf32_Dyn, "d_val") != 4)
    \\        @compileError("an ELF dynamic entry's fields moved");
    \\}
    \\
    \\/// Every refusal this program can make and nothing else, so a reader of
    \\/// the exit status can tell which check fired. Nothing std can fail with
    \\/// leaks in: an IO failure and a failed argument list are both logged
    \\/// with their own message and folded into the one member that means
    \\/// "this run proved nothing".
    \\///
    \\/// Every member carries a message, which is the whole point of the set.
    \\/// The argv is written by build.zig, so a reader of a failure did not
    \\/// type any of it: a member whose name is the entire diagnosis tells
    \\/// them nothing they did not already know, and cannot say which of the
    \\/// three required flags went missing.
    \\const CheckError = error{
    \\        MissingArtefactPath,
    \\        MissingExpectation,
    \\        BadInvocation,
    \\        BadExpectation,
    \\        ExpectationMismatch,
    \\        TruncatedGateRow,
    \\        /// Rendering this program's own diagnostics ran out of memory. The
    \\        /// only allocation that can fail is the argv walk and the two
    \\        /// lists a refusal prints, so it says so rather than folding an
    \\        /// allocation failure into a claim about the artefact.
    \\        OutOfMemory,
    \\        ArtefactUnreadable,
    \\        NotAnElfFile,
    \\        TruncatedElfHeader,
    \\        WrongElfClass,
    \\        WrongElfData,
    \\        WrongElfOsAbi,
    \\        WrongElfMachine,
    \\        // The three that make this gate able to refuse a host artefact.
    \\        // `MissingLibcNeeded` and `WrongElfInterpreter` are the two
    \\        // checks `e_machine` could not make: on x86_64 a host glibc PIE
    \\        // carries the same e_machine, EI_CLASS, EI_DATA and EI_OSABI as a
    \\        // bionic one, so the header alone accepts it and this gate used to.
    \\        //
    \\        // `NotBionic` is the umbrella a future check would use; it is
    \\        // declared so the set keeps naming the class of refusal, and every
    \\        // current bionic check returns the more specific member above it.
    \\        NotBionic,
    \\        TruncatedProgramHeaders,
    \\        NoDynamicSegment,
    \\        UnreadableDynamicString,
    \\        MissingLibcNeeded,
    \\        WrongElfInterpreter,
    \\    };
    \\
    \\pub fn main(init: std.process.Init) CheckError!void {
    \\    const gpa = init.arena.allocator();
    \\    const io = init.io;
    \\
    \\    const args = init.minimal.args.toSlice(gpa) catch |err| {
    \\        std.log.err("this program's own arguments could not be read: {t}", .{err});
    \\        return error.BadInvocation;
    \\    };
    \\    if (args.len < 2) {
    \\        std.log.err(
    \\            "ndk-elf-check was invoked with no path to check. The artefact " ++
    \\                "path is the LAST argument, after the flags:\n  " ++
    \\                "  ndk-elf-check --abi <name> --class <EI_CLASS> " ++
    \\                "--machine <e_machine> [--gate <row>...] <path>",
    \\            .{},
    \\        );
    \\        return error.MissingArtefactPath;
    \\    }
    \\    // The path is last, after the flags: the flags are a fixed set and a
    \\    // path is not, which is the same shape the libc paths helper is
    \\    // invoked in.
    \\    const path = args[args.len - 1];
    \\    const flags = args[1 .. args.len - 1];
    \\
    \\    var abi: []const u8 = "";
    \\    // Integers, never enums, all the way to the diagnostic. `std.elf.CLASS`
    \\    // and `std.elf.EM` are non-exhaustive, and `std.enums.fromInt` on a
    \\    // non-exhaustive enum accepts every integer its tag type holds
    \\    // (std/enums.zig:13-18): `--machine 65535` therefore became an EM
    \\    // value with no tag, and the bare `@tagName` that rendered it
    \\    // panicked with "invalid enum value", a core dump, and no artefact
    \\    // path and no ABI name in the output. Nothing below needs an enum,
    \\    // so nothing below is handed one.
    \\    var want_class: ?u8 = null;
    \\    var want_machine: ?u16 = null;
    \\    // The whole ABI table, not just this run's row. It is what the two
    \\    // expectation values are validated against, and it is the same seven
    \\    // fields in the same order the libc paths helper is handed, so one
    \\    // function writes both.
    \\    var rows: std.ArrayList([7][]const u8) = .empty;
    \\    defer rows.deinit(gpa);
    \\
    \\    var i: usize = 0;
    \\    while (i < flags.len) {
    \\        const flag = flags[i];
    \\        if (std.mem.eql(u8, flag, "--gate")) {
    \\            if (i + 7 >= flags.len) {
    \\                std.log.err(
    \\                    "--gate was given fewer than its seven values. Each " ++
    \\                        "row is seven strings: name, triple, zig-abi, " ++
    \\                        "min-api, cpu-arch, elf-class, elf-machine.",
    \\                    .{},
    \\                );
    \\                return error.TruncatedGateRow;
    \\            }
    \\            try rows.append(gpa, .{
    \\                flags[i + 1],
    \\                flags[i + 2],
    \\                flags[i + 3],
    \\                flags[i + 4],
    \\                flags[i + 5],
    \\                flags[i + 6],
    \\                flags[i + 7],
    \\            });
    \\            i += 8;
    \\            continue;
    \\        }
    \\        if (i + 1 >= flags.len) {
    \\            std.log.err(
    \\                "'{s}' was given with no value. Every flag takes one:\n  " ++
    \\                    "  ndk-elf-check --abi <name> --class <EI_CLASS> " ++
    \\                    "--machine <e_machine> [--gate <row>...] <path>",
    \\                .{flag},
    \\            );
    \\            return error.BadInvocation;
    \\        }
    \\        const value = flags[i + 1];
    \\        if (std.mem.eql(u8, flag, "--abi")) {
    \\            abi = value;
    \\        } else if (std.mem.eql(u8, flag, "--class")) {
    \\            want_class = std.fmt.parseInt(u8, value, 10) catch {
    \\                std.log.err(
    \\                    "--class '{s}' is not an EI_CLASS number. It is the " ++
    \\                        "EI_CLASS byte of the ELF header as a decimal, " ++
    \\                        "1 for ELFCLASS32 or 2 for ELFCLASS64, written " ++
    \\                        "from the AbiGate row the gate built for -Dabi=.",
    \\                    .{value},
    \\                );
    \\                return error.BadExpectation;
    \\            };
    \\        } else if (std.mem.eql(u8, flag, "--machine")) {
    \\            want_machine = std.fmt.parseInt(u16, value, 10) catch {
    \\                std.log.err(
    \\                    "--machine '{s}' is not an e_machine number. It is the " ++
    \\                        "e_machine field of the ELF header as a decimal, " ++
    \\                        "written from the AbiGate row the gate built for " ++
    \\                        "-Dabi=.",
    \\                    .{value},
    \\                );
    \\                return error.BadExpectation;
    \\            };
    \\        } else {
    \\            std.log.err(
    \\                "unrecognised argument '{s}'. This program takes --abi, " ++
    \\                    "--class, --machine and --gate, and the artefact path " ++
    \\                    "last.",
    \\                .{flag},
    \\            );
    \\            return error.BadInvocation;
    \\        }
    \\        i += 2;
    \\    }
    \\
    \\    const expected_class = want_class orelse return missingExpectation("--class");
    \\    const expected_machine = want_machine orelse return missingExpectation("--machine");
    \\    if (abi.len == 0) return missingExpectation("--abi");
    \\    // Before the artefact is opened. An expectation no ABI row carries
    \\    // cannot be checked against anything, and saying so here names the
    \\    // flag and the values that would have been accepted.
    \\    try checkExpectations(gpa, abi, expected_class, expected_machine, rows.items);
    \\
    \\    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
    \\        std.log.err("the link gate installed '{s}', which cannot be read: {t}", .{ path, err });
    \\        return error.ArtefactUnreadable;
    \\    };
    \\    defer file.close(io);
    \\
    \\    // The file is read WHOLE, not just its first twenty bytes. The
    \\    // bionic checks below live in the program headers and the dynamic
    \\    // segment, which is past everything the old header-only read ever
    \\    // looked at, and that is the whole reason it accepted a host glibc
    \\    // binary for x86_64. Read the magic and the header from the front of
    \\    // this buffer rather than from a separate read, so there is one
    \\    // description of where the bytes came from.
    \\    const stat = file.stat(io) catch |err| {
    \\        std.log.err("the link gate installed '{s}', whose size cannot be read: {t}", .{ path, err });
    \\        return error.ArtefactUnreadable;
    \\    };
    \\    if (stat.size > max_artefact_bytes) {
    \\        std.log.err(
    \\            "the link gate installed '{s}', which is {d} bytes: past the " ++
    \\                "{d}-byte ceiling this checker reads, so nothing about it " ++
    \\                "was verified",
    \\            .{ path, stat.size, max_artefact_bytes },
    \\        );
    \\        return error.ArtefactUnreadable;
    \\    }
    \\    const bytes = gpa.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    \\    const read = file.readPositionalAll(io, bytes, 0) catch |err| {
    \\        std.log.err("the link gate installed '{s}', which cannot be read: {t}", .{ path, err });
    \\        return error.ArtefactUnreadable;
    \\    };
    \\    const header = bytes[0..];
    \\
    \\    // The magic check is the one this gate has always made and it stays
    \\    // first, unchanged: a file that is not an ELF at all has nothing else
    \\    // to say, and nothing after it can be trusted to be a header.
    \\    if (read < magic.len or !std.mem.eql(u8, header[0..magic.len], magic)) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which does not begin with " ++
    \\                "the ELF magic: read {d} of 4 bytes, no Android " ++
    \\                "executable was emitted",
    \\            .{ path, @min(read, magic.len) },
    \\        );
    \\        return error.NotAnElfFile;
    \\    }
    \\    const header_len: usize = if (expected_class == 1) e_header_len_32 else e_header_len;
    \\    if (read < header_len) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose {s}-class ELF header ends early: " ++
    \\                "read {d} of the {d} bytes it needs, so no ABI can be read out of it",
    \\            .{
    \\                path,
    \\                className(expected_class),
    \\                read,
    \\                header_len,
    \\            },
    \\        );
    \\        return error.TruncatedElfHeader;
    \\    }
    \\
    \\    const found_class = std.enums.fromInt(std.elf.CLASS, header[std.elf.EI.CLASS]) orelse {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose EI_CLASS is {d}, which is not an ELF class at all",
    \\            .{ path, header[std.elf.EI.CLASS] },
    \\        );
    \\        return error.WrongElfClass;
    \\    };
    \\    if (@intFromEnum(found_class) != expected_class) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which is an ELF{s} file, but -Dabi={s} " ++
    \\                "builds an ELF{s} file: EI_CLASS is {d}, expected {d}",
    \\            .{
    \\                path,
    \\                tagName(std.elf.CLASS, found_class),
    \\                abi,
    \\                className(expected_class),
    \\                @intFromEnum(found_class),
    \\                expected_class,
    \\            },
    \\        );
    \\        return error.WrongElfClass;
    \\    }
    \\
    \\    const found_data = std.enums.fromInt(std.elf.DATA, header[std.elf.EI.DATA]) orelse {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose EI_DATA is {d}, which is not an ELF encoding at all",
    \\            .{ path, header[std.elf.EI.DATA] },
    \\        );
    \\        return error.WrongElfData;
    \\    };
    \\    if (found_data != std.elf.DATA.@"2LSB") {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which is a {s} ELF, but every Android bionic " ++
    \\                "binary is ELFDATA2LSB: EI_DATA is {d}, expected {d}",
    \\            .{
    \\                path,
    \\                tagName(std.elf.DATA, found_data),
    \\                @intFromEnum(found_data),
    \\                @intFromEnum(std.elf.DATA.@"2LSB"),
    \\            },
    \\        );
    \\        return error.WrongElfData;
    \\    }
    \\
    \\    // EI_DATA was just checked as 2LSB, so the two bytes at `e_machine`
    \\    // below are known to be little-endian.
    \\    //
    \\    // On the OS/ABI byte: an Android value is what says the artefact was
    \\    // linked against bionic rather than against another libc. Read off
    \\    // this toolchain's own output, NDK r29's bionic stamps
    \\    // ELFOSABI_NONE, not ELFOSABI_ANDROID — every usr/lib/<triple>/<api>/
    \\    // libc.so for all five ABIs and every API level reads 0 at byte 7, and
    \\    // so does the artefact `zig build ndk-link-check` installs. So 97 alone
    \\    // would refuse the correct binary and leave the gate permanently red,
    \\    // which is the same defect as a gate that never fails: a green run
    \\    // nobody can trust. Both Android values are therefore accepted, and
    \\    // everything else — GNU, which is the glibc value, and the rest — is
    \\    // refused by name. This byte does not separate bionic from glibc on
    \\    // its own; `e_machine` below is what separates a host artefact from
    \\    // an Android one.
    \\    const found_osabi = header[std.elf.EI.OSABI];
    \\    if (found_osabi != osabi_none and found_osabi != osabi_android) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose ELF OS/ABI is {s} ({d}): an NDK bionic " ++
    \\                "link stamps {s} ({d}) or {s} ({d}), and no other value names an Android " ++
    \\                "sysroot, so this artefact was not linked against bionic",
    \\            .{
    \\                path,
    \\                osabiName(found_osabi),
    \\                found_osabi,
    \\                osabiName(osabi_none),
    \\                osabi_none,
    \\                osabiName(osabi_android),
    \\                osabi_android,
    \\            },
    \\        );
    \\        return error.WrongElfOsAbi;
    \\    }
    \\
    \\    const machine_bytes: *const [@sizeOf(std.elf.Half)]u8 = header[e_machine_offset..][0..@sizeOf(std.elf.Half)];
    \\    const found_machine = std.mem.readInt(std.elf.Half, machine_bytes, .little);
    \\    if (found_machine != expected_machine) {
    \\        // `machineName`, not `@tagName`: the expectation is an integer and
    \\        // `std.elf.EM` has no tag for every value it can hold, so the bare
    \\        // call this replaces panicked with "invalid enum value" on a value
    \\        // the same file already knew how to name.
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose e_machine is {s} ({d}), but -Dabi={s} " ++
    \\                "builds {s} ({d}): the artefact is for another architecture than the " ++
    \\                "ABI this gate was asked to link",
    \\            .{
    \\                path,
    \\                machineName(found_machine),
    \\                found_machine,
    \\                abi,
    \\                machineName(expected_machine),
    \\                expected_machine,
    \\            },
    \\        );
    \\        return error.WrongElfMachine;
    \\    }
    \\
    \\    // ------------------------------------------------------------------
    \\    // The bionic checks. These are what `e_machine` cannot do.
    \\    //
    \\    // On x86_64 a host glibc PIE and a bionic x86_64 binary agree on
    \\    // e_machine (62), EI_CLASS (2), EI_DATA (1) and EI_OSABI (0), so
    \\    // everything above passes for both and this gate used to accept the
    \\    // host binary. What separates them is after the header: bionic's
    \\    // soname is `libc.so` and glibc's is `libc.so.6`, and the Android
    \\    // interpreter is under /system/bin while a host one is under the
    \\    // glibc store path. Both are checked, and both are NOT per-ABI: the
    \\    // soname is the same string for all five, and the interpreter is
    \\    // decided by EI_CLASS, which the check above already tied to the ABI
    \\    // row. So nothing here is a second ABI table.
    \\    // ------------------------------------------------------------------
    \\    const is_64 = expected_class == 2;
    \\    const phdr_size: usize = if (is_64) @sizeOf(std.elf.Elf64.Phdr) else @sizeOf(std.elf.Elf32.Phdr);
    \\    const phoff = readField(header, @offsetOf(std.elf.Elf64.Ehdr, "phoff"), @offsetOf(std.elf.Elf32.Ehdr, "phoff"), is_64);
    \\    const phentsize = readHalf(header, @offsetOf(std.elf.Elf64.Ehdr, "phentsize"), @offsetOf(std.elf.Elf32.Ehdr, "phentsize"), is_64);
    \\    const phnum = readHalf(header, @offsetOf(std.elf.Elf64.Ehdr, "phnum"), @offsetOf(std.elf.Elf32.Ehdr, "phnum"), is_64);
    \\    if (phentsize != phdr_size) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose e_phentsize is {d}, not the {d} " ++
    \\                "bytes a {s}-class program header is: the program headers " ++
    \\                "cannot be walked, so nothing after the ELF header was checked",
    \\            .{ path, phentsize, phdr_size, className(expected_class) },
    \\        );
    \\        return error.TruncatedProgramHeaders;
    \\    }
    \\    const phdr_bytes = phnum * phentsize;
    \\    if (phoff + phdr_bytes > bytes.len) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose {d} program headers at offset " ++
    \\                "{d} run past its {d} bytes: they cannot be walked, so nothing " ++
    \\                "after the ELF header was checked",
    \\            .{ path, phnum, phoff, bytes.len },
    \\        );
    \\        return error.TruncatedProgramHeaders;
    \\    }
    \\
    \\    // `PT_INTERP` names the program interpreter, and `PT_DYNAMIC` is where
    \\    // the DT_NEEDED entries live. Both are file offsets, so both can be
    \\    // read straight out of the buffer already in hand.
    \\    var interp: ?[]const u8 = null;
    \\    var dynamic: ?struct { off: u64, len: u64 } = null;
    \\    {
    \\        var ph: u64 = 0;
    \\        while (ph < phnum) : (ph += 1) {
    \\            const at: usize = @intCast(phoff + ph * phentsize);
    \\            const phdr = bytes[at..][0..phentsize];
    \\            const kind = readWord32(phdr, @offsetOf(std.elf.Elf64.Phdr, "type"));
    \\            const off = readField(phdr, @offsetOf(std.elf.Elf64.Phdr, "offset"), @offsetOf(std.elf.Elf32.Phdr, "offset"), is_64);
    \\            const filesz = readField(phdr, @offsetOf(std.elf.Elf64.Phdr, "filesz"), @offsetOf(std.elf.Elf32.Phdr, "filesz"), is_64);
    \\            if (off + filesz > bytes.len) continue;
    \\            const body = bytes[@intCast(off)..][0..@intCast(filesz)];
    \\            if (kind == std.elf.PT_INTERP and interp == null) {
    \\                // The interpreter string is NUL-terminated and `filesz`
    \\                // includes that NUL, so the slice is trimmed rather than
    \\                // trusted to be exact.
    \\                interp = std.mem.trimEnd(u8, body, "\x00");
    \\            } else if (kind == std.elf.PT_DYNAMIC and dynamic == null) {
    \\                dynamic = .{ .off = off, .len = filesz };
    \\            }
    \\        }
    \\    }
    \\
    \\    // Android's own linker, and nothing else. `/system/bin/linker` for the
    \\    // two 32-bit ABIs and `/system/bin/linker64` for the three 64-bit
    \\    // ones, so this is decided by the class the header already committed
    \\    // to above rather than by a per-ABI table this file would have to keep
    \\    // in step with `abi_gates`.
    \\    const want_interp: []const u8 = if (is_64) "/system/bin/linker64" else "/system/bin/linker";
    \\    const got_interp = interp orelse {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which has no PT_INTERP segment: " ++
    \\                "every dynamically linked Android binary is loaded by {s}, " ++
    \\                "and a file with no interpreter is not one",
    \\            .{ path, want_interp },
    \\        );
    \\        return error.WrongElfInterpreter;
    \\    };
    \\    if (!std.mem.eql(u8, got_interp, want_interp)) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose PT_INTERP names '{s}', but " ++
    \\                "-Dabi={s} builds a {s}-class Android binary loaded by {s}: " ++
    \\                "this artefact is not loaded by the Android linker",
    \\            .{ path, got_interp, abi, className(expected_class), want_interp },
    \\        );
    \\        return error.WrongElfInterpreter;
    \\    }
    \\
    \\    // `libc.so` exactly. bionic's soname carries no version suffix and
    \\    // glibc's carries `.6`, so this one string separates the two libcs with
    \\    // no ambiguity and no per-ABI field.
    \\    const want_needed = "libc.so";
    \\    const seg = dynamic orelse {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which has no PT_DYNAMIC segment: " ++
    \\                "a binary linked against {s} always has one, so its " ++
    \\                "DT_NEEDED entries cannot be read and this run proved nothing",
    \\            .{ path, want_needed },
    \\        );
    \\        return error.NoDynamicSegment;
    \\    };
    \\    if (!hasNeeded(bytes, seg.off, seg.len, is_64, want_needed)) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose DT_NEEDED entries do not " ++
    \\                "include {s}: -Dabi={s} builds a binary linked against " ++
    \\                "Android bionic, whose libc soname is {s}. A host binary " ++
    \\                "linked against glibc carries the same e_machine, EI_CLASS, " ++
    \\                "EI_DATA and EI_OSABI on x86_64 and is told apart here",
    \\            .{ path, want_needed, abi, want_needed },
    \\        );
    \\        return error.MissingLibcNeeded;
    \\    }
    \\
    \\    // The one success line. A gate that says nothing when it passes leaves
    \\    // no record, which is how a matrix run over five ABIs ends with one
    \\    // ambiguous artefact and no way to tell the other four were checked.
    \\    std.debug.print(
    \\        "ndk-elf-check: {s} OK: EI_CLASS {d}, e_machine {s} ({d}), " ++
    \\            "PT_INTERP {s}, DT_NEEDED {s}; {s}\n",
    \\        .{ abi, expected_class, machineName(expected_machine), expected_machine, want_interp, want_needed, path },
    \\    );
    \\}
    \\
    \\/// One 32-bit field of an ELF program header, at `at`. `p_type` is 32
    \\/// bits in BOTH classes, so reading it eight bytes wide folds the
    \\/// `p_flags` word into the value and no program header compares equal to
    \\/// the type it carries — which is a program-header walk that finds
    \\/// nothing and then says so about a perfectly good binary.
    \\fn readWord32(buf: []const u8, at: usize) u64 {
    \\        return std.mem.readInt(u32, buf[at..][0..4], .little);
    \\    }
    \\
    \\/// One 16-bit `Half` field of an ELF header, at whichever offset the
    \\/// class puts it.
    \\///
    \\/// Its own reader because these are `Half`: reading them through
    \\/// `readField` takes eight bytes where the field is two, which returns a
    \\/// plausible wrong number rather than failing — an `e_phentsize` of
    \\/// 10414849016987704 is what that reads out of a real Android binary.
    \\/// The offsets differ between the classes as well: `e_phentsize` is 54 in
    \\/// `Elf64.Ehdr` and 42 in `Elf32.Ehdr`, so one offset for both classes
    \\/// reads a zero out of every 32-bit binary this gate is asked about.
    \\fn readHalf(buf: []const u8, off64: usize, off32: usize, is_64: bool) u64 {
    \\        const at = if (is_64) off64 else off32;
    \\        return std.mem.readInt(std.elf.Half, buf[at..][0..2], .little);
    \\    }
    \\
    \\/// One unsigned field of an ELF header or program header, read in
    \\/// whichever width the class implies and from whichever offset it puts
    \\/// the field.
    \\///
    \\/// BOTH offsets are passed rather than one, because the 32-bit and 64-bit
    \\/// layouts place the same field at DIFFERENT offsets: `e_phoff` is 32 in
    \\/// `Elf64.Ehdr` and 28 in `Elf32.Ehdr`, and a program header's `p_offset`
    \\/// is 8 and 4. Reading the 64-bit offset out of a 32-bit file does not
    \\/// fail — it returns a plausible wrong number, and that is how this gate
    \\/// came to believe a real Android binary declared an `e_phentsize` of
    \\/// 10414849016987704.
    \\fn readField(buf: []const u8, off64: usize, off32: usize, is_64: bool) u64 {
    \\        if (is_64) return std.mem.readInt(u64, buf[off64..][0..8], .little);
    \\        return std.mem.readInt(u32, buf[off32..][0..4], .little);
    \\    }
    \\
    \\/// Whether the dynamic segment at `off` carries a `DT_NEEDED` naming
    \\/// exactly `want`.
    \\///
    \\/// A `DT_NEEDED` value is an OFFSET into the string table `DT_STRTAB`
    \\/// points at, and `DT_STRTAB` is a VIRTUAL ADDRESS, so this walks the
    \\/// dynamic entries twice: once to find the string table's address, once
    \\/// to resolve the names. The address becomes a file offset through the
    \\/// `PT_LOAD` segment holding it, which is the one mapping step needed and
    \\/// is why `vaddr` is read at all.
    \\fn hasNeeded(bytes: []const u8, off: u64, len: u64, is_64: bool, want: []const u8) bool {
    \\        const entry_size: usize = if (is_64) @sizeOf(std.elf.Elf64_Dyn) else @sizeOf(std.elf.Elf32_Dyn);
    \\        if (off + len > bytes.len or len < entry_size) return false;
    \\        const seg = bytes[@intCast(off)..][0..@intCast(len)];
    \\
    \\        var strtab_vaddr: ?u64 = null;
    \\        var count: usize = 0;
    \\        while (count + entry_size <= seg.len) : (count += entry_size) {
    \\            const e = seg[count..][0..entry_size];
    \\            const tag = readField(e, @offsetOf(std.elf.Elf64_Dyn, "d_tag"), @offsetOf(std.elf.Elf32_Dyn, "d_tag"), is_64);
    \\            const val = readField(e, @offsetOf(std.elf.Elf64_Dyn, "d_val"), @offsetOf(std.elf.Elf32_Dyn, "d_val"), is_64);
    \\            if (tag == std.elf.DT_NULL) break;
    \\            if (tag == std.elf.DT_STRTAB) strtab_vaddr = val;
    \\        }
    \\        const strtab = strtab_vaddr orelse return false;
    \\        const strtab_off = vaddrToOffset(bytes, strtab, is_64) orelse return false;
    \\
    \\        count = 0;
    \\        while (count + entry_size <= seg.len) : (count += entry_size) {
    \\            const e = seg[count..][0..entry_size];
    \\            const tag = readField(e, @offsetOf(std.elf.Elf64_Dyn, "d_tag"), @offsetOf(std.elf.Elf32_Dyn, "d_tag"), is_64);
    \\            const val = readField(e, @offsetOf(std.elf.Elf64_Dyn, "d_val"), @offsetOf(std.elf.Elf32_Dyn, "d_val"), is_64);
    \\            if (tag == std.elf.DT_NULL) break;
    \\            if (tag != std.elf.DT_NEEDED) continue;
    \\            const name_at = strtab_off + val;
    \\            if (name_at >= bytes.len) continue;
    \\            const rest = bytes[@intCast(name_at)..];
    \\            const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    \\            if (std.mem.eql(u8, rest[0..end], want)) return true;
    \\        }
    \\        return false;
    \\    }
    \\
    \\/// The file offset a virtual address sits at, through the `PT_LOAD`
    \\/// segment that contains it.
    \\fn vaddrToOffset(bytes: []const u8, vaddr: u64, is_64: bool) ?u64 {
    \\        const phoff = readField(bytes, @offsetOf(std.elf.Elf64.Ehdr, "phoff"), @offsetOf(std.elf.Elf32.Ehdr, "phoff"), is_64);
    \\        const phentsize = readHalf(bytes, @offsetOf(std.elf.Elf64.Ehdr, "phentsize"), @offsetOf(std.elf.Elf32.Ehdr, "phentsize"), is_64);
    \\        const phnum = readHalf(bytes, @offsetOf(std.elf.Elf64.Ehdr, "phnum"), @offsetOf(std.elf.Elf32.Ehdr, "phnum"), is_64);
    \\        var i: u64 = 0;
    \\        while (i < phnum) : (i += 1) {
    \\            const at: usize = @intCast(phoff + i * phentsize);
    \\            if (at + phentsize > bytes.len) return null;
    \\            const ph = bytes[at..][0..@intCast(phentsize)];
    \\            if (readWord32(ph, @offsetOf(std.elf.Elf64.Phdr, "type")) != std.elf.PT_LOAD) continue;
    \\            const seg_off = readField(ph, @offsetOf(std.elf.Elf64.Phdr, "offset"), @offsetOf(std.elf.Elf32.Phdr, "offset"), is_64);
    \\            const seg_vaddr = readField(ph, @offsetOf(std.elf.Elf64.Phdr, "vaddr"), @offsetOf(std.elf.Elf32.Phdr, "vaddr"), is_64);
    \\            const seg_filesz = readField(ph, @offsetOf(std.elf.Elf64.Phdr, "filesz"), @offsetOf(std.elf.Elf32.Phdr, "filesz"), is_64);
    \\            if (vaddr < seg_vaddr or vaddr >= seg_vaddr + seg_filesz) continue;
    \\            return seg_off + (vaddr - seg_vaddr);
    \\        }
    \\        return null;
    \\}
    \\
    \\fn tagName(comptime E: type, value: E) []const u8 {
    \\    return std.enums.tagName(E, value) orelse "unnamed";
    \\}
    \\
    \\fn machineName(value: std.elf.Half) []const u8 {
    \\    const tag = std.enums.fromInt(std.elf.EM, value) orelse return "an architecture Zig has no EM name for";
    \\    return tagName(std.elf.EM, tag);
    \\}
    \\
    \\fn osabiName(value: u8) []const u8 {
    \\    if (value == osabi_android) return "ELFOSABI_ANDROID";
    \\    if (value == osabi_none) return "ELFOSABI_NONE";
    \\    const tag = std.enums.fromInt(std.elf.OSABI, value) orelse return "an OS/ABI Zig has no name for";
    \\    return tagName(std.elf.OSABI, tag);
    \\}
    \\    /// `tagName` for a raw EI_CLASS byte, for the same reason the
    \\    /// expectation stays an integer: `std.elf.CLASS` is non-exhaustive and
    \\    /// a bare `@tagName` panics on a value with no tag instead of naming
    \\    /// it.
    \\    fn className(raw: u8) []const u8 {
    \\        const tag = std.enums.fromInt(std.elf.CLASS, raw) orelse return "a class Zig has no name for";
    \\        return tagName(std.elf.CLASS, tag);
    \\    }
    \\    /// The one refusal for a required expectation that was never given,
    \\    /// named so the exit status says WHICH of the three went missing.
    \\    fn missingExpectation(flag: []const u8) CheckError {
    \\        std.log.err(
    \\            "no {s} was given, and all three expectations are required:\n  " ++
    \\                "  ndk-elf-check --abi <name> --class <EI_CLASS> " ++
    \\                "--machine <e_machine> [--gate <row>...] <path>\n" ++
    \\                "  build.zig writes all three from one AbiGate row, so a " ++
    \\                "missing one is a bug in this package's own wiring.",
    \\            .{flag},
    \\        );
    \\        return error.MissingExpectation;
    \\    }
    \\    /// The ABI rows, and the contract `--class` and `--machine` are held
    \\    /// to.
    \\    ///
    \\    /// The rows are the build script's own `abi_gates` entries, so the
    \\    /// accepted set is that table's and not a second list spelled here.
    \\    /// Validating here, before the artefact is opened, is what makes the
    \\    /// panic this replaces unreachable: a class/machine pair that is in
    \\    /// nobody's table has no name in `std.elf.EM` and never reaches a
    \\    /// diagnostic.
    \\    ///
    \\    /// Two refusals, and the second exists because the pair alone is not
    \\    /// enough. `--abi`, `--class` and `--machine` are written from ONE
    \\    /// AbiGate row by one loop in build.zig, so a pair that belongs to a
    \\    /// different row is not a caller's mistake and cannot be reached by
    \\    /// typing arguments: it is this package disagreeing with itself.
    \\    fn checkExpectations(
    \\        gpa: std.mem.Allocator,
    \\        abi: []const u8,
    \\        want_class: u8,
    \\        want_machine: u16,
    \\        rows: []const [7][]const u8,
    \\    ) CheckError!void {
    \\        if (rows.len == 0) {
    \\            std.log.err(
    \\                "no --gate ABI row was passed, so there is nothing to " ++
    \\                    "check the two expectation values against. The rows " ++
    \\                    "ARE the ABI table, and they are the same seven " ++
    \\                    "fields the libc paths helper is handed.",
    \\                .{},
    \\            );
    \\            return error.BadInvocation;
    \\        }
    \\        var in_table = false;
    \\        for (rows) |row| {
    \\            const row_class = std.fmt.parseInt(u8, row[5], 10) catch continue;
    \\            const row_machine = std.fmt.parseInt(u16, row[6], 10) catch continue;
    \\            if (row_class != want_class or row_machine != want_machine) continue;
    \\            in_table = true;
    \\            if (std.mem.eql(u8, row[0], abi)) return;
    \\        }
    \\        if (in_table) {
    \\            std.log.err(
    \\                "--abi={s} with --class={d} and --machine={d} is a " ++
    \\                    "combination no ABI row carries: the table's pairs " ++
    \\                    "are {s}, and the row named {s} is a different pair. " ++
    \\                    "All three arguments are written from ONE AbiGate row " ++
    \\                    "by one loop, so they cannot disagree in a build " ++
    \\                    "anybody else runs: this is zig-ndk's own wiring, " ++
    \\                    "not an argument anyone typed.",
    \\                .{ abi, want_class, want_machine, try pairList(gpa, rows), abi },
    \\            );
    \\            return error.ExpectationMismatch;
    \\        }
    \\        std.log.err(
    \\            "--class={d} with --machine={d} is not an EI_CLASS and " ++
    \\                "e_machine pair any ABI row carries, so this run could " ++
    \\                "have checked nothing. The pairs this build script can " ++
    \\                "ask for: {s}. Pass one of those, with --abi naming the " ++
    \\                "row it belongs to.",
    \\            .{ want_class, want_machine, try pairList(gpa, rows) },
    \\        );
    \\        return error.BadExpectation;
    \\    }
    \\    /// The table's EI_CLASS/e_machine pairs, one per row, for the two
    \\    /// refusals above: a reader told a value is wrong has to be told what
    \\    /// would have been accepted.
    \\    fn pairList(gpa: std.mem.Allocator, rows: []const [7][]const u8) CheckError![]const u8 {
    \\        // The error set is this program's own, and the reason is the
    \\        // writer: an `Allocating` writer fails only by running out of
    \\        // memory, so what comes out of it is `OutOfMemory` and not a
    \\        // `WriteFailed` leaking in from a writer type.
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (rows, 0..) |row, i| {
    \\            if (i != 0) out.writer.print("; ", .{}) catch return error.OutOfMemory;
    \\            out.writer.print("{s} (EI_CLASS {s}, e_machine {s})", .{ row[0], row[5], row[6] }) catch
    \\                return error.OutOfMemory;
    \\        }
    \\        return out.written();
    \\    }
;

/// The program that writes the libc paths file.
///
/// Generated into the build cache and given the published `ndk` module as an
/// import, so every path it writes is computed by `src/ndk.zig` and the file
/// itself is rendered by `ndk.LibcPaths`. It knows no NDK layout and spells no
/// field of the format: both live in the library.
///
/// Invoked as
///
///     ndk-libc-file --ndk <root> --abi <name> --api <level>
///                  [--gate <name> <triple> <zig-abi> <min-api>
///                          <cpu-arch> <elf-class> <elf-machine>]... <out-path>
///
/// The last argument is the file to write. Its layout, its mandatory fields
/// and the comment block above them live in `src/libc_file.zig`, which is the
/// single home for that format in this package. Do not restate them here.
const libc_file_helper_source =
    \\// Generated by zig-ndk's build.zig. Do not edit.
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const ndk = @import("ndk");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const gpa = init.arena.allocator();
    \\    const io = init.io;
    \\
    \\    const args = try init.minimal.args.toSlice(gpa);
    \\    if (args.len < 2) {
    \\        std.log.err(
    \\            "ndk-libc-file was invoked with no output path. The file to " ++
    \\                "write is the LAST argument, after every flag:\n  " ++
    \\                "  ndk-libc-file --ndk <root> --abi <name> --api <level> " ++
    \\                "[--gate <row>...] <out-path>",
    \\            .{},
    \\        );
    \\        return error.MissingOutputPath;
    \\    }
    \\    const out_path = args[args.len - 1];
    \\    const body = args[1 .. args.len - 1];
    \\
    \\    var ndk_root: ?[]const u8 = null;
    \\    var abi_name: ?[]const u8 = null;
    \\    var api_level: u32 = 0;
    \\    var gates: std.ArrayList([7][]const u8) = .empty;
    \\    defer gates.deinit(gpa);
    \\    // "I hold no ABI table" is a claim, and it is made by this flag rather
    \\    // than inferred from an empty row list. An empty list is ambiguous:
    \\    // it is what a caller with no table passes AND what a caller whose
    \\    // table lost every row passes, and reading the second as the first is
    \\    // what made every consumer of the documented default fail on a table
    \\    // they never claimed to have.
    \\    var claims_gate_table = false;
    \\    var resolved_host: ?[]const u8 = null;
    \\    var host_tags: std.ArrayList([]const u8) = .empty;
    \\    defer host_tags.deinit(gpa);
    \\
    \\    var i: usize = 0;
    \\    while (i < body.len) {
    \\        const flag = body[i];
    \\        if (std.mem.eql(u8, flag, "--gate")) {
    \\            if (i + 7 >= body.len) {
    \\                std.log.err(
    \\                    "--gate was given fewer than its seven values. Each row " ++
    \\                        "is seven strings: name, triple, zig-abi, min-api, " ++
    \\                        "cpu-arch, elf-class, elf-machine.",
    \\                    .{},
    \\                );
    \\                return error.TruncatedGate;
    \\            }
    \\            try gates.append(gpa, .{
    \\                body[i + 1],
    \\                body[i + 2],
    \\                body[i + 3],
    \\                body[i + 4],
    \\                body[i + 5],
    \\                body[i + 6],
    \\                body[i + 7],
    \\            });
    \\            claims_gate_table = true;
    \\            i += 8;
    \\            continue;
    \\        }
    \\        if (std.mem.eql(u8, flag, "--no-gate-table")) {
    \\            claims_gate_table = false;
    \\            i += 1;
    \\            continue;
    \\        }
    \\        if (i + 1 >= body.len) {
    \\            std.log.err(
    \\                "'{s}' was given with no value. Every other flag here takes " ++
    \\                    "one: --ndk <root>, --abi <name>, --api <level>, " ++
    \\                    "--host-tag <dir>, --resolved-host <dir>.",
    \\                .{flag},
    \\            );
    \\            return error.MissingValue;
    \\        }
    \\        const value = body[i + 1];
    \\        if (std.mem.eql(u8, flag, "--ndk")) {
    \\            ndk_root = value;
    \\        } else if (std.mem.eql(u8, flag, "--abi")) {
    \\            abi_name = value;
    \\        } else if (std.mem.eql(u8, flag, "--api")) {
    \\            api_level = std.fmt.parseInt(u32, value, 10) catch {
    \\                std.log.err(
    \\                    "--api '{s}' is not an API level. It is a decimal " ++
    \\                        "number: -Dapi=21, -Dapi=30, -Dapi=35, and it must " ++
    \\                        "name a directory under usr/lib/<triple>/.",
    \\                    .{value},
    \\                );
    \\                return error.BadApiLevel;
    \\            };
    \\        } else if (std.mem.eql(u8, flag, "--host-tag")) {
    \\            try host_tags.append(gpa, value);
    \\        } else if (std.mem.eql(u8, flag, "--resolved-host")) {
    \\            resolved_host = value;
    \\        } else {
    \\            std.log.err(
    \\                "unrecognised argument '{s}'. This program takes --ndk, " ++
    \\                    "--abi, --api, --gate, --no-gate-table, --host-tag and " ++
    \\                    "--resolved-host, and the output path last.",
    \\                .{flag},
    \\            );
    \\            return error.BadInvocation;
    \\        }
    \\        i += 2;
    \\    }
    \\
    \\    const root = ndk_root orelse {
    \\        std.log.err(
    \\            "no --ndk was given, so there is no installation to read the " ++
    \\                "sysroot out of:\n  " ++
    \\                "  ndk-libc-file --ndk <root> --abi <name> --api <level> " ++
    \\                "[--gate <row>...] <out-path>",
    \\            .{},
    \\        );
    \\        return error.MissingNdkRoot;
    \\    };
    \\    const wanted = abi_name orelse {
    \\        std.log.err(
    \\            "no --abi was given, so there is no ABI to build a libc paths " ++
    \\                "file for:\n  " ++
    \\                "  ndk-libc-file --ndk <root> --abi <name> --api <level> " ++
    \\                "[--gate <row>...] <out-path>\n" ++
    \\                "  The names are {s}.",
    \\            .{try abiNameList(gpa)},
    \\        );
    \\        return error.MissingAbi;
    \\    };
    \\    const abi = abiByName(wanted) orelse {
    \\        std.log.err(
    \\            "the zig-ndk module has no ABI named '{s}'. The names it does " ++
    \\                "carry are {s}, and that list is `zig_ndk.abi_names` " ++
    \\                "in this package's build half: -Dabi= (and `.abi`) take one " ++
    \\                "of them and nothing else is guessed at.",
    \\            .{ wanted, try abiNameList(gpa) },
    \\        );
    \\        return error.UnsupportedAbi;
    \\    };
    \\
    \\    if (claims_gate_table) {
    \\        try checkGateTable(gates.items);
    \\    } else if (gates.items.len != 0) {
    \\        // Unreachable from this build script, and refused rather than
    \\        // ignored: the two claims contradict each other, so one of them is
    \\        // wrong and the reader needs to know which.
    \\        std.log.err(
    \\            "--no-gate-table and {d} --gate row(s) were both passed. Either " ++
    \\                "claim the ABI table or disown it; both at once is " ++
    \\                "zig-ndk's own wiring, not an argument mistake.",
    \\            .{gates.items.len},
    \\        );
    \\        return error.BadInvocation;
    \\    }
    \\    try checkHostTags(gpa, resolved_host, host_tags.items);
    \\
    \\    const host = ndk.Ndk.hostTag(builtin.target) catch |err| {
    \\        // The same text tools/sync-ndk.sh prints for the same condition
    \\        // (tools/sync-ndk.sh:286-293), because the two refuse the same host
    \\        // for the same reason. No path is offered: this error is not a claim
    \\        // about any path, so offering one would blame the reader for
    \\        // something they cannot change. `build()` refuses this case before
    \\        // it ever gets here, so the proof for this arm is by reading.
    \\        std.log.err(
    \\            "this build host has no Android NDK host tag: {t}\n" ++
    \\                "  builtin.target: {s}-{s}\n" ++
    \\                "Ndk.hostTag() refuses this host with error.UnsupportedHost, " ++
    \\                "which no -Dndk value and no ANDROID_NDK_HOME, " ++
    \\                "ANDROID_NDK_ROOT or ANDROID_NDK value can fix. The tags " ++
    \\                "this package serves:\n{s}" ++
    \\                "Run the build on one of those hosts, or cross the NDK " ++
    \\                "toolchain by hand.",
    \\            .{
    \\                err,
    \\                @tagName(builtin.target.os.tag),
    \\                @tagName(builtin.target.cpu.arch),
    \\                try hostTagList(gpa),
    \\            },
    \\        );
    \\        return err;
    \\    };
    \\    const install = ndk.Ndk.open(gpa, io, root, host) catch |err| {
    \\        // `NotAnNdk` is the union of the three mistakes a caller really
    \\        // makes — a zip, an Android SDK root, an NDK unpacked for another
    \\        // host tag — so the error name alone leaves the reader guessing
    \\        // which one they made. The library exports the half that names
    \\        // the probed paths, so use it rather than re-spelling the two
    \\        // layouts here, where a second copy could disagree with the one
    \\        // that did the probing.
    \\        if (err == error.NotAnNdk) {
    \\            var report: std.Io.Writer.Allocating = .init(gpa);
    \\            ndk.Ndk.describeProbeFailure(gpa, io, root, host, &report.writer) catch {};
    \\            std.log.err(
    \\                "'{s}' does not resolve to an unpacked Android NDK: {t}\n{s}",
    \\                .{ root, err, report.written() },
    \\            );
    \\        } else {
    \\            // NOT a verdict on what the path contains. `Ndk.open` maps only
    \\            // FileNotFound, NotDir and NotAnNdk, so everything that lands
    \\            // here is a filesystem failure reaching this program
    \\            // unclassified: AccessDenied on a tree this user cannot read, or
    \\            // a genuine I/O error on the probe itself. Calling those "not
    \\            // an NDK" states a conclusion nobody reached and sends the
    \\            // reader to unpack an archive that is already unpacked.
    \\            std.log.err(
    \\                "'{s}' could not be probed as an Android NDK: {t}\n" ++
    \\                    "  That is a filesystem failure, not a statement about " ++
    \\                    "what the path contains. Check that the path exists, " ++
    \\                    "that it is a directory rather than a file, and that " ++
    \\                    "this user can read and traverse it.",
    \\                .{ root, err },
    \\            );
    \\        }
    \\        return err;
    \\    };
    \\    const crt_path = ndk.Ndk.libcDirFor(install, gpa, io, abi, api_level) catch |err| switch (err) {
    \\        // Two errors whose remedies are different things, so they get two
    \\        // messages. One message covering both told a reader who asked for
    \\        // an ABI this NDK does not ship to go and change their API level,
    \\        // which cannot help them.
    \\        error.UnsupportedAbi => {
    \\            std.log.err(
    \\                "this NDK ships no usr/lib/{s} at all, so it carries no {s} " ++
    \\                    "ABI: {t}\n" ++
    \\                    "  The whole directory usr/lib/{s} is absent, not one " ++
    \\                    "  level out of it. {s} declares {d} as its lowest API " ++
    \\                    "  level, so this NDK is older than that ABI, or was " ++
    \\                    "  built without it. Change -Dabi= (or `.abi`) to one of " ++
    \\                    "  {s} that this NDK does ship.",
    \\                .{
    \\                    abi.triple(),
    \\                    wanted,
    \\                    err,
    \\                    abi.triple(),
    \\                    wanted,
    \\                    abi.minApiLevel(),
    \\                    try abiNameList(gpa),
    \\                },
    \\            );
    \\            return err;
    \\        },
    \\        error.ApiLevelUnavailable => {
    \\            // The levels that DO exist are one directory read away, and
    \\            // naming them is the whole answer: -Dapi has to be one of them.
    \\            // A refusal that names only the missing directory leaves the
    \\            // reader to go and run `ls` to learn what to type instead.
    \\            const levels = install.apiLevelsFor(gpa, io, abi) catch |list_err| {
    \\                std.log.err(
    \\                    "no usr/lib/{s}/{d} in this sysroot: {t}\n" ++
    \\                        "  The levels this NDK ships for {s} could not be " ++
    \\                        "  listed either: {t}",
    \\                    .{ abi.triple(), api_level, err, wanted, list_err },
    \\                );
    \\                return err;
    \\            };
    \\            std.log.err(
    \\                "no usr/lib/{s}/{d} in this sysroot: {t}\n" ++
    \\                    "  The API levels this NDK ships for {s}:\n{s}" ++
    \\                    "  -Dapi must be one of those, and so must `.api_level`. " ++
    \\                    "Each is a directory under usr/lib/{s} holding that " ++
    \\                    "level's libc.so, libm.so and CRT objects.",
    \\                .{ abi.triple(), api_level, err, wanted, try apiLevelList(gpa, levels), abi.triple() },
    \\            );
    \\            return err;
    \\        },
    \\        else => |other| {
    \\            std.log.err(
    \\                "usr/lib/{s}/{d} could not be resolved in this sysroot: {t}",
    \\                .{ abi.triple(), api_level, other },
    \\            );
    \\            return other;
    \\        },
    \\    };
    \\    const sysroot = install.sysroot();
    \\    const headers_dir = try std.fs.path.join(gpa, &.{ sysroot, "usr", "include" });
    \\
    \\    // CONTRACT.md §2: on Android the system include directory is the same
    \\    // directory as the plain one, because that is where `sys/errno.h`
    \\    // lives. `<sysroot>/usr/include/android` is a real directory with no
    \\    // `sys/` tree, so naming it here would parse and would link, and
    \\    // would still break every consumer that resolves a header through
    \\    // that field. The renderer rejects an empty value, not a wrong one,
    \\    // so only a real check on disk catches this class of mistake.
    \\    try expectPath(io, try std.fs.path.join(gpa, &.{ headers_dir, "stdio.h" }));
    \\    try expectPath(io, try std.fs.path.join(gpa, &.{ headers_dir, "sys", "errno.h" }));
    \\
    \\    // The file's text comes from the library. `forAndroid` copies both
    \\    // directories above into `gpa`, so `paths` owns its three strings and
    \\    // `deinit` is what releases them. The process arena would reclaim
    \\    // them either way; this states who owns them instead of leaving it
    \\    // to be inferred from the allocator.
    \\    var paths = try ndk.LibcPaths.forAndroid(gpa, headers_dir, headers_dir, crt_path);
    \\    defer paths.deinit(gpa);
    \\
    \\    var contents: std.Io.Writer.Allocating = .init(gpa);
    \\    try paths.render(&contents.writer);
    \\    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = contents.written() });
    \\}
    \\
    \\    fn abiByName(name: []const u8) ?ndk.Abi {
    \\        return ndk.Abi.fromName(name);
    \\    }
    \\
    \\fn expectPath(io: std.Io, path: []const u8) !void {
    \\    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
    \\        std.log.err("'{s}' is not in this sysroot: {t}", .{ path, err });
    \\        return err;
    \\    };
    \\}
    \\    /// The five ABI names the module carries, joined for a message that
    \\    /// has to name them. Rendered from `ndk.Abi`, never spelled here, so
    \\    /// the list a refusal prints is the list the lookup above used.
    \\    fn abiNameList(gpa: std.mem.Allocator) ![]const u8 {
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (std.enums.values(ndk.Abi), 0..) |candidate, i| {
    \\            if (i != 0) try out.writer.print(", ", .{});
    \\            try out.writer.print("{s}", .{candidate.name()});
    \\        }
    \\        return out.written();
    \\    }
    \\    /// The host tags this package serves, one per line, indented to read
    \\    /// as a list. Rendered from `ndk.HostTag`, so the list a refusal
    \\    /// prints is the list `Ndk.hostTag` can actually resolve to.
    \\    fn hostTagList(gpa: std.mem.Allocator) ![]const u8 {
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (std.enums.values(ndk.HostTag)) |tag| {
    \\            try out.writer.print("    {s}\n", .{tag.directoryName()});
    \\        }
    \\        return out.written();
    \\    }
    \\    /// The API levels an NDK ships for one ABI, one per line, indented to
    \\    /// read as a list. Already sorted ascending by `apiLevelsFor`.
    \\    fn apiLevelList(gpa: std.mem.Allocator, levels: []const u32) ![]const u8 {
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (levels) |level| {
    \\            try out.writer.print("    {d}\n", .{level});
    \\        }
    \\        return out.written();
    \\    }
    \\
    \\/// Re-derive the build script's ABI table from the module and refuse any
    \\/// disagreement, so the two copies of the layout cannot drift apart
    \\/// without failing the gate.
    \\///
    \\/// Every field of an entry is compared, and so is the row count. Those are
    \\/// the two holes a subset leaves: `cpu_arch` decides what the gate builds
    \\/// and `elf_class`/`elf_machine` decide what the gate then accepts, and a
    \\/// typo in any of the three still compiles — root.zig has no
    \\/// arch-specific code, so `ndk-abi-check` cannot see it — while a
    \\/// deleted row is invisible to a loop over the rows that were handed over.
    \\///
    \\/// The ELF class and machine are not spelled as numbers below. They are
    \\/// derived from the sysroot triple the MODULE publishes, so this is the
    \\/// module's own data answering, and the numbers themselves are `std.elf`'s.
    \\    fn checkGateTable(gates: []const [7][]const u8) !void {
    \\        const expected_rows = std.enums.values(ndk.Abi).len;
    \\        if (gates.len != expected_rows) {
    \\            announceInternalCheck();
    \\            std.log.err(
    \\                "  the table passed via --gate has {d} rows and the zig-ndk module has {d} ABIs",
    \\                .{ gates.len, expected_rows },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        for (gates) |gate| {
    \\            const name = gate[0];
    \\            const abi = abiByName(name) orelse {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': the table lists it, and the zig-ndk module does not have it",
    \\                    .{name},
    \\                );
    \\                return error.GateTableMismatch;
    \\            };
    \\            const min_api_level = std.fmt.parseInt(u32, gate[3], 10) catch {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': minimum API level '{s}' is not a number. Each row " ++
    \\                        "is seven strings and the fourth is a decimal API level.",
    \\                    .{ name, gate[3] },
    \\                );
    \\                return error.BadGate;
    \\            };
    \\            if (!std.mem.eql(u8, abi.triple(), gate[1])) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table triple '{s}', module triple '{s}'",
    \\                    .{ name, gate[1], abi.triple() },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\            if (!std.mem.eql(u8, @tagName(abi.zigAbi()), gate[2])) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table Zig ABI '{s}', module Zig ABI '{s}'",
    \\                    .{ name, gate[2], @tagName(abi.zigAbi()) },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\            if (abi.minApiLevel() != min_api_level) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table minimum API level {d}, module minimum {d}",
    \\                    .{ name, min_api_level, abi.minApiLevel() },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\            // The two refusals below have no remedy to offer, because there
    \\            // is none: an unparsable ELF number in a row this build script
    \\            // wrote. Name the field and the shape anyway, which is the most
    \\            // a reader of the message can do with it.
    \\            const elf_class = std.fmt.parseInt(u8, gate[5], 10) catch {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': EI_CLASS '{s}' is not a number. Each row is seven " ++
    \\                        "strings and the sixth is a decimal EI_CLASS.",
    \\                    .{ name, gate[5] },
    \\                );
    \\                return error.BadGate;
    \\            };
    \\            const elf_machine = std.fmt.parseInt(u16, gate[6], 10) catch {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': e_machine '{s}' is not a number. Each row is seven " ++
    \\                        "strings and the seventh is a decimal e_machine.",
    \\                    .{ name, gate[6] },
    \\                );
    \\                return error.BadGate;
    \\            };
    \\            // `identityForTriple` is a RULE, not a table of answers: it
    \\            // reads the triple the MODULE publishes and works out what that
    \\            // arch must be. Its answers are compared against every row here,
    \\            // so a wrong entry in it fails this check rather than quietly
    \\            // teaching the checker to accept the wrong architecture.
    \\            const identity = identityForTriple(abi.triple()) orelse {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': the module's triple '{s}' names no architecture Zig has an ELF machine for",
    \\                    .{ name, abi.triple() },
    \\                );
    \\                return error.GateTableMismatch;
    \\            };
    \\            if (!std.mem.eql(u8, identity.cpu_arch, gate[4])) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table CPU arch '{s}', module triple '{s}' means '{s}'",
    \\                    .{ name, gate[4], abi.triple(), identity.cpu_arch },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\            if (identity.class != elf_class) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table EI_CLASS {d}, module triple '{s}' means EI_CLASS {d}",
    \\                    .{ name, elf_class, abi.triple(), identity.class },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\            if (identity.machine != elf_machine) {
    \\                announceInternalCheck();
    \\                std.log.err(
    \\                    "  '{s}': table e_machine {d}, module triple '{s}' means e_machine {d}",
    \\                    .{ name, elf_machine, abi.triple(), identity.machine },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\        }
    \\    }
    \\
    \\    /// One line ahead of every detail below, because the refusal that
    \\    /// follows reads like a complaint about the reader's build and is not
    \\    /// one. The only two things that can be wrong are the table that was
    \\    /// passed in and the module it was compared against, and a reader who
    \\    /// reached this can fix neither file. Printed at each refusal rather
    \\    /// than once on entry, so a build whose table AGREES prints nothing.
    \\    fn announceInternalCheck() void {
    \\        std.log.err(
    \\            "zig-ndk internal check, not your build: the ABI table passed " ++
    \\                "via --gate and the ndk module disagree. Only zig-ndk's own " ++
    \\                "build.zig and src/ndk.zig can be at fault, and the row " ++
    \\                "below says which value came from where:",
    \\            .{},
    \\        );
    \\    }
    \\
    \\    /// The host tags this build script claims, checked against the module's.
    \\    ///
    \\    /// `build()` resolves a host tag to a configure-time refusal and cannot
    \\    /// import the module to confirm it, so it spells the rule out
    \\    /// (`hostTagDir`). This is where that copy is checked, on every run,
    \\    /// against the two things it could be wrong about: the LIST of tags,
    \\    /// compared with `std.enums.values(ndk.HostTag)`, and the MAPPING from
    \\    /// this machine to one of them, compared with `Ndk.hostTag` on the very
    \\    /// target the helper was built for. Without it, a fourth tag in
    \\    /// src/ndk.zig or a host mapped to the wrong directory would be found by
    \\    /// a reader on the wrong machine, in a build with no NDK diagnostics at
    \\    /// all.
    \\    fn checkHostTags(gpa: std.mem.Allocator, resolved: ?[]const u8, tags: []const []const u8) !void {
    \\        const module_tags = std.enums.values(ndk.HostTag);
    \\        if (tags.len != module_tags.len) {
    \\            std.log.err(
    \\                "  the build script names {d} NDK host tag(s): {s}; the " ++
    \\                    "zig-ndk module has {d}: {s}",
    \\                .{ tags.len, try joinNames(gpa, tags), module_tags.len, try moduleTagNames(gpa) },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        for (tags, module_tags) |claimed, module_tag| {
    \\            if (!std.mem.eql(u8, claimed, module_tag.directoryName())) {
    \\                std.log.err(
    \\                    "  host tag '{s}' is named by the build script and '{s}' by " ++
    \\                        "the zig-ndk module",
    \\                    .{ claimed, module_tag.directoryName() },
    \\                );
    \\                return error.GateTableMismatch;
    \\            }
    \\        }
    \\        const host = try ndk.Ndk.hostTag(builtin.target);
    \\        const wanted = resolved orelse {
    \\            std.log.err(
    \\                "  no --resolved-host was passed, so the build script's host " ++
    \\                    "mapping cannot be checked against Ndk.hostTag",
    \\                .{},
    \\            );
    \\            return error.BadInvocation;
    \\        };
    \\        if (!std.mem.eql(u8, wanted, host.directoryName())) {
    \\            std.log.err(
    \\                "  the build script resolved this host to '{s}' and Ndk.hostTag " ++
    \\                    "resolves it to '{s}': zig-ndk holds two copies of the " ++
    \\                    "host rule and they disagree, so one of them is wrong",
    \\                .{ wanted, host.directoryName() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\    }
    \\
    \\    /// Names joined with ", " for a message that has to show two lists
    \\    /// side by side.
    \\    fn joinNames(gpa: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (names, 0..) |name, i| {
    \\            if (i != 0) try out.writer.print(", ", .{});
    \\            try out.writer.print("{s}", .{name});
    \\        }
    \\        return out.written();
    \\    }
    \\
    \\    /// The module's own host tags on one line, for the same comparison.
    \\    fn moduleTagNames(gpa: std.mem.Allocator) ![]const u8 {
    \\        var out: std.Io.Writer.Allocating = .init(gpa);
    \\        for (std.enums.values(ndk.HostTag), 0..) |tag, i| {
    \\            if (i != 0) try out.writer.print(", ", .{});
    \\            try out.writer.print("{s}", .{tag.directoryName()});
    \\        }
    \\        return out.written();
    \\    }
    \\
    \\/// The Zig CPU architecture tag, ELF class and `e_machine` that an NDK
    \\/// sysroot triple implies.
    \\///
    \\/// The only NDK-specific knowledge here is that a triple's architecture
    \\/// is its first field and that `i686` is how `x86` spells itself in a
    \\/// sysroot triple while it is `x86` in Zig. Every number is `std.elf`'s,
    \\/// and the triple is the module's.
    \\const ElfIdentity = struct {
    \\    cpu_arch: []const u8,
    \\    class: u8,
    \\    machine: u16,
    \\};
    \\
    \\fn identityForTriple(triple: []const u8) ?ElfIdentity {
    \\    const dash = std.mem.indexOfScalar(u8, triple, '-') orelse return null;
    \\    const arch = triple[0..dash];
    \\    const cpu_arch = if (std.mem.eql(u8, arch, "i686")) "x86" else arch;
    \\    const class: std.elf.CLASS = if (std.mem.eql(u8, cpu_arch, "arm") or
    \\        std.mem.eql(u8, cpu_arch, "x86")) .@"32" else .@"64";
    \\    const machine: std.elf.EM = blk: {
    \\        if (std.mem.eql(u8, cpu_arch, "aarch64")) break :blk .AARCH64;
    \\        if (std.mem.eql(u8, cpu_arch, "arm")) break :blk .ARM;
    \\        if (std.mem.eql(u8, cpu_arch, "x86")) break :blk .@"386";
    \\        if (std.mem.eql(u8, cpu_arch, "x86_64")) break :blk .X86_64;
    \\        if (std.mem.eql(u8, cpu_arch, "riscv64")) break :blk .RISCV;
    \\        return null;
    \\    };
    \\    return .{
    \\        .cpu_arch = cpu_arch,
    \\        .class = @intFromEnum(class),
    \\        .machine = @intFromEnum(machine),
    \\    };
    \\}
    \\
;
