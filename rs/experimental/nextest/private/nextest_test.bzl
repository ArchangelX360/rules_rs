"""Implementation of the `nextest_test` rule."""

load("@rules_rust//rust:rust_common.bzl", "rust_common")
load("@rules_rust//rust/private:utils.bzl", "expand_dict_value_locations")
load(
    ":constants.bzl",
    "PLAN_ENV_VAR",
    "RUST_TOOLCHAIN_TYPE",
)
load(":coverage.bzl", "COVERAGE_ATTRS", "coverage_enabled", "coverage_env", "coverage_runfiles")
load(
    ":metadata.bzl",
    "binaries_metadata_json",
    "binary_entry",
    "cargo_metadata_json",
    "rlocationpath",
    "validate_binaries",
)
load(":plan.bzl", "render_plan")

_CARGO_PACKAGE_FIELDS = [
    "authors",
    "description",
    "homepage",
    "license",
    "license_file",
    "repository",
]

def _test_crate_info(target):
    """Returns the CrateInfo of a rules_rust test target.

    `rust_test` provides `CrateInfo` directly, and additionally `TestCrateInfo` when built via
    `rust_test(crate = ...)`; both spellings are accepted, matching rules_rust's own
    `_find_test_crate_info`.

    Args:
        target: A configured target.

    Returns:
        The `CrateInfo`, or None when the target does not provide one.
    """
    if rust_common.test_crate_info in target:
        return target[rust_common.test_crate_info].crate
    if rust_common.crate_info in target:
        return target[rust_common.crate_info]
    return None

def _dirname(path):
    index = path.rfind("/")
    return path[:index] if index != -1 else ""

def _collect_binaries(ctx):
    package_fields = {
        field: ctx.attr.cargo_package[field]
        for field in _CARGO_PACKAGE_FIELDS
        if field in ctx.attr.cargo_package
    }
    if "authors" in package_fields:
        # cargo metadata models authors as a list; cargo_package() joins them the way cargo
        # joins CARGO_PKG_AUTHORS.
        package_fields["authors"] = package_fields["authors"].split(":")

    default_name = ctx.attr.cargo_package.get("name", ctx.label.package.rsplit("/", 1)[-1] or ctx.label.name)
    default_version = ctx.attr.cargo_package.get("version", "")

    binaries = []
    for target in ctx.attr.tests:
        crate_info = _test_crate_info(target)
        if not crate_info:
            fail("nextest_test {}: {} is not a rust_test target (no CrateInfo provider).".format(
                ctx.label,
                target.label,
            ))
        if not crate_info.is_test:
            fail((
                "nextest_test {}: {} is not a test target. `tests` expects rust_test targets; " +
                "a rust_library or rust_binary produces no libtest binary for nextest to run."
            ).format(ctx.label, target.label))

        label = str(target.label)
        binaries.append(binary_entry(
            label = label,
            rlocation_path = rlocationpath(crate_info.output, ctx.workspace_name),
            package_name = default_name,
            package_version = default_version,
            crate_name = crate_info.name,
            target_name = target.label.name,
            wrapped_crate_type = getattr(crate_info, "wrapped_crate_type", None),
            edition = crate_info.edition,
            binary_id_override = ctx.attr.binary_ids.get(target.label.name),
            package_fields = package_fields,
        ))

    errors = validate_binaries(binaries)
    if errors:
        fail("nextest_test {}:\n  {}".format(ctx.label, "\n  ".join(errors)))
    return binaries

def _write_metadata(ctx, binaries, toolchain):
    binaries_file = ctx.actions.declare_file(ctx.label.name + ".nextest-binaries.json")
    ctx.actions.write(
        output = binaries_file,
        content = binaries_metadata_json(
            binaries = binaries,
            target_triple = toolchain.target_triple.str,
        ),
    )

    cargo_file = ctx.actions.declare_file(ctx.label.name + ".cargo-metadata.json")
    ctx.actions.write(
        output = cargo_file,
        content = cargo_metadata_json(binaries = binaries),
    )
    return binaries_file, cargo_file

