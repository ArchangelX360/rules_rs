"""Assertions for cargo-faithful dev-dependency feature separation.

Cargo only enables `[dev-dependencies]` features when building test targets, so a crate
that is depended on both normally and as a dev-dependency must be compiled without the
dev-only features for production targets. See the `dev_dep_features` fixture.

`DEP_DATA`'s `crate_features` describes the workspace member rather than its registry
dependencies, so these assertions read the features off the compile action instead.
`crate_features` reach rustc as a `--cfg` flag followed by `feature="<name>"`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _rustc_action(env, tut):
    actions = [action for action in tut.actions if action.mnemonic == "Rustc"]
    asserts.equals(
        env,
        1,
        len(actions),
        "Expected exactly one Rustc action, got {}".format([action.mnemonic for action in tut.actions]),
    )
    return actions[0] if actions else None

def _enabled_features(action):
    return [arg for arg in action.argv if arg.startswith('feature="')]

def _crate_features_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _rustc_action(env, analysistest.target_under_test(env))
    if not action:
        return analysistest.end(env)

    enabled = _enabled_features(action)

    for feature in ctx.attr.expected_features:
        asserts.true(
            env,
            'feature="{}"'.format(feature) in enabled,
            "Expected feature {} to be enabled, got {}".format(feature, enabled),
        )

    for feature in ctx.attr.unexpected_features:
        asserts.false(
            env,
            'feature="{}"'.format(feature) in enabled,
            "Feature {} leaked from [dev-dependencies] into a non-test build, got {}".format(feature, enabled),
        )

    return analysistest.end(env)

crate_features_test = analysistest.make(
    _crate_features_test_impl,
    attrs = {
        "expected_features": attr.string_list(),
        "unexpected_features": attr.string_list(),
    },
)
