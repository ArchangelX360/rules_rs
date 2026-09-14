"""Constants shared by the nextest rule implementation and its unit tests."""

# Placeholder roots baked into the generated metadata in place of real paths.
#
# nextest's `PathMapper` rewrites a recorded path only when it starts with the prefix stored
# in the metadata, and leaves it untouched otherwise. Using absolute paths that cannot exist
# on any machine therefore means a mistake fails loudly rather than silently resolving to
# something real. Keeping real paths out of the metadata is also what makes the generated
# JSON byte-identical across machines, and so remotely cacheable.
#
# Two distinct prefixes are used even though the runner remaps both to the same runtime
# directory: the workspace mapping drives each test's working directory and
# CARGO_MANIFEST_DIR, while the build-directory mapping drives `binary-path`. Distinct
# prefixes keep the two mappings independently debuggable.
FAKE_WORKSPACE_ROOT = "/__rules_rs_nextest_ws__"
FAKE_TARGET_DIR = "/__rules_rs_nextest_target__"

# Prefix for the environment variables that carry the runner's configuration. Everything the
# runner needs arrives this way, following rules_rust's own lint_test.bzl.
ENV_PREFIX = "RULES_RS_NEXTEST_"

# Separator for the list-valued variables. Newlines cannot appear in a Bazel path, and the rule
# rejects any other value containing one, so no escaping is needed.
ENV_LIST_SEPARATOR = "\n"

# `cargo_metadata::Edition` is a closed enum: an unrecognised value fails deserialization of
# the whole document, so unknown editions are mapped to DEFAULT_EDITION instead.
KNOWN_EDITIONS = ["2015", "2018", "2021", "2024"]
DEFAULT_EDITION = "2021"

# Must parse as a full semver version.
DEFAULT_PACKAGE_VERSION = "0.0.0"

RUST_TOOLCHAIN_TYPE = "@rules_rust//rust:toolchain_type"
