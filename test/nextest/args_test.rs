//! `args` is a native attribute that Bazel appends to the test's argv at run time. The rule
//! must not also embed it in the plan, or every filter would be applied twice.

#[test]
fn selected_by_args() {}

#[test]
fn not_selected_by_args() {
    panic!("the target's args should have filtered this test out");
}
