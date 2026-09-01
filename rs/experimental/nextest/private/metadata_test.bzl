"""Unit tests for the generated nextest metadata.

These carry the version-skew risk described in the rule documentation: the two documents are
written against cargo-nextest's serde structs, and there is no published JSON schema for
them. The tests compare the *decoded* documents against exact expected dictionaries, so any
field that is added, removed or renamed fails here rather than at test time. Exact dictionary
equality pins the schema just as tightly as a golden string would, without breaking when
Bazel's JSON formatting changes.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":constants.bzl", "FAKE_TARGET_DIR", "FAKE_WORKSPACE_ROOT")
load(
    ":metadata.bzl",
    "binaries_metadata_json",
    "binary_entry",
    "binary_kind_and_id",
    "cargo_metadata_json",
    "normalize_edition",
    "validate_binaries",
)

def _entry(
        name = "unit_test",
        rlocation_path = "_main/foo/bar/unit_test",
        package_name = "my-crate",
        package_version = "1.2.3",
        crate_name = "my_crate",
        wrapped_crate_type = "lib",
        edition = "2021",
        binary_id_override = None,
        package_fields = {}):
    return binary_entry(
        label = "//foo/bar:" + name,
        rlocation_path = rlocation_path,
        package_name = package_name,
        package_version = package_version,
        crate_name = crate_name,
        target_name = name,
        wrapped_crate_type = wrapped_crate_type,
        edition = edition,
        binary_id_override = binary_id_override,
        package_fields = package_fields,
    )

def _binary_kind_and_id_impl(ctx):
    env = unittest.begin(ctx)

    # A rust_test(crate = ":mylib") wraps a library, so its unit tests are the package's.
    for crate_type in ["lib", "rlib", "dylib", "proc-macro"]:
        asserts.equals(
            env,
            ("lib", "my-crate"),
            binary_kind_and_id(crate_type, "my-crate", "unit_test"),
            "wrapped crate type " + crate_type,
        )

    # A rust_test(crate = ":mybin") wraps a binary.
    asserts.equals(env, ("bin", "my-crate::bin/mybin"), binary_kind_and_id("bin", "my-crate", "mybin"))

    # A rust_test(srcs = [...]) has no wrapped crate, so it is an integration test.
    asserts.equals(env, ("test", "my-crate::integration"), binary_kind_and_id(None, "my-crate", "integration"))

    return unittest.end(env)

def _external_repo_paths_impl(ctx):
    env = unittest.begin(ctx)

    # A test binary from an external repository. Anchoring the metadata on the runfiles root
    # rather than on the workspace directory is what makes these resolve.
    entry = _entry(rlocation_path = "other_repo/pkg/it")
    asserts.equals(env, FAKE_TARGET_DIR + "/other_repo/pkg/it", entry.binary_path)
    asserts.equals(env, FAKE_WORKSPACE_ROOT + "/other_repo/pkg", entry.manifest_dir)
    asserts.equals(
        env,
        "path+file://" + FAKE_WORKSPACE_ROOT + "/other_repo/pkg#my-crate@1.2.3",
        entry.package_id,
    )

    # A binary directly at the runfiles root still yields a manifest dir under the workspace.
    asserts.equals(env, FAKE_WORKSPACE_ROOT, _entry(rlocation_path = "t").manifest_dir)

    return unittest.end(env)

def _edition_and_version_defaults_impl(ctx):
    env = unittest.begin(ctx)

    for edition in ["2015", "2018", "2021", "2024"]:
        asserts.equals(env, edition, normalize_edition(edition))

    # cargo_metadata::Edition is a closed enum, so an unknown value would fail the whole
    # document; it is mapped to a supported edition instead.
    asserts.equals(env, "2021", normalize_edition("2027"))
    asserts.equals(env, "2021", normalize_edition(""))

    # The version must parse as full semver.
    asserts.equals(env, "0.0.0", _entry(package_version = "").package_version)

    return unittest.end(env)

def _validate_binaries_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, [], validate_binaries([
        _entry(name = "a", rlocation_path = "_main/a/a"),
        _entry(name = "b", rlocation_path = "_main/b/b", wrapped_crate_type = None),
    ]))

    # Two binaries in one Bazel package share a cargo package, which is how cargo models a lib
    # unit test alongside its integration tests. That must not be an error.
    asserts.equals(env, [], validate_binaries([
        _entry(name = "a", rlocation_path = "_main/x/a", wrapped_crate_type = None),
        _entry(name = "b", rlocation_path = "_main/x/b", wrapped_crate_type = None),
    ]))

    # `rust-binaries` is keyed by binary id, so a duplicate would silently drop a whole test
    # binary. That has to be an analysis error.
    errors = validate_binaries([
        _entry(name = "a", rlocation_path = "_main/x/a"),
        _entry(name = "b", rlocation_path = "_main/x/b"),
    ])
    asserts.equals(env, 1, len(errors), "expected exactly one binary id conflict")
    asserts.true(env, "binary id" in errors[0], errors[0])
    asserts.true(env, "//foo/bar:a" in errors[0] and "//foo/bar:b" in errors[0], errors[0])

    # An explicit binary id resolves it.
    asserts.equals(env, [], validate_binaries([
        _entry(name = "a", rlocation_path = "_main/x/a"),
        _entry(name = "b", rlocation_path = "_main/x/b", binary_id_override = "my-crate::b"),
    ]))

    return unittest.end(env)

def _binaries_metadata_impl(ctx):
    env = unittest.begin(ctx)

    document = binaries_metadata_json(
        binaries = [_entry()],
        target_triple = "x86_64-unknown-linux-gnu",
    )
    platform = {
        "libdir": {"reason": "not-in-archive", "status": "unavailable"},
        "platform": "x86_64-unknown-linux-gnu",
    }
    asserts.equals(env, {
        "rust-binaries": {
            "my-crate": {
                "binary-id": "my-crate",
                "binary-name": "my_crate",
                "binary-path": FAKE_TARGET_DIR + "/_main/foo/bar/unit_test",
                "build-platform": "target",
                "kind": "lib",
                "package-id": "path+file://" + FAKE_WORKSPACE_ROOT + "/_main/foo/bar#my-crate@1.2.3",
            },
        },
        "rust-build-meta": {
            "base-output-directories": [],
            "build-script-out-dirs": {},
            "linked-paths": [],
            "non-test-binaries": {},
            "platforms": {"host": platform, "targets": [platform]},
            "target-directory": FAKE_TARGET_DIR,
            "target-platforms": [{"triple": "x86_64-unknown-linux-gnu"}],
        },
    }, json.decode(document))

    # build-directory is deliberately absent: nextest then defaults it to target-directory, so
    # one --target-dir-remap suffices and --build-dir-remap is never needed.
    asserts.false(env, "build-directory" in json.decode(document)["rust-build-meta"])

    return unittest.end(env)

def _cargo_metadata_impl(ctx):
    env = unittest.begin(ctx)

    document = cargo_metadata_json(binaries = [_entry(package_fields = {
        "authors": ["Alice <alice@example.com>", "Bob <bob@example.com>"],
        "description": "a crate",
        "license": "MIT",
    })])
    package_id = "path+file://" + FAKE_WORKSPACE_ROOT + "/_main/foo/bar#my-crate@1.2.3"
    asserts.equals(env, {
        "build_directory": None,
        "packages": [{
            "authors": ["Alice <alice@example.com>", "Bob <bob@example.com>"],
            "categories": [],
            "default_run": None,
            "dependencies": [],
            "description": "a crate",
            "documentation": None,
            "edition": "2021",
            "features": {},
            "homepage": None,
            "id": package_id,
            "keywords": [],
            "license": "MIT",
            "license_file": None,
            "links": None,
            "manifest_path": FAKE_WORKSPACE_ROOT + "/_main/foo/bar/Cargo.toml",
            "metadata": None,
            "name": "my-crate",
            "publish": None,
            "readme": None,
            "repository": None,
            "rust_version": None,
            "source": None,
            "targets": [{
                "crate_types": ["lib"],
                "doc": True,
                "doctest": False,
                "edition": "2021",
                "kind": ["lib"],
                "name": "my_crate",
                "src_path": FAKE_WORKSPACE_ROOT + "/_main/foo/bar/src/lib.rs",
                "test": True,
            }],
            "version": "1.2.3",
        }],
        "resolve": None,
        "target_directory": FAKE_TARGET_DIR,
        "version": 1,
        "workspace_default_members": [package_id],
        "workspace_members": [package_id],
        "workspace_root": FAKE_WORKSPACE_ROOT,
    }, json.decode(document))

    return unittest.end(env)

def _shared_package_impl(ctx):
    env = unittest.begin(ctx)

    # Two test binaries in one Bazel package share a cargo package, so the document must not
    # contain a duplicate entry for it.
    document = json.decode(cargo_metadata_json(binaries = [
        _entry(name = "unit_test", rlocation_path = "_main/foo/bar/unit_test"),
        _entry(name = "it", rlocation_path = "_main/foo/bar/it", wrapped_crate_type = None),
    ]))
    asserts.equals(env, 1, len(document["packages"]))
    asserts.equals(env, 1, len(document["workspace_members"]))

    return unittest.end(env)

def _no_machine_paths_impl(ctx):
    env = unittest.begin(ctx)

    # The whole design rests on the generated documents being byte-identical across machines,
    # which is what makes them remotely cacheable.
    documents = [
        binaries_metadata_json(binaries = [_entry()], target_triple = "x86_64-unknown-linux-gnu"),
        cargo_metadata_json(binaries = [_entry()]),
    ]
    for document in documents:
        for needle in ["bazel-out", "execroot", ".runfiles", "/Users", "/home/", "/private/var", "C:\\"]:
            asserts.false(
                env,
                needle in document,
                "generated metadata leaks a machine path ({}): {}".format(needle, document),
            )

    return unittest.end(env)

binary_kind_and_id_test = unittest.make(_binary_kind_and_id_impl)
external_repo_paths_test = unittest.make(_external_repo_paths_impl)
edition_and_version_defaults_test = unittest.make(_edition_and_version_defaults_impl)
validate_binaries_test = unittest.make(_validate_binaries_impl)
binaries_metadata_test = unittest.make(_binaries_metadata_impl)
cargo_metadata_test = unittest.make(_cargo_metadata_impl)
shared_package_test = unittest.make(_shared_package_impl)
no_machine_paths_test = unittest.make(_no_machine_paths_impl)

def nextest_metadata_tests():
    return unittest.suite(
        "nextest_metadata_tests",
        binary_kind_and_id_test,
        external_repo_paths_test,
        edition_and_version_defaults_test,
        validate_binaries_test,
        binaries_metadata_test,
        cargo_metadata_test,
        shared_package_test,
        no_machine_paths_test,
    )
