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

/// One NDK ABI directory and the Zig target query that builds for it.
///
/// These five entries are the gate's enumeration of the ABI set, transcribed
/// from CONTRACT.md §2, which reads NDK r29's own `meta/abis.json`. They are
/// not the library's ABI table and must never be treated as one: the
/// `ndk-link-check` helper re-derives every one of them from the `ndk` module
/// and fails the gate on any disagreement, so the two cannot drift apart
/// silently.
const AbiGate = struct {
    /// NDK ABI directory name, as spelled under `sysroot/usr/lib`.
    directory: []const u8,
    /// NDK sysroot triple, which is not a Zig triple.
    triple: []const u8,
    /// Zig C ABI tag for that triple.
    zig_abi: std.Target.Abi,
    /// Zig CPU architecture tag for that triple.
    cpu_arch: std.Target.Cpu.Arch,
    /// Lowest API level the NDK declares for that ABI.
    min_api_level: u32,
};

const abi_gates = [_]AbiGate{
    .{
        .directory = "armeabi-v7a",
        .triple = "arm-linux-androideabi",
        .zig_abi = .androideabi,
        .cpu_arch = .arm,
        .min_api_level = 21,
    },
    .{
        .directory = "arm64-v8a",
        .triple = "aarch64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .aarch64,
        .min_api_level = 21,
    },
    .{
        .directory = "riscv64",
        .triple = "riscv64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .riscv64,
        .min_api_level = 35,
    },
    .{
        .directory = "x86",
        .triple = "i686-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86,
        .min_api_level = 21,
    },
    .{
        .directory = "x86_64",
        .triple = "x86_64-linux-android",
        .zig_abi = .android,
        .cpu_arch = .x86_64,
        .min_api_level = 21,
    },
};

