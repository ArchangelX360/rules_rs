"""Coverage wiring for the nextest test rule.

Mirrors what rules_rust's `rust_test` does (`rust/private/rust.bzl`), with one necessary
difference: `rust_test` relies on rules_rust's `//util/collect_coverage`, which exports
coverage for exactly one object read from `TEST_BINARY`. Under nextest `TEST_BINARY` is this
rule's runner, which carries no instrumented code, and a single target may drive several test
binaries. So the objects are passed explicitly and collected by a variant that accepts more
than one.
"""

load(":constants.bzl", "COVERAGE_OBJECTS_ENV_VAR")
load(":metadata.bzl", "rlocationpath")

COVERAGE_ATTRS = {
    "_collect_cc_coverage": attr.label(
        cfg = "exec",
        default = Label("//rs/experimental/nextest/private:nextest_collect_coverage"),
        executable = True,
    ),
    # Bazel's coverage runner needs an lcov merger, whose location it reads from the
    # LCOV_MERGER environment variable. Built-in rules get this from a magic `$lcov_merger`
    # attribute that Starlark cannot declare, so it is specified explicitly.
    "_lcov_merger": attr.label(
        cfg = "exec",
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
    ),
}

def coverage_enabled(ctx, toolchain):
    """Reports whether coverage output should be produced for this test.

    Args:
        ctx: The rule context.
        toolchain: The resolved Rust toolchain.

    Returns:
        True when Bazel asked for coverage and the toolchain supports it.
    """
    return toolchain.coverage_supported and ctx.configuration.coverage_enabled

def _toolchain_tool_path(file):
    """Path to a toolchain tool, as rules_rust spells it.

    Toolchain tools live in external repositories, so stripping `../` from the short path
    already yields a runfiles-root-relative path. Kept identical to rules_rust so the resolution
    rules_rust's collector relies on continue to apply.
    """
    path = file.short_path
    if path.startswith("../"):
        return path[len("../"):]
    return path

def coverage_env(ctx, toolchain, objects):
    """Builds the coverage environment variables for the test.

    Args:
        ctx: The rule context.
        toolchain: The resolved Rust toolchain.
        objects: The instrumented test binary `File`s.

    Returns:
        A dict of environment variables.
    """
    if not toolchain.llvm_profdata:
        fail("The Rust toolchain sets llvm_cov but not llvm_profdata; both are required for coverage.")

    if toolchain._experimental_use_coverage_metadata_files:
        llvm_cov_path = toolchain.llvm_cov.path
        llvm_profdata_path = toolchain.llvm_profdata.path
    else:
        llvm_cov_path = _toolchain_tool_path(toolchain.llvm_cov)
        llvm_profdata_path = _toolchain_tool_path(toolchain.llvm_profdata)

    return {
        # Bazel's collect_coverage.sh checks both GENERATE_LLVM_LCOV and
        # CC_CODE_COVERAGE_SCRIPT before invoking the collector. Starlark test rules do not
        # get these wired automatically.
        "CC_CODE_COVERAGE_SCRIPT": ctx.executable._collect_cc_coverage.path,
        "GENERATE_LLVM_LCOV": "1",
        "RUST_LLVM_COV": llvm_cov_path,
        "RUST_LLVM_PROFDATA": llvm_profdata_path,
        # The collector resolves these against the runfiles root, so they need the full
        # rlocation path. A bare short path would be workspace-relative and would miss the
        # repository component for anything in the main repository.
        COVERAGE_OBJECTS_ENV_VAR: ctx.configuration.host_path_separator.join(
            [rlocationpath(obj, ctx.workspace_name) for obj in objects],
        ),
    }

def coverage_runfiles(ctx, toolchain):
    """Returns the files the coverage collector needs at test time.

    Args:
        ctx: The rule context.
        toolchain: The resolved Rust toolchain.

    Returns:
        A list of `File`s.
    """
    files = [ctx.executable._collect_cc_coverage]
    if toolchain.llvm_cov:
        files.append(toolchain.llvm_cov)
    if toolchain.llvm_profdata:
        files.append(toolchain.llvm_profdata)
    return files
