// `bitflags::parser::ParseError` implements `std::error::Error` only when bitflags is
// built with its `std` feature. `std` is requested solely by this package's
// `[dev-dependencies]` entry, so this file compiles only if the test target links a
// bitflags that has it -- and the production binary must not.
fn assert_std_error<E: std::error::Error>() {}

#[test]
fn bitflags_std_feature_is_enabled_for_tests() {
    assert_std_error::<bitflags::parser::ParseError>();
}
