load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "merge_structured_dep_specs")

def _merge_structured_dep_specs_dedupes_and_promotes_impl(ctx):
    env = unittest.begin(ctx)

    specs = [
        (
            ["@repo//:shared", "@repo//:dup"],
            {
                "//cfg:unix": ["@repo//:linux_only", "@repo//:dup"],
                "//cfg:darwin": ["@repo//:darwin_only"],
            },
        ),
        (
            [],
            {
                "//cfg:unix": ["@repo//:everywhere"],
                "//cfg:darwin": ["@repo//:everywhere", "@repo//:darwin_only"],
                "//cfg:win": ["@repo//:everywhere"],
            },
        ),
    ]

    shared, per_platform = merge_structured_dep_specs(
        specs,
        ["//cfg:darwin", "//cfg:unix", "//cfg:win"],
        None,
    )

    asserts.equals(env, ["@repo//:dup", "@repo//:everywhere", "@repo//:shared"], shared)
    asserts.equals(env, {
        "//cfg:darwin": ["@repo//:darwin_only"],
        "//cfg:unix": ["@repo//:linux_only"],
    }, per_platform)

    return unittest.end(env)

def _merge_structured_dep_specs_applies_filter_prefix_impl(ctx):
    env = unittest.begin(ctx)

    shared, per_platform = merge_structured_dep_specs(
        [
            (
                ["@repo//:shared", "@other//:drop"],
                {
                    "//cfg:linux": ["@repo//:linux_only", "@other//:drop"],
                },
            ),
        ],
        ["//cfg:darwin", "//cfg:linux"],
        "@repo//:",
    )

    asserts.equals(env, ["@repo//:shared"], shared)
    asserts.equals(env, {"//cfg:linux": ["@repo//:linux_only"]}, per_platform)

    return unittest.end(env)

def _all_crate_deps_defaults_to_normal_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": ["//:normal"],
            "deps_by_platform": {},
            "build_deps": ["//:build"],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dev"],
            "dev_deps_by_platform": {},
        },
        platforms = ["//cfg:darwin", "//cfg:linux"],
    )

    asserts.equals(env, ["//:normal"], got)

    return unittest.end(env)

def _all_crate_deps_dedupes_across_selected_kinds_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": [],
            "deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_b"],
            },
            "build_deps": [],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dep_b"],
            "dev_deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_c"],
            },
        },
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
    )

    asserts.equals(env, ["//:dep_a", "//:dep_b", "//:dep_c"], got)

    return unittest.end(env)

_DEV_VARIANT_DEP_DATA = {
    "deps": ["//:tok"],
    "deps_by_platform": {},
    "build_deps": [],
    "build_deps_by_platform": {},
    "dev_deps": ["//:tok", "//:proptest"],
    "dev_deps_by_platform": {},
}

_DEV_VARIANTS = {"//:tok": "//:tok__dev"}

def _all_crate_deps_keeps_production_variant_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        _DEV_VARIANT_DEP_DATA,
        platforms = ["//cfg:linux"],
        normal = True,
        dev_variants = _DEV_VARIANTS,
    )

    asserts.equals(env, ["//:tok"], got)

    return unittest.end(env)

def _all_crate_deps_substitutes_dev_variant_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        _DEV_VARIANT_DEP_DATA,
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
        dev_variants = _DEV_VARIANTS,
    )

    # The variant replaces the production label rather than joining it; a test target
    # cannot link two crates sharing a `crate_name`.
    asserts.equals(env, ["//:proptest", "//:tok__dev"], got)

    return unittest.end(env)

def _all_crate_deps_substitutes_normal_only_dep_impl(ctx):
    env = unittest.begin(ctx)

    # A crate that is only a normal dependency still needs its variant when a
    # dev-dependency raised its features transitively.
    got = all_crate_deps(
        {
            "deps": ["//:serde"],
            "deps_by_platform": {},
            "build_deps": [],
            "build_deps_by_platform": {},
            "dev_deps": [],
            "dev_deps_by_platform": {},
        },
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
        dev_variants = {"//:serde": "//:serde__dev"},
    )

    asserts.equals(env, ["//:serde__dev"], got)

    return unittest.end(env)

def _all_crate_deps_without_dev_variants_unions_impl(ctx):
    env = unittest.begin(ctx)

    # Without the split enabled there are no variants, and the bags union as before.
    got = all_crate_deps(
        _DEV_VARIANT_DEP_DATA,
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
    )

    asserts.equals(env, ["//:proptest", "//:tok"], got)

    return unittest.end(env)

def _all_crate_deps_substitutes_per_platform_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": [],
            "deps_by_platform": {"//cfg:linux": ["//:tok"]},
            "build_deps": [],
            "build_deps_by_platform": {},
            "dev_deps": [],
            "dev_deps_by_platform": {"//cfg:linux": ["//:tok"]},
        },
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
        dev_variants = _DEV_VARIANTS,
    )

    asserts.equals(env, ["//:tok__dev"], got)

    return unittest.end(env)

merge_structured_dep_specs_dedupes_and_promotes_test = unittest.make(_merge_structured_dep_specs_dedupes_and_promotes_impl)
merge_structured_dep_specs_applies_filter_prefix_test = unittest.make(_merge_structured_dep_specs_applies_filter_prefix_impl)
all_crate_deps_defaults_to_normal_test = unittest.make(_all_crate_deps_defaults_to_normal_impl)
all_crate_deps_dedupes_across_selected_kinds_test = unittest.make(_all_crate_deps_dedupes_across_selected_kinds_impl)
all_crate_deps_keeps_production_variant_test = unittest.make(_all_crate_deps_keeps_production_variant_impl)
all_crate_deps_substitutes_dev_variant_test = unittest.make(_all_crate_deps_substitutes_dev_variant_impl)
all_crate_deps_substitutes_normal_only_dep_test = unittest.make(_all_crate_deps_substitutes_normal_only_dep_impl)
all_crate_deps_without_dev_variants_unions_test = unittest.make(_all_crate_deps_without_dev_variants_unions_impl)
all_crate_deps_substitutes_per_platform_test = unittest.make(_all_crate_deps_substitutes_per_platform_impl)

def all_crate_deps_tests():
    return unittest.suite(
        "all_crate_deps_tests",
        merge_structured_dep_specs_dedupes_and_promotes_test,
        merge_structured_dep_specs_applies_filter_prefix_test,
        all_crate_deps_defaults_to_normal_test,
        all_crate_deps_dedupes_across_selected_kinds_test,
        all_crate_deps_keeps_production_variant_test,
        all_crate_deps_substitutes_dev_variant_test,
        all_crate_deps_substitutes_normal_only_dep_test,
        all_crate_deps_without_dev_variants_unions_test,
        all_crate_deps_substitutes_per_platform_test,
    )
