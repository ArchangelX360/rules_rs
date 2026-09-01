"""Synthesis of the two JSON documents `cargo-nextest` needs to run without cargo.

`cargo nextest run --binaries-metadata <A> --cargo-metadata <B>` skips the cargo invocation
and the build entirely, so Bazel can supply both documents from analysis. `<A>` is normally
produced by `cargo nextest list --list-type binaries-only --message-format json` and `<B>` by
`cargo metadata --format-version 1`; here both are written by `ctx.actions.write`.

Every function in this file is pure -- values in, strings out -- so the schema fidelity that
carries all of the version-skew risk is unit-testable without running an action. See
`metadata_test.bzl`, whose golden strings pin the exact bytes.

Schema references, at cargo-nextest 0.9.143:

* `BinaryListSummary`, `RustBuildMetaSummary`, `RustTestBinarySummary`, `PlatformLibdirSummary`
  -- nextest-metadata/src/test_list.rs
* `PlatformSummary` -- target-spec/src/summaries.rs
* `Metadata`, `Package`, `Target` -- the cargo_metadata crate (0.23.1), read by guppy 0.17.26

Two deliberate choices about fields:

* `build-directory` is omitted. nextest then defaults it to `target-directory`, so a single
  `--target-dir-remap` covers `binary-path` remapping and we never depend on
  `--build-dir-remap`, which only exists from 0.9.131.
* Every `Package` field is emitted explicitly, even the ones with serde defaults, because
  which fields carry `#[serde(default)]` has changed across cargo_metadata versions and being
  explicit costs nothing here.
"""

load(
    ":constants.bzl",
    "DEFAULT_EDITION",
    "DEFAULT_PACKAGE_VERSION",
    "FAKE_TARGET_DIR",
    "FAKE_WORKSPACE_ROOT",
    "KNOWN_EDITIONS",
)

# Crate types that mean "unit tests compiled into a library target", i.e. rust_test(crate =).
_LIB_CRATE_TYPES = ["lib", "rlib", "dylib", "proc-macro"]

def rlocationpath(file, workspace_name):
    """Returns the runfiles-root-relative path of `file`.

    This is the same helper rules_rust's lint_test.bzl uses. It is deliberately not
    `File.short_path`: a short path is relative to the *workspace* directory and spells
    external repositories `../repo/...`, whereas nextest needs a single root under which both
    main-repo and external-repo binaries resolve.

    Args:
        file: A `File`.
        workspace_name: `ctx.workspace_name`.

    Returns:
        The path relative to the runfiles root, as a string.
    """
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return "{}/{}".format(workspace_name, file.short_path)

def _dirname(path):
    index = path.rfind("/")
    if index == -1:
        return ""
    return path[:index]

def normalize_edition(edition):
    """Maps an edition onto one cargo_metadata can deserialize.

    `cargo_metadata::Edition` is a closed enum, so an unrecognised value fails deserialization
    of the entire document. Unknown editions are reported as `DEFAULT_EDITION` instead. Nothing
    nextest does depends on the reported edition -- it is carried only so the synthesized
    manifest is well formed -- so substituting silently is safe.

    Args:
        edition: The edition string, possibly empty or unrecognised.

    Returns:
        One of `KNOWN_EDITIONS`.
    """
    if edition in KNOWN_EDITIONS:
        return edition
    return DEFAULT_EDITION

def manifest_dir_for(rlocation_path):
    """Returns the placeholder manifest directory for a test binary.

    Args:
        rlocation_path: The binary's runfiles-root-relative path.

    Returns:
        An absolute path under `FAKE_WORKSPACE_ROOT`.
    """
    package_dir = _dirname(rlocation_path)
    if not package_dir:
        return FAKE_WORKSPACE_ROOT
    return "{}/{}".format(FAKE_WORKSPACE_ROOT, package_dir)

def package_id_for(manifest_dir, package_name, version):
    """Returns a cargo package id.

    This is the modern spelling cargo emits for path packages, so any id parsing in guppy
    succeeds.

    Args:
        manifest_dir: Directory holding the package's `Cargo.toml`.
        package_name: The cargo package name.
        version: The package version.

    Returns:
        A package id string.
    """
    return "path+file://{}#{}@{}".format(manifest_dir, package_name, version)

