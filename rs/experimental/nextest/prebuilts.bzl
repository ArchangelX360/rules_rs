"""Prebuilt `cargo-nextest` archives.

Five archives cover the six exec platforms `rules_rs` supports:

* the Apple archive is a universal binary that runs on both `x86_64` and `arm64` macOS, and
* the Linux archives are statically linked musl builds, so they run on glibc systems too and
  are not subject to the glibc 2.27 floor of the upstream gnu builds.

Every nextest release publishes a `cargo-nextest-<version>-<triple>.sha256` asset whose body
lists a checksum per archive format. `scripts/update_nextest.sh` reads those to refresh the
`sha256` values below.
"""

NEXTEST_VERSION = "0.9.143"

NEXTEST_PREBUILTS = [
    struct(
        repo = "cargo_nextest_linux_x86_64",
        archive_triple = "x86_64-unknown-linux-musl",
        platforms = [("linux", "x86_64")],
        sha256 = "6d891c18105ec2d33f6e441a4f92b7ccab47ba263e22055c8bb66884243f3389",
        windows = False,
    ),
    struct(
        repo = "cargo_nextest_linux_aarch64",
        archive_triple = "aarch64-unknown-linux-musl",
        platforms = [("linux", "aarch64")],
        sha256 = "0560ce0ce017f368c54b5db86588370fc03b470985490fa81200e62a657dda05",
        windows = False,
    ),
    struct(
        repo = "cargo_nextest_macos",
        archive_triple = "universal-apple-darwin",
        platforms = [("macos", "x86_64"), ("macos", "aarch64")],
        sha256 = "4830d430411148d17602a75cc880bfb4dc8dac153dea59a48a2ef4cc93577f07",
        windows = False,
    ),
    struct(
        repo = "cargo_nextest_windows_x86_64",
        archive_triple = "x86_64-pc-windows-msvc",
        platforms = [("windows", "x86_64")],
        sha256 = "c42a1dbde532da06dc9b4a43d44fd0ce668b836c2ab7388410f10ff9834476a2",
        windows = True,
    ),
    struct(
        repo = "cargo_nextest_windows_aarch64",
        archive_triple = "aarch64-pc-windows-msvc",
        platforms = [("windows", "aarch64")],
        sha256 = "c89ca8168a6cb1aff6e38b3551bedc9b924477aa983d947b99038c5bed6438ba",
        windows = True,
    ),
]

# `.tar.gz` is used for every platform, including Windows, so a single code path handles all
# five archives and the executable mode bit survives extraction.
_URL_TEMPLATE = "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-{version}/cargo-nextest-{version}-{triple}.tar.gz"

def nextest_url(version, archive_triple):
    """Returns the release URL for one prebuilt archive.

    Args:
        version: cargo-nextest version, e.g. `"0.9.143"`.
        archive_triple: Archive triple, e.g. `"x86_64-unknown-linux-musl"`.

    Returns:
        The download URL as a string.
    """
    return _URL_TEMPLATE.format(version = version, triple = archive_triple)

def nextest_binary_name(prebuilt):
    """Returns the name of the executable inside one prebuilt archive.

    Args:
        prebuilt: An entry of `NEXTEST_PREBUILTS`.

    Returns:
        `"cargo-nextest.exe"` on Windows, `"cargo-nextest"` elsewhere.
    """
    return "cargo-nextest.exe" if prebuilt.windows else "cargo-nextest"

def nextest_repo_names():
    """Returns the names of every repository the `nextest` extension creates.

    Returns:
        A list of repository name strings.
    """
    return [prebuilt.repo for prebuilt in NEXTEST_PREBUILTS]

def nextest_archive_triples():
    """Returns the archive triples that `nextest.version(sha256 = ...)` accepts as keys.

    Returns:
        A sorted list of archive triple strings.
    """
    return sorted([prebuilt.archive_triple for prebuilt in NEXTEST_PREBUILTS])
