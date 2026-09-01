"""Analysis-time assertions for nextest_test.

`ctx.actions.write` exposes its content to analysistest, so the generated metadata can be
asserted on without running anything. These cover the two properties the design rests on and
that no runtime test can demonstrate: that the metadata contains no machine-specific paths (so
it is deterministic and remotely cacheable), and that the test executable is a symlink with no
action running on an execution platform.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _write_action_contents(tut):
    """Returns the content of every FileWrite action, keyed by output basename."""
    contents = {}
    for action in tut.actions:
        if action.mnemonic != "FileWrite":
            continue
        for output in action.outputs.to_list():
            contents[output.basename] = action.content
    return contents

def _find(contents, suffix):
    for basename, content in contents.items():
        if basename.endswith(suffix):
            return content
    return None

def _metadata_content_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    contents = _write_action_contents(tut)

    binaries = _find(contents, ".nextest-binaries.json")
    asserts.true(env, binaries != None, "no .nextest-binaries.json was written")
    decoded = json.decode(binaries)

    asserts.equals(env, 1, len(decoded["rust-binaries"]), "expected one test binary")
    entry = decoded["rust-binaries"].values()[0]
    asserts.equals(env, "lib", entry["kind"], "rust_test(crate = ...) is a lib unit test")
    asserts.equals(env, "target", entry["build-platform"])
    asserts.true(
        env,
        entry["binary-path"].startswith("/__rules_rs_nextest_target__/"),
        "binary-path must be under the placeholder target dir, got {}".format(entry["binary-path"]),
    )

    # Omitted so nextest defaults it to target-directory, which is what lets one
    # --target-dir-remap cover binary paths without relying on --build-dir-remap.
    asserts.false(env, "build-directory" in decoded["rust-build-meta"])

    cargo = _find(contents, ".cargo-metadata.json")
    asserts.true(env, cargo != None, "no .cargo-metadata.json was written")
    decoded = json.decode(cargo)
    asserts.equals(env, 1, decoded["version"])

    # As emitted by `cargo metadata --no-deps`; guppy tolerates a null resolve and nextest only
    # ever looks packages up by id.
    asserts.equals(env, None, decoded["resolve"])
    asserts.equals(env, "/__rules_rs_nextest_ws__", decoded["workspace_root"])
    asserts.equals(env, 1, len(decoded["packages"]))

    return analysistest.end(env)

def _no_machine_paths_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    # The generated files must be byte-identical on every machine, which is what makes them
    # cacheable and safe for remote execution. A leaked execroot or home directory would make
    # every developer's cache entries mutually useless.
    for basename, content in _write_action_contents(tut).items():
        for needle in ["bazel-out", "execroot", ".runfiles", "/Users/", "/home/", "/private/var"]:
            asserts.false(
                env,
                needle in content,
                "{} leaks a machine path ({}):\n{}".format(basename, needle, content),
            )

    return analysistest.end(env)

# Actions Bazel creates for every test target, regardless of the rule.
_BAZEL_TEST_PLUMBING = [
    "RepoMappingManifest",
    "RunfilesTree",
    "SourceSymlinkManifest",
    "TestRunner",
]

def _executable_is_a_symlink_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    # A symlink to a shared runner rather than a per-target compiled launcher stub. That is what
    # keeps runtime argv reaching the runner untouched, avoids proxying signals and exit codes
    # through an extra process, and -- asserted below -- leaves no action that has to run on an
    # execution platform, so a test target costs no remote round trip.
    symlinks = [action for action in tut.actions if action.mnemonic == "ExecutableSymlink"]
    asserts.equals(
        env,
        1,
        len(symlinks),
        "expected exactly one ExecutableSymlink, got {}".format([a.mnemonic for a in tut.actions]),
    )

    # ctx.actions.write and ctx.actions.symlink are performed by Bazel in process. Anything else
    # would mean a spawn, and so an execution platform and remote traffic per target.
    contributed = sorted({
        action.mnemonic: None
        for action in tut.actions
        if action.mnemonic not in _BAZEL_TEST_PLUMBING
    })
    asserts.equals(
        env,
        ["ExecutableSymlink", "FileWrite"],
        contributed,
        "nextest_test should only write metadata and symlink the runner",
    )

    # Three metadata documents plus the stub workspace manifest.
    writes = [action for action in tut.actions if action.mnemonic == "FileWrite"]
    asserts.equals(env, 4, len(writes), "expected four generated files")

    return analysistest.end(env)

def _coverage_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    environment = tut[RunEnvironmentInfo].environment
    for name in [
        "CC_CODE_COVERAGE_SCRIPT",
        "GENERATE_LLVM_LCOV",
        "RULES_RS_NEXTEST_COVERAGE_OBJECTS",
        "RUST_LLVM_COV",
        "RUST_LLVM_PROFDATA",
    ]:
        asserts.true(env, name in environment, "{} should be set under coverage".format(name))

    # The objects are resolved against the runfiles root, so they carry the repository prefix.
    objects = environment["RULES_RS_NEXTEST_COVERAGE_OBJECTS"]
    asserts.true(
        env,
        objects.startswith("_main/") or objects.startswith("test/"),
        "coverage objects should be rlocation paths, got {}".format(objects),
    )

    return analysistest.end(env)

metadata_content_test = analysistest.make(_metadata_content_test_impl)
no_machine_paths_test = analysistest.make(_no_machine_paths_test_impl)
executable_is_a_symlink_test = analysistest.make(_executable_is_a_symlink_test_impl)
coverage_env_test = analysistest.make(
    _coverage_env_test_impl,
    config_settings = {
        "//command_line_option:collect_code_coverage": True,
        "//command_line_option:instrumentation_filter": "//nextest[:/]",
    },
)
