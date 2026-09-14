"""Constants shared by the nextest rule implementation and its unit tests."""

# Placeholder roots in the generated metadata, which the runner remaps to real runfiles paths at
# run time, keeping the metadata byte-identical across machines. nextest rewrites a recorded
# path only when it starts with the prefix stored in the metadata. The workspace root drives each
# test's working directory and CARGO_MANIFEST_DIR; the target directory drives `binary-path`.
FAKE_WORKSPACE_ROOT = "/__rules_rs_nextest_ws__"
FAKE_TARGET_DIR = "/__rules_rs_nextest_target__"

# Prefix for the environment variables carrying the runner's configuration.
ENV_PREFIX = "RULES_RS_NEXTEST_"

# Separator for the list-valued variables. The rule rejects any value containing one, so no
# escaping is needed.
ENV_LIST_SEPARATOR = "\n"

# Path-separator-joined instrumented objects, read by nextest_collect_coverage.
COVERAGE_OBJECTS_ENV_VAR = ENV_PREFIX + "COVERAGE_OBJECTS"

# `cargo_metadata::Edition` is a closed enum: an unrecognised value fails deserialization of the
# whole document, so unknown editions are reported as DEFAULT_EDITION.
KNOWN_EDITIONS = ["2015", "2018", "2021", "2024"]
DEFAULT_EDITION = "2021"

# Must parse as a full semver version.
DEFAULT_PACKAGE_VERSION = "0.0.0"

RUST_TOOLCHAIN_TYPE = "@rules_rust//rust:toolchain_type"