def _write_plan(ctx, binaries, binaries_file, cargo_file):
    entries = [
        ("nextest", rlocationpath(ctx.file.nextest, ctx.workspace_name)),
        ("binaries_metadata", rlocationpath(binaries_file, ctx.workspace_name)),
        ("cargo_metadata", rlocationpath(cargo_file, ctx.workspace_name)),
        ("profile", ctx.attr.nextest_profile),
        ("fail_fast", "true" if ctx.attr.fail_fast else "false"),
    ]
    if ctx.attr.nextest_config:
        entries.append(("user_config", rlocationpath(ctx.file.nextest_config, ctx.workspace_name)))
    if ctx.attr.test_threads:
        entries.append(("test_threads", ctx.attr.test_threads))
    if ctx.attr.filter_expr:
        entries.append(("filter_expr", ctx.attr.filter_expr))
    for arg in ctx.attr.nextest_args:
        entries.append(("nextest_arg", arg))

    # Directories that may hold dynamic libraries the test binaries need. nextest runs from a
    # scratch directory rather than the runfiles root, so these are passed explicitly.
    dylib_dirs = sorted({
        _dirname(binary.rlocation_path): None
        for binary in binaries
    })
    for dylib_dir in dylib_dirs:
        if dylib_dir:
            entries.append(("dylib_dir", dylib_dir))

    plan = ctx.actions.declare_file(ctx.label.name + ".nextest-plan")
    ctx.actions.write(output = plan, content = render_plan(entries))
    return plan

def _nextest_test_impl(ctx):
    if not ctx.attr.tests:
        fail("nextest_test {}: `tests` must name at least one rust_test target.".format(ctx.label))

    toolchain = ctx.toolchains[RUST_TOOLCHAIN_TYPE]
    if not toolchain.target_triple:
        fail((
            "nextest_test {}: the Rust toolchain uses a custom target specification, which " +
            "has no target triple to report in the generated metadata. Use rust_test for " +
            "custom targets."
        ).format(ctx.label))
    binaries = _collect_binaries(ctx)
    binaries_file, cargo_file = _write_metadata(ctx, binaries, toolchain)
    plan = _write_plan(ctx, binaries, binaries_file, cargo_file)

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))

    # A symlink rather than a compiled launcher stub: the runner then *is* the test binary, so
    # runtime arguments from `args` and --test_arg reach it untouched, signals and exit codes
    # are not proxied through an extra process, and no action runs on an execution platform.
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._runner,
        is_executable = True,
    )

    # nextest requires a manifest at the workspace root, which it only checks for existence and
    # never parses. Declaring it as a runfiles *root* symlink puts it at the runfiles root, a
    # location no repository's own Cargo.toml can occupy, so there is nothing to conflict with.
    workspace_manifest = ctx.actions.declare_file(ctx.label.name + ".nextest-workspace-manifest.toml")
    ctx.actions.write(output = workspace_manifest, content = "[workspace]\n")

    test_outputs = [_test_crate_info(target).output for target in ctx.attr.tests]

    with_coverage = coverage_enabled(ctx, toolchain)
    direct_files = [executable, plan, binaries_file, cargo_file, ctx.file.nextest] + test_outputs
    if ctx.attr.nextest_config:
        direct_files.append(ctx.file.nextest_config)
    if with_coverage:
        direct_files.extend(coverage_runfiles(ctx, toolchain))

    runfiles = ctx.runfiles(
        files = direct_files + ctx.files.data,
        root_symlinks = {"Cargo.toml": workspace_manifest},
    ).merge_all(
        [ctx.attr._runner[DefaultInfo].default_runfiles] +
        # Each inner rust_test already carries its data, transitive dylibs and, under
        # coverage, the llvm tools. Merging them is what makes this a drop-in for rust_test.
        [target[DefaultInfo].default_runfiles for target in ctx.attr.tests] +
        [target[DefaultInfo].default_runfiles for target in ctx.attr.data if DefaultInfo in target],
    )

    env = expand_dict_value_locations(ctx, ctx.attr.env, ctx.attr.data, {})
    env[PLAN_ENV_VAR] = rlocationpath(plan, ctx.workspace_name)
    if with_coverage:
        env.update(coverage_env(ctx, toolchain, test_outputs))

    providers = [
        DefaultInfo(
            executable = executable,
            files = depset([executable, plan, binaries_file, cargo_file]),
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = env,
            inherited_environment = ctx.attr.env_inherit,
        ),
    ]
    if with_coverage:
        providers.append(coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["tests"],
            extensions = ["rs"],
            source_attributes = [],
        ))
    return providers

