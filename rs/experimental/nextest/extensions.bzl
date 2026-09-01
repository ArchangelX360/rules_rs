"""Module extension that fetches the hermetic `cargo-nextest` prebuilts."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    ":prebuilts.bzl",
    "NEXTEST_PREBUILTS",
    "NEXTEST_VERSION",
    "nextest_archive_triples",
    "nextest_binary_name",
    "nextest_repo_names",
    "nextest_url",
)

_version = tag_class(
    doc = """Overrides the `cargo-nextest` version.

Only the root module may declare this tag; tags from dependencies are ignored so that a
consumer's choice always wins.
""",
    attrs = {
        "sha256": attr.string_dict(
            doc = (
                "Archive triple to sha256 of the corresponding `.tar.gz`. Keys must be a " +
                "subset of {}. Omitted archives are downloaded without a checksum, which " +
                "Bazel warns about."
            ).format(nextest_archive_triples()),
        ),
        "version": attr.string(
            doc = "cargo-nextest version, for example \"0.9.143\".",
            mandatory = True,
        ),
    },
)

def _resolve_version(mctx):
    version = NEXTEST_VERSION
    sha256_by_triple = {
        prebuilt.archive_triple: prebuilt.sha256
        for prebuilt in NEXTEST_PREBUILTS
    }

    for mod in mctx.modules:
        if not mod.is_root:
            continue
        if len(mod.tags.version) > 1:
            fail("nextest: the root module declared {} `nextest.version` tags, expected at most one".format(
                len(mod.tags.version),
            ))
        for tag in mod.tags.version:
            unknown = [key for key in tag.sha256 if key not in sha256_by_triple]
            if unknown:
                fail("nextest.version: unknown archive triples {}, expected a subset of {}".format(
                    sorted(unknown),
                    nextest_archive_triples(),
                ))
            version = tag.version

            # A new version invalidates every built-in checksum, so only the explicitly
            # provided ones are kept.
            sha256_by_triple = {
                triple: tag.sha256.get(triple, "")
                for triple in sha256_by_triple
            }

    return version, sha256_by_triple

def _nextest_impl(mctx):
    version, sha256_by_triple = _resolve_version(mctx)

    for prebuilt in NEXTEST_PREBUILTS:
        http_archive(
            name = prebuilt.repo,
            build_file_content = 'exports_files(["{}"], visibility = ["//visibility:public"])\n'.format(
                nextest_binary_name(prebuilt),
            ),
            sha256 = sha256_by_triple[prebuilt.archive_triple],
            url = nextest_url(version, prebuilt.archive_triple),
        )

    repos = nextest_repo_names()
    if mctx.root_module_has_non_dev_dependency:
        return mctx.extension_metadata(
            reproducible = True,
            root_module_direct_deps = repos,
            root_module_direct_dev_deps = [],
        )
    return mctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = [],
        root_module_direct_dev_deps = repos,
    )

nextest = module_extension(
    implementation = _nextest_impl,
    tag_classes = {"version": _version},
)