def binary_kind_and_id(wrapped_crate_type, package_name, target_name):
    """Derives nextest's `kind` and `binary-id` for a rules_rust test binary.

    `CrateInfo.wrapped_crate_type` holds the wrapped crate's type on the
    `rust_test(crate = ":lib")` path and is absent on the `rust_test(srcs = [...])` path,
    which is exactly the unit-test versus integration-test distinction nextest encodes. The
    id format is part of nextest's stable API (see `RustBinaryId::from_parts`).

    Args:
        wrapped_crate_type: `CrateInfo.wrapped_crate_type`, or None.
        package_name: The cargo package name.
        target_name: The cargo target name.

    Returns:
        A `(kind, binary_id)` tuple.
    """
    if wrapped_crate_type in _LIB_CRATE_TYPES:
        # There can only be one library per package, so the package name is unique.
        return "lib", package_name
    if wrapped_crate_type == "bin":
        return "bin", "{}::bin/{}".format(package_name, target_name)
    return "test", "{}::{}".format(package_name, target_name)

def validate_binaries(binaries):
    """Checks the one invariant nextest would not report itself.

    `rust-binaries` is a JSON object keyed by binary id, so a duplicate id silently collapses
    an entry and every test in the dropped binary vanishes with no error anywhere. That has to
    be caught at analysis time, naming the offending targets.

    Package ids are deliberately *not* checked: several test binaries in one Bazel package
    legitimately belong to one cargo package, which is exactly how cargo models a lib unit test
    and its integration tests. `cargo_metadata_json` emits one entry per distinct package.

    Returned rather than raised so the logic stays unit-testable.

    Args:
        binaries: A list of structs as returned by `binary_entry`.

    Returns:
        A list of human-readable error strings; empty when everything is consistent.
    """
    errors = []
    seen = {}
    for binary in binaries:
        if binary.binary_id in seen:
            errors.append((
                "targets {} and {} both map to nextest binary id {}, which would silently " +
                "drop one of them. Disambiguate with " +
                "binary_ids = {{\"{}\": \"<unique id>\"}}."
            ).format(
                seen[binary.binary_id],
                binary.label,
                repr(binary.binary_id),
                binary.label.split(":")[-1],
            ))
        else:
            seen[binary.binary_id] = binary.label
    return errors

def binary_entry(
        *,
        label,
        rlocation_path,
        package_name,
        package_version,
        crate_name,
        target_name,
        wrapped_crate_type,
        edition,
        binary_id_override = None,
        package_fields = {}):
    """Builds the per-test-binary record both documents are derived from.

    Args:
        label: The inner test target's label, used only in error messages.
        rlocation_path: Runfiles-root-relative path of the test binary.
        package_name: The cargo package name.
        package_version: The cargo package version.
        crate_name: The Rust crate name.
        target_name: The cargo target name.
        wrapped_crate_type: `CrateInfo.wrapped_crate_type`, or None.
        edition: The Rust edition.
        binary_id_override: Explicit binary id, or None to derive one.
        package_fields: Extra `CARGO_PKG_*` values keyed by cargo metadata field name.

    Returns:
        A struct consumed by `binaries_metadata_json` and `cargo_metadata_json`.
    """
    version = package_version or DEFAULT_PACKAGE_VERSION
    manifest_dir = manifest_dir_for(rlocation_path)
    kind, derived_id = binary_kind_and_id(wrapped_crate_type, package_name, target_name)
    return struct(
        binary_id = binary_id_override or derived_id,
        binary_name = crate_name if kind == "lib" else target_name,
        binary_path = "{}/{}".format(FAKE_TARGET_DIR, rlocation_path),
        crate_name = crate_name,
        edition = normalize_edition(edition),
        kind = kind,
        label = label,
        manifest_dir = manifest_dir,
        package_fields = package_fields,
        package_id = package_id_for(manifest_dir, package_name, version),
        package_name = package_name,
        package_version = version,
        rlocation_path = rlocation_path,
    )

