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
    directory: []const u8,
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
    /// `std.elf.EM`. This is the load-bearing one: a host executable, or a
    /// bionic binary for a different ABI, has the right magic and the right
    /// OS/ABI and still fails here.
    elf_machine: std.elf.EM,
};

const abi_gates = [_]AbiGate{
    .{
        .directory = "armeabi-v7a",
        .triple = "arm-linux-androideabi",
        .zig_abi = .androideabi,
        .cpu_arch = .arm,
        .min_api_level = 21,
        .elf_class = .@"32",
        .elf_machine = .ARM,
    },
    .{
        .directory = "arm64-v8a",
        .triple = "aarch64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .aarch64,
        .min_api_level = 21,
        .elf_class = .@"64",
        .elf_machine = .AARCH64,
    },
    .{
        .directory = "riscv64",
        .triple = "riscv64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .riscv64,
        .min_api_level = 35,
        .elf_class = .@"64",
        .elf_machine = .RISCV,
    },
    .{
        .directory = "x86",
        .triple = "i686-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86,
        .min_api_level = 21,
        .elf_class = .@"32",
        .elf_machine = .@"386",
    },
    .{
        .directory = "x86_64",
        .triple = "x86_64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86_64,
        .min_api_level = 21,
        .elf_class = .@"64",
        .elf_machine = .X86_64,
    },
};

