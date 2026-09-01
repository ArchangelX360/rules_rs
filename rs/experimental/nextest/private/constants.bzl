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

# The single environment variable the rule uses to reach the runner. Everything else the
# runner needs is named by the plan file this points at.
PLAN_ENV_VAR = "RULES_RS_NEXTEST_PLAN"

# Path-separator-joined instrumented objects, read by nextest_collect_coverage.
COVERAGE_OBJECTS_ENV_VAR = "RULES_RS_NEXTEST_COVERAGE_OBJECTS"

# Bumped whenever the plan file format changes incompatibly. The runner refuses a plan whose
# version it does not know, so a rule/runner mismatch surfaces as a clear error.
PLAN_VERSION = "1"

# `cargo_metadata::Edition` is a closed enum: an unrecognised value fails deserialization of
# the whole document, so unknown editions are mapped to DEFAULT_EDITION instead.
KNOWN_EDITIONS = ["2015", "2018", "2021", "2024"]
DEFAULT_EDITION = "2021"

# Must parse as a full semver version.
DEFAULT_PACKAGE_VERSION = "0.0.0"

RUST_TOOLCHAIN_TYPE = "@rules_rust//rust:toolchain_type"
