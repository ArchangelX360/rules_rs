//! Used to check that `filter_expr` and `--test_filter` actually narrow the run.

#[test]
fn keep_me_one() {}

#[test]
fn keep_me_two() {}

#[test]
fn drop_me() {
    panic!("this test is excluded by the target's filter_expr and must not run");
}