def _libdir():
    # `unavailable` is the honest and the cheap answer. The libdir's only consumer is
    # `RustBuildMeta::dylib_paths()`, which appends the rustc sysroot lib directory to the
    # platform dynamic-library search path; when it is unknown, nextest logs "failed to detect
    # the rustc libdir" and carries on. Nothing breaks, because rules_rust links libstd
    # statically by default, nextest runs each binary at its real runfiles path so $ORIGIN
    # rpaths still resolve, and the runner prepends the runfiles library directories itself.
    # Reporting `available` would require an absolute machine path in a build artifact, which
    # is exactly what this design exists to avoid.
    return {"reason": "not-in-archive", "status": "unavailable"}

def binaries_metadata_json(*, binaries, target_triple):
    """Renders the `--binaries-metadata` document (nextest's `BinaryListSummary`).

    Args:
        binaries: A list of `binary_entry` structs.
        target_triple: The Rust target triple the binaries were built for.

    Returns:
        The document as a JSON string.
    """
    platform = {"libdir": _libdir(), "platform": target_triple}
    return json.encode_indent(
        {
            "rust-binaries": {
                binary.binary_id: {
                    "binary-id": binary.binary_id,
                    "binary-name": binary.binary_name,
                    "binary-path": binary.binary_path,
                    "build-platform": "target",
                    "kind": binary.kind,
                    "package-id": binary.package_id,
                }
                for binary in sorted(binaries, key = lambda binary: binary.binary_id)
            },
            "rust-build-meta": {
                # Relative dylib search directories. Left empty: the runner owns the dynamic
                # library search path, because it knows the runfiles layout and nextest does not.
                "base-output-directories": [],
                "build-script-out-dirs": {},
                "linked-paths": [],
                "non-test-binaries": {},
                "platforms": {
                    "host": platform,
                    "targets": [platform],
                },
                # Superseded by "platforms", emitted for tolerance of older nextest versions.
                "target-platforms": [{"triple": target_triple}],
                "target-directory": FAKE_TARGET_DIR,
            },
        },
        indent = "  ",
    ) + "\n"

def _package(binary):
    fields = binary.package_fields
    return {
        "authors": fields.get("authors", []),
        "categories": [],
        "default_run": None,
        "dependencies": [],
        "description": fields.get("description"),
        "documentation": None,
        "edition": binary.edition,
        # nextest looks packages up by id and reads their manifest path and CARGO_PKG_*
        # metadata; it never resolves the dependency graph, so an empty one is sufficient.
        "features": {},
        "homepage": fields.get("homepage"),
        "id": binary.package_id,
        "keywords": [],
        "license": fields.get("license"),
        "license_file": fields.get("license_file"),
        "links": None,
        "manifest_path": "{}/Cargo.toml".format(binary.manifest_dir),
        "metadata": None,
        "name": binary.package_name,
        "publish": None,
        "readme": None,
        "repository": fields.get("repository"),
        "rust_version": None,
        # A path package, as opposed to a registry or git one.
        "source": None,
        "targets": [{
            "crate_types": ["lib"],
            "doc": True,
            "doctest": False,
            "edition": binary.edition,
            "kind": ["lib"],
            "name": binary.crate_name,
            "src_path": "{}/src/lib.rs".format(binary.manifest_dir),
            "test": True,
        }],
        "version": binary.package_version,
    }

def cargo_metadata_json(*, binaries):
    """Renders the `--cargo-metadata` document (`cargo metadata --format-version 1`).

    Args:
        binaries: A list of `binary_entry` structs. Several binaries may share one package.

    Returns:
        The document as a JSON string.
    """
    packages = {}
    for binary in binaries:
        # Several test binaries can belong to one cargo package; the first wins, and
        # validate_binaries has already rejected genuine conflicts.
        packages.setdefault(binary.package_id, binary)

    package_ids = sorted(packages)
    return json.encode_indent(
        {
            "build_directory": None,
            "packages": [_package(packages[package_id]) for package_id in package_ids],
            # As emitted by `cargo metadata --no-deps`. guppy reads
            # `metadata.resolve.map(...).unwrap_or_default()`, so a null resolve yields a graph
            # with no edges -- all nextest needs, since it only looks packages up by id.
            "resolve": None,
            "target_directory": FAKE_TARGET_DIR,
            "version": 1,
            "workspace_default_members": package_ids,
            "workspace_members": package_ids,
            "workspace_root": FAKE_WORKSPACE_ROOT,
        },
        indent = "  ",
    ) + "\n"
