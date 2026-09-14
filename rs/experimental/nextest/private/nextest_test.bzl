"""Implementation of the `nextest_test` rule."""

load("@rules_rust//rust:rust_common.bzl", "rust_common")
load("@rules_rust//rust/private:utils.bzl", "expand_dict_value_locations")
load(
    ":constants.bzl",
    "ENV_LIST_SEPARATOR",
    "ENV_PREFIX",
    "RUST_TOOLCHAIN_TYPE",
)
load(
    ":metadata.bzl",
    "binaries_metadata_json",
    "binary_entry",
    "cargo_metadata_json",
    "rlocationpath",
    "validate_binaries",
)

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

def _env_list(ctx, key, values):
    """Joins a list for transport in one environment variable.

    The separator is a newline, which cannot occur in a Bazel path. Any other value containing
    one is rejected here rather than silently splitting into two entries at run time.

    Args:
        ctx: The rule context, used for the error message.
        key: Attribute name, used for the error message.
        values: The list of strings.

    Returns:
        The joined string.
    """
    for value in values:
        if ENV_LIST_SEPARATOR in value:
            fail("nextest_test {}: {} entry contains a newline, which cannot be passed to the test runner: {}".format(
                ctx.label,
                key,
                repr(value),
            ))
    return ENV_LIST_SEPARATOR.join(values)

def _runner_env(ctx, binaries, binaries_file, cargo_file):
    """Builds the environment variables that configure the runner.

    Everything the runner needs travels this way, as rules_rust's lint_test.bzl does for its
    own shared runner. Paths are rlocation paths, which the runner resolves against the
    runfiles root.

    Args:
        ctx: The rule context.
        binaries: The `binary_entry` structs.
        binaries_file: The generated binaries metadata `File`.
        cargo_file: The generated cargo metadata `File`.

    Returns:
        A dict of environment variables.
    """
    env = {
        ENV_PREFIX + "BINARIES_METADATA": rlocationpath(binaries_file, ctx.workspace_name),
        ENV_PREFIX + "CARGO_METADATA": rlocationpath(cargo_file, ctx.workspace_name),
        ENV_PREFIX + "FAIL_FAST": "true" if ctx.attr.fail_fast else "false",
        ENV_PREFIX + "NEXTEST": rlocationpath(ctx.file.nextest, ctx.workspace_name),
        ENV_PREFIX + "PROFILE": ctx.attr.nextest_profile,
    }
    if ctx.attr.nextest_config:
        env[ENV_PREFIX + "USER_CONFIG"] = rlocationpath(ctx.file.nextest_config, ctx.workspace_name)
    if ctx.attr.test_threads:
        env[ENV_PREFIX + "TEST_THREADS"] = ctx.attr.test_threads
    if ctx.attr.filter_expr:
        env[ENV_PREFIX + "FILTER_EXPR"] = ctx.attr.filter_expr
    if ctx.attr.nextest_args:
        env[ENV_PREFIX + "ARGS"] = _env_list(ctx, "nextest_args", ctx.attr.nextest_args)

    # Directories that may hold dynamic libraries the test binaries need. nextest runs from a
    # scratch directory rather than the runfiles root, so these are passed explicitly.
    dylib_dirs = [
        dylib_dir
        for dylib_dir in sorted({_dirname(binary.rlocation_path): None for binary in binaries})
        if dylib_dir
    ]
    if dylib_dirs:
        env[ENV_PREFIX + "DYLIB_DIRS"] = _env_list(ctx, "dylib_dir", dylib_dirs)
    return env

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
    if ctx.configuration.coverage_enabled:
        # Coverage is unsupported, and without InstrumentedFilesInfo Bazel would simply
        # attribute no sources -- so a target migrated from rust_test would lose its coverage
        # with no message anywhere. Warn rather than fail, so `bazel coverage //...` still
        # works in a repository that contains these targets. Reported here rather than only
        # from the runner because a passing test's log is hidden unless --test_output=all.
        print((
            "WARNING: nextest_test {}: coverage is not supported and this target will " +
            "contribute nothing to the report. cargo nextest runs one process per test, " +
            "which needs a collector that merges per-process profiles across every test " +
            "binary in the target; that is not implemented. Use rust_test for targets whose " +
            "coverage you measure."
        ).format(ctx.label))

    binaries = _collect_binaries(ctx)
    binaries_file, cargo_file = _write_metadata(ctx, binaries, toolchain)

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

    direct_files = [executable, binaries_file, cargo_file, ctx.file.nextest] + test_outputs
    if ctx.attr.nextest_config:
        direct_files.append(ctx.file.nextest_config)

    runfiles = ctx.runfiles(
        files = direct_files + ctx.files.data,
        root_symlinks = {"Cargo.toml": workspace_manifest},
    ).merge_all(
        [ctx.attr._runner[DefaultInfo].default_runfiles] +
        # Each inner rust_test already carries its own data and transitive dylibs. Merging them
        # is what makes this a drop-in for rust_test.
        [target[DefaultInfo].default_runfiles for target in ctx.attr.tests] +
        [target[DefaultInfo].default_runfiles for target in ctx.attr.data if DefaultInfo in target],
    )

    # User env last, so an explicit `env` entry can override the runner's configuration.
    env = _runner_env(ctx, binaries, binaries_file, cargo_file)
    env.update(expand_dict_value_locations(ctx, ctx.attr.env, ctx.attr.data, {}))

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable, binaries_file, cargo_file]),
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = env,
            inherited_environment = ctx.attr.env_inherit,
        ),
    ]

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
    attrs = _ATTRS,
    doc = """Runs one or more `rust_test` binaries under `cargo nextest`.

Each test runs in its own process, a JUnit report is written where Bazel expects it, and
`--test_filter` and test sharding are translated to nextest's native equivalents.

`cargo-nextest` is resolved hermetically and driven without cargo, so nothing outside the
build graph is required at test time.
""",
    test = True,
    toolchains = [RUST_TOOLCHAIN_TYPE],
)
