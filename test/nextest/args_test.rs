//! `args` is a native attribute that Bazel appends to the test's argv at run time. The rule
//! must not pass it again, or every filter is applied twice.

#[test]
fn selected_by_args() {}

#[test]
fn not_selected_by_args() {
    panic!("the target's args should have filtered this test out");
}
