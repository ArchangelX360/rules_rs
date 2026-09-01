//! `CARGO_PKG_*` comes from the synthesized cargo metadata, which is populated from the
//! `cargo_package` attribute (and so, in a Cargo workspace, from `DEP_DATA`). nextest
//! overwrites these variables for every test process, so this attribute is the only way to
//! control them.

#[test]
fn cargo_pkg_variables_come_from_the_attribute() {
    assert_eq!(std::env::var("CARGO_PKG_NAME").as_deref(), Ok("my-fixture-crate"));
    assert_eq!(std::env::var("CARGO_PKG_VERSION").as_deref(), Ok("4.5.6"));
    assert_eq!(std::env::var("CARGO_PKG_VERSION_MAJOR").as_deref(), Ok("4"));
    assert_eq!(std::env::var("CARGO_PKG_VERSION_MINOR").as_deref(), Ok("5"));
    assert_eq!(std::env::var("CARGO_PKG_VERSION_PATCH").as_deref(), Ok("6"));
    assert_eq!(
        std::env::var("CARGO_PKG_AUTHORS").as_deref(),
        Ok("Ada <ada@example.com>:Grace <grace@example.com>")
    );
    assert_eq!(std::env::var("CARGO_PKG_DESCRIPTION").as_deref(), Ok("a fixture crate"));
    assert_eq!(std::env::var("CARGO_PKG_LICENSE").as_deref(), Ok("Apache-2.0"));
}
