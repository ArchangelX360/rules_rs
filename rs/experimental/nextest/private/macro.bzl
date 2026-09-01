"""Implementation of the `rust_nextest_test` macro."""

load("@rules_rust//rust:defs.bzl", "rust_test")
load(":nextest_test.bzl", "nextest_test")

# Attributes consumed by the nextest_test wrapper rather than by the inner rust_test.
_WRAPPER_ATTRS = [
    "binary_ids",
    "cargo_package",
    "fail_fast",
    "filter_expr",
    "nextest",
    "nextest_args",
    "nextest_config",
    "nextest_profile",
    "test_threads",
]

# Attributes Bazel interprets on the test target itself, which must therefore stay on the
# wrapper and not be forwarded to the inner (non-running) rust_test.
_TEST_ATTRS = [
    "args",
    "env",
    "env_inherit",
    "flaky",
    "shard_count",
    "size",
    "target_compatible_with",
    "timeout",
    "toolchains",
    "visibility",
]

# Attributes the inner rust_test needs in addition to whatever it is given.
_SHARED_ATTRS = ["data"]

def rust_nextest_test(name, **kwargs):
    """Declares a `rust_test` and runs it under `cargo nextest`.

    A drop-in replacement for `rust_test`: it accepts the same attributes, plus the
    nextest-specific ones documented on `nextest_test`. Compared with `rust_test` it runs each
    test in its own process, writes a real JUnit report to `XML_OUTPUT_FILE`, honours
    `--test_filter`, and shards without a shell script.

    Two targets are created: `<name>` is the test, and `<name>.test_binary` is the inner
    `rust_test` that compiles the libtest binary. The inner target is tagged `manual` so it is
    not picked up by wildcards.

    Args:
        name: The test target name.
        **kwargs: `rust_test` attributes plus the `nextest_test` attributes listed above.
    """
    if kwargs.get("use_libtest_harness", True) == False:
        fail((
            "rust_nextest_test {}: use_libtest_harness = False produces a plain binary rather " +
            "than a libtest binary, which cargo nextest cannot enumerate. Use rust_test instead."
        ).format(name))
    if "experimental_enable_sharding" in kwargs:
        fail((
            "rust_nextest_test {}: experimental_enable_sharding is not accepted; sharding is " +
            "handled natively through nextest's partitioning, so just set shard_count."
        ).format(name))
    if "tests" in kwargs:
        fail((
            "rust_nextest_test {}: `tests` belongs to nextest_test. rust_nextest_test builds " +
            "its own test binary from srcs/crate."
        ).format(name))

    binary_name = name + ".test_binary"

    # The inner target name carries a dot so it reads as a companion of `name`, but rules_rust
    # derives the crate name from the label and rejects a dot in it. Pinning the crate name to
    # what plain rust_test would have produced for `name` keeps the compiled crate, and so
    # nextest's reported binary name, identical to rust_test. It also lets rules_rust infer the
    # crate root from `<name>.rs`, which the label no longer matches.
    #
    # On the `crate = ...` path the crate name comes from the wrapped crate instead, so it must
    # be left alone there.
    if "crate" not in kwargs:
        kwargs.setdefault("crate_name", name.replace("-", "_"))

    wrapper_kwargs = {key: kwargs.pop(key) for key in _WRAPPER_ATTRS if key in kwargs}
    test_kwargs = {key: kwargs.pop(key) for key in _TEST_ATTRS if key in kwargs}
    for key in _SHARED_ATTRS:
        if key in kwargs:
            wrapper_kwargs[key] = kwargs[key]

    tags = kwargs.pop("tags", [])
    rust_test(
        name = binary_name,
        # Not a target anyone should run directly: nextest drives the binary it produces.
        tags = tags + ["manual"],
        # Bazel would otherwise wrap the binary in a shell sharding script, and nextest needs
        # the real libtest binary.
        experimental_enable_sharding = False,
        visibility = ["//visibility:private"],
        **kwargs
    )

    nextest_test(
        name = name,
        tags = tags,
        tests = [":" + binary_name],
        **(wrapper_kwargs | test_kwargs)
    )
