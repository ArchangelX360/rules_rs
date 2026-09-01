//! Integration-test shape (`rust_test(srcs = ...)`), which nextest reports with a
//! `<package>::<target>` binary id rather than the bare package name.

#[test]
fn integration_one() {
    assert_eq!(mylib::add(1, 1), 2);
}

#[test]
fn integration_two() {
    assert!(mylib::add(0, 0) == 0);
}
