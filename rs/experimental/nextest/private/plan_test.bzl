"""Unit tests for the runner plan file."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":constants.bzl", "PLAN_VERSION")
load(":plan.bzl", "PLAN_KEYS", "render_plan")

def _render_plan_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "\n".join([
            "version\t" + PLAN_VERSION,
            "nextest\tcargo_nextest_macos/cargo-nextest",
            "profile\tdefault",
            "dylib_dir\t_main/foo",
            "dylib_dir\t_main/bar",
        ]) + "\n",
        render_plan([
            ("nextest", "cargo_nextest_macos/cargo-nextest"),
            ("profile", "default"),
            # Repeated keys express lists, and their relative order is preserved.
            ("dylib_dir", "_main/foo"),
            ("dylib_dir", "_main/bar"),
        ]),
    )

    # The version line is always first, so the runner can reject an incompatible plan before
    # interpreting anything else.
    asserts.true(env, render_plan([]).startswith("version\t"))

    return unittest.end(env)

def _plan_keys_are_unique_impl(ctx):
    env = unittest.begin(ctx)

    # The runner splits PLAN_KEYS into single-valued and repeated sets; a duplicate here would
    # mean one of them silently disagrees with this list.
    asserts.equals(env, len(PLAN_KEYS), len({key: None for key in PLAN_KEYS}))
    asserts.true(env, "version" in PLAN_KEYS)

    return unittest.end(env)

render_plan_test = unittest.make(_render_plan_impl)
plan_keys_are_unique_test = unittest.make(_plan_keys_are_unique_impl)

def nextest_plan_tests():
    return unittest.suite(
        "nextest_plan_tests",
        render_plan_test,
        plan_keys_are_unique_test,
    )
