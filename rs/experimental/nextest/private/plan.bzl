"""Rendering of the plan file the nextest runner reads.

The plan is a line-oriented `key<TAB>value` file rather than JSON, so the runner can stay a
std-only Rust binary with no JSON parser. Tabs cannot occur in Bazel paths, and values are
rejected at analysis time if they contain a tab or newline, so the format needs no escaping.

Keys may repeat, which is how list-valued entries are expressed. The runner rejects any key
it does not know, so a rule/runner mismatch surfaces as a clear error rather than silently
dropped configuration.
"""

load(":constants.bzl", "PLAN_VERSION")

# Every key the runner understands. Kept here so plan_test.bzl can assert the rule and the
# runner agree on the vocabulary.
PLAN_KEYS = [
    "version",
    # Runfiles-relative paths.
    "nextest",
    "binaries_metadata",
    "cargo_metadata",
    "workspace_manifest",
    "user_config",
    "dylib_dir",
    # Plain values.
    "profile",
    "fail_fast",
    "test_threads",
    "filter_expr",
    "nextest_arg",
    "allow_no_tests",
]

def _check(key, value):
    if key not in PLAN_KEYS:
        fail("nextest plan: unknown key {}, expected one of {}".format(repr(key), PLAN_KEYS))
    if "\t" in value or "\n" in value:
        fail((
            "nextest plan: the value for {} contains a tab or newline, which the plan " +
            "format cannot represent: {}"
        ).format(key, repr(value)))

def render_plan(entries):
    """Renders plan entries into the plan file body.

    Args:
        entries: A list of `(key, value)` tuples. Order is preserved, so repeated keys keep
            their relative order.

    Returns:
        The plan file contents as a string.
    """
    lines = ["version\t" + PLAN_VERSION]
    for key, value in entries:
        if key == "version":
            fail("nextest plan: the version entry is added automatically")
        _check(key, value)
        lines.append("{}\t{}".format(key, value))
    return "\n".join(lines) + "\n"