/// The five NDK ABI directory names, for a consumer that iterates every ABI.
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
    // Registered with b.addModule so `b.dependency("zig-ndk", …).module("ndk")`
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
        "NDK ABI directory name the ndk-link-check gate links for: armeabi-v7a, arm64-v8a, riscv64, x86 or x86_64. Defaults to arm64-v8a.",
    );
    const api_option = b.option(
        u32,
        "api",
        "Android API level the ndk-link-check gate links for. Defaults to 35. The sysroot must ship usr/lib/<triple>/<api>.",
    );

    // ----------------------------------------------------------------------
    // Gate: host unit tests.
    //
    // Rooted at root.zig so the package's published surface is what is
    // compiled and run, and so any `test` block the sources add is picked up
    // without a second file to keep in sync.
    // ----------------------------------------------------------------------
    const host_tests = b.addTest(.{
        .name = "ndk-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("root.zig"),
            .target = b.graph.host,
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
        // execute. Build it so the compile is still proven, and say plainly
        // that it was not run rather than failing on a foreign executable.
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
            .target = b.graph.host,
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
        }) catch |err| {
            const refuse = std.Build.Step.Fail.create(b, b.fmt(
                \\`ndk-link-check` could not be configured: {t}
                \\
            , .{err}));
            link_check_step.dependOn(&refuse.step);
            break :link_check;
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
        // proof, so the installed file is read back and refused unless it is an
        // ELF. A link that emits nothing, or emits something that is not an
        // executable, stops the gate instead of passing it.
        const elf_check = b.addExecutable(.{
            .name = "ndk-elf-check",
            .root_module = b.createModule(.{
                .root_source_file = b.addWriteFiles().add("ndk_elf_check.zig", elf_check_source),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        const run_elf_check = b.addRunArtifact(elf_check);
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

/// Resolve an NDK root using CONTRACT.md D3's order, first hit wins.
///
/// Returns the candidate as the caller supplied it. Nothing is checked for
/// existence here: the layout knowledge belongs to the `ndk` module, and the
/// whole point of the `-Dndk` option is that a caller may point at either the
/// direct NDK layout or the nixpkgs `ndk-bundle` layout.
fn resolveNdkRoot(b: *std.Build, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |path| {
        if (path.len != 0) return path;
    }
    for (ndk_env_vars) |name| {
        const value = b.graph.environ_map.get(name) orelse continue;
        if (value.len != 0) return value;
    }
    return null;
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
        \\source that is set. Each of them read:
        \\
        \\  1. the -Dndk build option           {s}
        \\  2. the ANDROID_NDK_HOME environment {s}
        \\  3. the ANDROID_NDK_ROOT environment {s}
        \\  4. the ANDROID_NDK environment      {s}
        \\
        \\Point one of them at an unpacked NDK, the directory holding
        \\`source.properties` and `toolchains/`:
        \\
        \\  zig build ndk-link-check -Dndk=/path/to/android-ndk-r29
        \\
        \\`zig build test`, `zig build ndk-abi-check` and `zig build check` do
        \\not need an NDK and stay green without one.
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

/// Whether a path relative to the package root exists right now.
///
/// Used only to decide whether the integration test is wired in. Every NDK
/// path check goes through the `ndk` module instead, so that this file keeps
/// no NDK layout knowledge at all.
fn fileExists(b: *std.Build, sub_path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}

/// Knobs for `linkAndroid`.
pub const AndroidLinkOptions = struct {
    /// NDK root to use. `null` runs the CONTRACT.md D3 discovery order. The
    /// value is borrowed for the build run; nothing here owns memory.
    ndk: ?[]const u8 = null,
    /// NDK ABI directory name: `armeabi-v7a`, `arm64-v8a`, `riscv64`, `x86`
    /// or `x86_64`. Anything else is refused rather than guessed at.
    abi: []const u8 = default_link_abi,
    /// Android API level. The sysroot must ship `usr/lib/<triple>/<api>`.
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
/// Call this once per `compile`. Building a second paths-file helper for the
/// same compilation produces duplicate module instances, which Zig 0.16
/// reports as "file exists in modules 'x' and 'x0'".
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
            run_helper.addArgs(&.{
                "--gate",
                gate.directory,
                gate.triple,
                @tagName(gate.zig_abi),
                b.fmt("{d}", .{gate.min_api_level}),
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

/// The program that refuses a link gate which produced no binary.
///
/// `ndk-link-check` ends in a `Step.Compile`, and a compile that emits nothing
/// is a successful one. This program is the part of the gate that can fail, so
/// it reads the artefact back instead of trusting the step summary.
///
/// Invoked as
///
///     ndk-elf-check <installed path of the linked executable>
///
/// A file that is not there fails in `openFile`; a file that is there and is
/// not an ELF fails on its first four bytes. Either way the gate stops.
const elf_check_source =
    \\// Generated by zig-ndk's build.zig. Do not edit.
    \\const std = @import("std");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const gpa = init.arena.allocator();
    \\    const io = init.io;
    \\
    \\    const args = try init.minimal.args.toSlice(gpa);
    \\    if (args.len < 2) return error.MissingArtefactPath;
    \\    const path = args[1];
    \\
    \\    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    \\    defer file.close(io);
    \\
    \\    var magic: [4]u8 = undefined;
    \\    const chunks = [_][]u8{&magic};
    \\    const read = try file.readStreaming(io, &chunks);
    \\    if (read != magic.len or !std.mem.eql(u8, &magic, "\x7fELF")) {
    \\        std.log.err(
    \\            "the link gate produced '{s}', which does not begin with " ++
    \\                "the ELF magic: read {d} of 4 bytes, no Android " ++
    \\                "executable was emitted",
    \\            .{ path, read },
    \\        );
    \\        return error.NotAnElfFile;
    \\    }
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
///     ndk-libc-file --ndk <root> --abi <dir> --api <level>
///                  [--gate <dir> <triple> <zig-abi> <min-api>]... <out-path>
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
    \\    var gates: std.ArrayList([4][]const u8) = .empty;
    \\    defer gates.deinit(gpa);
    \\
    \\    var i: usize = 0;
    \\    while (i < body.len) {
    \\        const flag = body[i];
    \\        if (std.mem.eql(u8, flag, "--gate")) {
    \\            if (i + 4 >= body.len) return error.TruncatedGate;
    \\            try gates.append(gpa, .{
    \\                body[i + 1],
    \\                body[i + 2],
    \\                body[i + 3],
    \\                body[i + 4],
    \\            });
    \\            i += 5;
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
    \\        std.log.err("the zig-ndk module has no ABI whose directory is '{s}'", .{wanted});
    \\        return error.UnsupportedAbi;
    \\    };
    \\
    \\    try checkGateTable(gates.items, wanted);
    \\
    \\    const host = ndk.Ndk.hostTag(builtin.target) catch |err| {
    \\        std.log.err("this build host has no NDK toolchain: {t}", .{err});
    \\        return err;
    \\    };
    \\    const install = ndk.Ndk.open(gpa, io, root, host) catch |err| {
    \\        std.log.err(
    \\            "'{s}' does not resolve to an unpacked Android NDK: {t}",
    \\            .{ root, err },
    \\        );
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
    \\fn checkGateTable(gates: []const [4][]const u8, wanted: []const u8) !void {
    \\    for (gates) |gate| {
    \\        const directory = gate[0];
    \\        const abi = abiByDirectoryName(directory) orelse {
    \\            std.log.err(
    \\                "the build script's ABI table lists '{s}', which the zig-ndk module does not have",
    \\                .{directory},
    \\            );
    \\            return error.GateTableMismatch;
    \\        };
    \\        const min_api_level = std.fmt.parseInt(u32, gate[3], 10) catch return error.BadGate;
    \\        if (!std.mem.eql(u8, abi.triple(), gate[1])) {
    \\            std.log.err(
    \\                "'{s}': build script triple '{s}', module triple '{s}'",
    \\                .{ directory, gate[1], abi.triple() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (!std.mem.eql(u8, @tagName(abi.zigAbi()), gate[2])) {
    \\            std.log.err(
    \\                "'{s}': build script Zig ABI '{s}', module Zig ABI '{s}'",
    \\                .{ directory, gate[2], @tagName(abi.zigAbi()) },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\        if (abi.minApiLevel() != min_api_level) {
    \\            std.log.err(
    \\                "'{s}': build script minimum API level {d}, module minimum {d}",
    \\                .{ directory, min_api_level, abi.minApiLevel() },
    \\            );
    \\            return error.GateTableMismatch;
    \\        }
    \\    }
    \\    // `-Dabi=` must name an ABI the module also knows, not only one this
    \\    // file knows, or the two could diverge with nothing to notice.
    \\    if (abiByDirectoryName(wanted) == null) {
    \\        std.log.err("'{s}' is not an ABI of this NDK", .{wanted});
    \\        return error.UnsupportedAbi;
    \\    }
    \\}
    \\
;
