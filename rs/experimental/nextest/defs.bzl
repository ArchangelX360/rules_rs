"""Public API for running Rust tests under `cargo nextest`.

`rust_nextest_test` is a drop-in replacement for `rust_test`. `nextest_test` wraps existing
`rust_test` targets, and accepts several of them so one Bazel target can schedule across
multiple test binaries.

Experimental: the attribute surface may change without notice.
"""

load("//rs/experimental/nextest/private:macro.bzl", _rust_nextest_test = "rust_nextest_test")
load("//rs/experimental/nextest/private:nextest_test.bzl", _nextest_test = "nextest_test")

nextest_test = _nextest_test
rust_nextest_test = _rust_nextest_test
