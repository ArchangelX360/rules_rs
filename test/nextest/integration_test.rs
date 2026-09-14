//! Integration-test shape (`rust_test(srcs = ...)`), which nextest gives a
//! `<package>::<target>` binary id.

#[test]
fn integration_one() {
    assert_eq!(mylib::add(1, 1), 2);
}

#[test]
fn integration_two() {
    assert!(mylib::add(0, 0) == 0);
}