_ATTRS = {
    "binary_ids": attr.string_dict(
        doc = "Overrides the nextest binary id for a `tests` entry, keyed by target name. " +
              "Needed only when two entries would otherwise derive the same id.",
    ),
    "cargo_package": attr.string_dict(
        doc = "Cargo package identity reported to the tests, which controls `CARGO_PKG_*`. " +
              "Recognised keys: name, version, edition, " + ", ".join(_CARGO_PACKAGE_FIELDS) +
              ". `authors` is colon-separated, as in `CARGO_PKG_AUTHORS`. Pass the generated " +
              "`cargo_package()` helper from a crate hub to populate it from Cargo.toml.",
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files and targets available to the tests at runtime.",
    ),
    "env": attr.string_dict(
        doc = "Environment variables set for the test. Subject to `$(location)` expansion. " +
              "Note that nextest sets `CARGO_MANIFEST_DIR` and the `CARGO_PKG_*` family " +
              "itself, so entries for those are overwritten; use `cargo_package` instead.",
    ),
    "env_inherit": attr.string_list(
        doc = "Environment variables inherited from the external environment.",
    ),
    "fail_fast": attr.bool(
        default = False,
        doc = "Stop after the first failing test. Defaults to False, matching libtest and " +
              "so `rust_test`, and keeping the JUnit report complete. nextest's own default " +
              "is to stop at the first failure.",
    ),
    "filter_expr": attr.string(
        doc = "A nextest filterset applied to every run, for example `test(/^integration/)`. " +
              "See https://nexte.st/docs/filtersets/.",
    ),
    "nextest": attr.label(
        allow_single_file = True,
        cfg = "target",
        default = Label("//rs/experimental/nextest:nextest_binary"),
        doc = "The cargo-nextest binary. Defaults to the hermetic prebuilt for the target platform.",
    ),
    "nextest_args": attr.string_list(
        doc = "Extra arguments passed to `cargo-nextest nextest run`.",
    ),
    "nextest_config": attr.label(
        allow_single_file = True,
        doc = "A nextest configuration file, supplied as a tool config so that profiles, " +
              "overrides and test groups apply while the Bazel-owned JUnit and store " +
              "settings still take precedence.",
    ),
    "nextest_profile": attr.string(
        default = "default",
        doc = "The nextest profile to run.",
    ),
    "test_threads": attr.string(
        doc = "Number of tests to run concurrently: a positive integer, a negative integer " +
              "relative to the CPU count, or `num-cpus`. Defaults to nextest's own choice.",
    ),
    "tests": attr.label_list(
        doc = "`rust_test` targets whose binaries nextest should run. More than one may be " +
              "given, in which case nextest schedules across all of them in one Bazel target.",
        mandatory = True,
        providers = [[rust_common.crate_info], [rust_common.test_crate_info]],
    ),
    "_runner": attr.label(
        cfg = "target",
        default = Label("//rs/experimental/nextest/private:nextest_bazel_runner"),
        executable = True,
    ),
    "_windows_constraint": attr.label(default = Label("@platforms//os:windows")),
}

nextest_test = rule(
    implementation = _nextest_test_impl,
    attrs = _ATTRS | COVERAGE_ATTRS,
    doc = """Runs one or more `rust_test` binaries under `cargo nextest`.

Each test runs in its own process, a JUnit report is written where Bazel expects it, and
`--test_filter` and test sharding are translated to nextest's native equivalents.

`cargo-nextest` is resolved hermetically and driven without cargo, so nothing outside the
build graph is required at test time.
""",
    test = True,
    toolchains = [RUST_TOOLCHAIN_TYPE],
)