/// The five NDK ABI names, for a consumer that iterates every ABI.
pub const abi_directory_names = blk: {
    var names: [abi_gates.len][]const u8 = undefined;
    for (abi_gates, 0..) |gate, i| names[i] = gate.directory;
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
        std.log.warn(
            "-Dtarget is not native: `zig build test` compiles the tests for {s} " ++
                "and does not run them, because this host cannot execute that target.",
            .{@tagName(target.result.cpu.arch)},
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
                "is not being compiled.",
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
            .name = b.fmt("ndk-{s}", .{gate.directory}),
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
            , .{ abi_name, joinGateNames(b) }));
            link_check_step.dependOn(&refuse.step);
            break :link_check;
        };

        const ndk_root = resolveNdkRoot(b, ndk_option) orelse {
            const refuse = std.Build.Step.Fail.create(b, ndkNotFoundMessage(b, ndk_option));
            link_check_step.dependOn(&refuse.step);
            break :link_check;
        };

        const link_target = b.resolveTargetQuery(.{
            .cpu_arch = gate.cpu_arch,
            .os_tag = .linux,
            .abi = gate.zig_abi,
            .android_api_level = api_level,
        });

        const link_exe = b.addExecutable(.{
            .name = "ndk-link-check",
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
            .abi = gate.directory,
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
            else => {
                const refuse = std.Build.Step.Fail.create(b, b.fmt(
                    \\`ndk-link-check` could not be configured: {t}
                    \\
                , .{err}));
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
            "--abi",     gate.directory,
            "--class",   b.fmt("{d}", .{@intFromEnum(gate.elf_class)}),
            "--machine", b.fmt("{d}", .{@intFromEnum(gate.elf_machine)}),
        });
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
        // order is a second thing to update when it changes.
        const ndk_root = resolveNdkRoot(b, ndk_option) orelse {
            const refuse = std.Build.Step.Fail.create(b, ndkNotFoundMessage(b, ndk_option));
            sync_ndk_step.dependOn(&refuse.step);
            break :sync_ndk;
        };

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
fn gateFor(directory: []const u8) ?AbiGate {
    for (abi_gates) |gate| {
        if (std.mem.eql(u8, gate.directory, directory)) return gate;
    }
    return null;
}

fn joinGateNames(b: *std.Build) []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(b.allocator);
    for (abi_gates, 0..) |gate, i| {
        if (i != 0) joined.appendSlice(b.allocator, ", ") catch @panic("OOM");
        joined.appendSlice(b.allocator, gate.directory) catch @panic("OOM");
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
fn resolveNdkRoot(b: *std.Build, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |path| {
        if (path.len != 0 and isOnDisk(b, path)) return path;
    }
    for (ndk_env_vars) |name| {
        const value = b.graph.environ_map.get(name) orelse continue;
        if (value.len == 0) continue;
        if (isOnDisk(b, value)) return value;
    }
    return null;
}

/// Whether `path` names something that is there.
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

fn envOrUnset(b: *std.Build, name: []const u8) []const u8 {
    const value = b.graph.environ_map.get(name) orelse return "(unset)";
    if (value.len == 0) return "(empty)";
    return value;
}

fn ndkNotFoundMessage(b: *std.Build, explicit: ?[]const u8) []const u8 {
    return b.fmt(
        \\no Android NDK was found, so the libc link gate cannot run.
        \\
        \\`ndk-link-check` looks for an NDK in this order and stops at the first
        \\source that is set AND on disk. A source naming a path that is not
        \\there is walked past, the rule `Ndk.find` uses, so a stale
        \\ANDROID_NDK_HOME hands the turn to the next source instead of failing
        \\the gate. Each of them read:
        \\
        \\  1. the -Dndk build option           {s}
        \\  2. the ANDROID_NDK_HOME environment {s}
        \\  3. the ANDROID_NDK_ROOT environment {s}
        \\  4. the ANDROID_NDK environment      {s}
        \\
        \\If every one of those is unset or names nothing on disk, point one of
        \\them at an unpacked NDK, the directory holding `source.properties`
        \\and `toolchains/`:
        \\
        \\  zig build ndk-link-check -Dndk=/path/to/android-ndk-r29
        \\
        \\One cause is not a path at all. Google publishes NDK host tags for
        \\linux-x86_64, darwin-x86_64 and windows-x86_64 and for no others, so
        \\on any other build host no value above can satisfy this gate, and the
        \\refusal a set source gets instead is `UnsupportedHost`, named "this
        \\build host has no NDK toolchain". Run the gate on a host Google ships
        \\a package for, or cross the toolchain yourself.
        \\
    , .{
        explicitOrUnset(explicit),
        envOrUnset(b, "ANDROID_NDK_HOME"),
        envOrUnset(b, "ANDROID_NDK_ROOT"),
        envOrUnset(b, "ANDROID_NDK"),
    });
}

/// Render the `-Dndk` option for the refusal message, in the same
/// `(unset)` / `(empty)` vocabulary `envOrUnset` uses for the environment
/// variables. A named function rather than an inline `if` because an
/// unannotated `if` expression handed to `b.fmt`'s `anytype` varargs infers
/// `void` for the else branch.
fn explicitOrUnset(explicit: ?[]const u8) []const u8 {
    if (explicit) |path| {
        if (path.len != 0) return path;
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
    /// which calls both. So `-Dapi=21` links at `-Doptimize=ReleaseSmall` or
    /// `ReleaseFast` and fails in `Debug` or `ReleaseSafe` with exactly
    /// `undefined symbol: preadv64`. Confirmed on r29: `arm64-v8a` is green at
    /// API 24 and red at 21, and `ReleaseSmall` is green at 21. That is a
    /// property of bionic and of Zig's panic handler, not of the NDK wiring,
    /// which resolves at every level.
    api_level: u32 = default_link_api_level,
    /// Optimization mode for the generated paths-file helper, which always
    /// runs on the build host.
    optimize: std.builtin.OptimizeMode = .Debug,
    /// When true, the helper re-derives every entry of this file's `abi_gates`
    /// table from the `ndk` module and fails the gate on any disagreement.
    /// Only the package's own link gate sets this; a consumer setting it
    /// opts into a check about this package's internals.
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

    const root = resolveNdkRoot(b, options.ndk) orelse return error.NdkNotFound;
    if (gateFor(options.abi) == null) return error.UnsupportedAbi;

    const gen = b.addWriteFiles();
    const helper_module = b.createModule(.{
        .root_source_file = gen.add("ndk_libc_file.zig", libc_file_helper_source),
        .target = b.graph.host,
        .optimize = options.optimize,
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
    if (options.check_abi_gates) {
        for (abi_gates) |gate| {
            // Every field of the entry, not a subset: `cpu_arch` decides what
            // gets built and `elf_class`/`elf_machine` decide what the link
            // gate then accepts, so a typo in any of the three has to fail
            // here rather than in the one gate that needs an NDK. The helper
            // re-derives all of them from the module and checks the row count
            // as well, so a deleted row fails as loudly as a mistyped one.
            run_helper.addArgs(&.{
                "--gate",
                gate.directory,
                gate.triple,
                @tagName(gate.zig_abi),
                b.fmt("{d}", .{gate.min_api_level}),
                @tagName(gate.cpu_arch),
                b.fmt("{d}", .{@intFromEnum(gate.elf_class)}),
                b.fmt("{d}", .{@intFromEnum(gate.elf_machine)}),
            });
        }
    }
    // The helper takes its output path as the last argument, because
    // `addPrefixedOutputFileArg` concatenates the prefix and the path with no
    // separator and would produce `--out<path>`.
    const libc_file = run_helper.addOutputFileArg("ndk-libc.txt");

    compile.setLibCFile(libc_file);
    compile.root_module.link_libc = true;

    return .{ .root = root, .libc_file = libc_file };
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
/// gate that cannot see them is not the gate this package needs. So the
/// header is read far enough to check `EI_CLASS`, `EI_DATA`, `EI_OSABI` and
/// `e_machine` as well, each against the ABI the gate was asked to build.
///
/// Invoked as
///
///     ndk-elf-check --abi <dir> --class <EI_CLASS> --machine <e_machine> <path>
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
    \\/// `e_ident` plus `e_type` plus `e_machine`, and nothing more: this gate
    \\/// reads the header's identity, not the program headers after it.
    \\const e_header_len = e_machine_offset + @sizeOf(std.elf.Half);
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
    \\}
    \\
    \\/// Every refusal this program can make and nothing else, so a reader of
    \\/// the exit status can tell which check fired. Nothing std can fail with
    \\/// leaks in: an IO failure and a failed argument list are both logged
    \\/// with their own message and folded into the one member that means
    \\/// "this run proved nothing".
    \\const CheckError = error{
    \\    MissingArtefactPath,
    \\    MissingExpectation,
    \\    BadInvocation,
    \\    BadExpectation,
    \\    ArtefactUnreadable,
    \\    NotAnElfFile,
    \\    TruncatedElfHeader,
    \\    WrongElfClass,
    \\    WrongElfData,
    \\    WrongElfOsAbi,
    \\    WrongElfMachine,
    \\};
    \\
    \\pub fn main(init: std.process.Init) CheckError!void {
    \\    const gpa = init.arena.allocator();
    \\    const io = init.io;
    \\
    \\    const args = init.minimal.args.toSlice(gpa) catch |err| {
    \\        std.log.err("this program's own arguments could not be read: {t}", .{err});
    \\        return error.BadInvocation;
    \\    };
    \\    if (args.len < 2) return error.MissingArtefactPath;
    \\    // The path is last, after the flags: the flags are a fixed set and a
    \\    // path is not, which is the same shape the libc paths helper is
    \\    // invoked in.
    \\    const path = args[args.len - 1];
    \\    const flags = args[1 .. args.len - 1];
    \\
    \\    var abi: []const u8 = "";
    \\    var want_class: ?std.elf.CLASS = null;
    \\    var want_machine: ?std.elf.EM = null;
    \\
    \\    var i: usize = 0;
    \\    while (i < flags.len) {
    \\        const flag = flags[i];
    \\        if (i + 1 >= flags.len) return error.BadInvocation;
    \\        const value = flags[i + 1];
    \\        if (std.mem.eql(u8, flag, "--abi")) {
    \\            abi = value;
    \\        } else if (std.mem.eql(u8, flag, "--class")) {
    \\            const raw = std.fmt.parseInt(u8, value, 10) catch return error.BadExpectation;
    \\            want_class = std.enums.fromInt(std.elf.CLASS, raw) orelse return error.BadExpectation;
    \\        } else if (std.mem.eql(u8, flag, "--machine")) {
    \\            const raw = std.fmt.parseInt(u16, value, 10) catch return error.BadExpectation;
    \\            want_machine = std.enums.fromInt(std.elf.EM, raw) orelse return error.BadExpectation;
    \\        } else {
    \\            std.log.err("unrecognised argument '{s}'", .{flag});
    \\            return error.BadInvocation;
    \\        }
    \\        i += 2;
    \\    }
    \\
    \\    const expected_class = want_class orelse return error.MissingExpectation;
    \\    const expected_machine = want_machine orelse return error.MissingExpectation;
    \\    if (abi.len == 0) return error.MissingExpectation;
    \\
    \\    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
    \\        std.log.err("the link gate installed '{s}', which cannot be read: {t}", .{ path, err });
    \\        return error.ArtefactUnreadable;
    \\    };
    \\    defer file.close(io);
    \\
    \\    var header: [e_header_len]u8 = undefined;
    \\    const chunks = [_][]u8{&header};
    \\    const read = file.readStreaming(io, &chunks) catch |err| {
    \\        std.log.err("the link gate installed '{s}', which cannot be read: {t}", .{ path, err });
    \\        return error.ArtefactUnreadable;
    \\    };
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
    \\    if (read < e_header_len) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose ELF header ends early: read {d} of " ++
    \\                "the {d} bytes that e_ident, e_type and e_machine need, so no ABI " ++
    \\                "can be read out of it",
    \\            .{ path, read, e_header_len },
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
    \\    if (found_class != expected_class) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which is an ELF{s} file, but -Dabi={s} " ++
    \\                "builds an ELF{s} file: EI_CLASS is {d}, expected {d}",
    \\            .{
    \\                path,
    \\                tagName(std.elf.CLASS, found_class),
    \\                abi,
    \\                tagName(std.elf.CLASS, expected_class),
    \\                @intFromEnum(found_class),
    \\                @intFromEnum(expected_class),
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
    \\    if (found_machine != @intFromEnum(expected_machine)) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', whose e_machine is {s} ({d}), but -Dabi={s} " ++
    \\                "builds {s} ({d}): the artefact is for another architecture than the " ++
    \\                "ABI this gate was asked to link",
    \\            .{
    \\                path,
    \\                machineName(found_machine),
    \\                found_machine,
    \\                abi,
    \\                @tagName(expected_machine),
    \\                @intFromEnum(expected_machine),
    \\            },
    \\        );
    \\        return error.WrongElfMachine;
    \\    }
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
    \\    if (args.len < 2) return error.MissingOutputPath;
    \\    const out_path = args[args.len - 1];
    \\    const body = args[1 .. args.len - 1];
    \\
    \\    var ndk_root: ?[]const u8 = null;
    \\    var abi_directory: ?[]const u8 = null;
    \\    var api_level: u32 = 0;
    \\    var gates: std.ArrayList([7][]const u8) = .empty;
    \\    defer gates.deinit(gpa);
    \\
    \\    var i: usize = 0;
    \\    while (i < body.len) {
    \\        const flag = body[i];
    \\        if (std.mem.eql(u8, flag, "--gate")) {
    \\            if (i + 7 >= body.len) return error.TruncatedGate;
    \\            try gates.append(gpa, .{
    \\                body[i + 1],
    \\                body[i + 2],
    \\                body[i + 3],
    \\                body[i + 4],
    \\                body[i + 5],
    \\                body[i + 6],
    \\                body[i + 7],
    \\            });
    \\            i += 8;
    \\            continue;
    \\        }
    \\        if (i + 1 >= body.len) return error.MissingValue;
    \\        const value = body[i + 1];
    \\        if (std.mem.eql(u8, flag, "--ndk")) {
    \\            ndk_root = value;
    \\        } else if (std.mem.eql(u8, flag, "--abi")) {
    \\            abi_directory = value;
    \\        } else if (std.mem.eql(u8, flag, "--api")) {
    \\            api_level = std.fmt.parseInt(u32, value, 10) catch return error.BadApiLevel;
    \\        } else {
    \\            std.log.err("unrecognised argument '{s}'", .{flag});
    \\            return error.BadInvocation;
    \\        }
    \\        i += 2;
    \\    }
    \\
    \\    const root = ndk_root orelse return error.MissingNdkRoot;
    \\    const wanted = abi_directory orelse return error.MissingAbi;
    \\    const abi = abiByDirectoryName(wanted) orelse {
    \\        std.log.err("the zig-ndk module has no ABI named '{s}'", .{wanted});
    \\        return error.UnsupportedAbi;
    \\    };
    \\
    \\    try checkGateTable(gates.items);
    \\
    \\    const host = ndk.Ndk.hostTag(builtin.target) catch |err| {
    \\        std.log.err("this build host has no NDK toolchain: {t}", .{err});
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
    \\            std.log.err("'{s}' does not resolve to an unpacked Android NDK: {t}", .{ root, err });
    \\        }
    \\        return err;
    \\    };
    \\    const crt_path = ndk.Ndk.libcDirFor(install, gpa, io, abi, api_level) catch |err| {
    \\        std.log.err(
    \\            "no usr/lib/{s}/{d} in this sysroot: {t}",
    \\            .{ abi.triple(), api_level, err },
    \\        );
    \\        return err;
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
    \\fn abiByDirectoryName(name: []const u8) ?ndk.Abi {
    \\    for (std.enums.values(ndk.Abi)) |candidate| {
    \\        if (std.mem.eql(u8, candidate.directoryName(), name)) return candidate;
    \\    }
    \\    return null;
    \\}
    \\
    \\fn expectPath(io: std.Io, path: []const u8) !void {
    \\    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
    \\        std.log.err("'{s}' is not in this sysroot: {t}", .{ path, err });
    \\        return err;
    \\    };
    \\}
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
    \\fn checkGateTable(gates: []const [7][]const u8) !void {
    \\    const expected_rows = std.enums.values(ndk.Abi).len;
    \\    if (gates.len != expected_rows) {
    \\        std.log.err(
    \\            "the build script's ABI table has {d} rows and the zig-ndk module has {d} ABIs",
    \\            .{ gates.len, expected_rows },
    \\        );
    \\        return error.GateTableMismatch;
    \\    }
    \\    for (gates) |gate| {
    \\        const name = gate[0];
    \\        const abi = abiByDirectoryName(name) orelse {
    \\            std.log.err(
    \\                "the build script's ABI table lists '{s}', which the zig-ndk module does not have",
    \\                .{name},
    \\            );
    \\            return error.GateTableMismatch;
    \\        };
    \\        const min_api_level = std.fmt.parseInt(u32, gate[3], 10) catch return error.BadGate;
    \\        if (!std.mem.eql(u8, abi.triple(), gate[1])) {
    \\            std.log.err(
    \\                "'{s}': build script triple '{s}', module triple '{s}'",
    \\                .{ name, gate[1], abi.triple() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (!std.mem.eql(u8, @tagName(abi.zigAbi()), gate[2])) {
    \\            std.log.err(
    \\                "'{s}': build script Zig ABI '{s}', module Zig ABI '{s}'",
    \\                .{ name, gate[2], @tagName(abi.zigAbi()) },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (abi.minApiLevel() != min_api_level) {
    \\            std.log.err(
    \\                "'{s}': build script minimum API level {d}, module minimum {d}",
    \\                .{ name, min_api_level, abi.minApiLevel() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        const elf_class = std.fmt.parseInt(u8, gate[5], 10) catch return error.BadGate;
    \\        const elf_machine = std.fmt.parseInt(u16, gate[6], 10) catch return error.BadGate;
    \\        const identity = identityForTriple(abi.triple()) orelse {
    \\            std.log.err(
    \\                "'{s}': module triple '{s}' names no architecture this build knows",
    \\                .{ name, abi.triple() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        };
    \\        if (!std.mem.eql(u8, identity.cpu_arch, gate[4])) {
    \\            std.log.err(
    \\                "'{s}': build script CPU arch '{s}', module triple '{s}' means '{s}'",
    \\                .{ name, gate[4], abi.triple(), identity.cpu_arch },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (identity.class != elf_class) {
    \\            std.log.err(
    \\                "'{s}': build script EI_CLASS {d}, module triple '{s}' means EI_CLASS {d}",
    \\                .{ name, elf_class, abi.triple(), identity.class },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (identity.machine != elf_machine) {
    \\            std.log.err(
    \\                "'{s}': build script e_machine {d}, module triple '{s}' means e_machine {d}",
    \\                .{ name, elf_machine, abi.triple(), identity.machine },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\    }
    \\}
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
