//! The behavioural parity check that matters most.
//!
//! rules_rust's `rust_test` sets `CARGO_MANIFEST_DIR` to the crate's package directory. Under
//! nextest the working directory is also the package directory, and both must resolve to the
//! same place, so that data files can be read by a package-relative path just as they can
//! under cargo.

use std::path::Path;

#[test]
fn cwd_matches_cargo_manifest_dir() {
    let cwd = std::env::current_dir().expect("a working directory");
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");

    // Compare canonicalized paths: on Windows nextest canonicalizes the remap roots, which
    // yields a verbatim \\?\ prefix, so a string comparison would differ from rust_test.
    let cwd = cwd.canonicalize().expect("canonical cwd");
    let manifest_dir = Path::new(&manifest_dir).canonicalize().expect("canonical manifest dir");
    assert_eq!(cwd, manifest_dir, "cwd and CARGO_MANIFEST_DIR must agree");
}

#[test]
fn cwd_is_the_bazel_package_directory() {
    let cwd = std::env::current_dir().expect("a working directory");
    assert!(
        cwd.ends_with("nextest"),
        "expected the working directory to be the Bazel package directory, got {}",
        cwd.display()
    );
}

#[test]
fn reads_a_data_file_by_relative_path() {
    // No rlocation needed: the working directory is the package directory, as under cargo.
    let contents = std::fs::read_to_string("fixtures/data.txt").expect("fixtures/data.txt");
    assert_eq!(contents.trim(), "hello from a data file");
}

#[test]
fn nextest_marks_the_environment() {
    assert_eq!(std::env::var("NEXTEST").as_deref(), Ok("1"));
    assert!(std::env::var("NEXTEST_RUN_ID").is_ok());
}
