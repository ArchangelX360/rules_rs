//! Deliberately failing, so the JUnit report can be asserted on. Tagged `manual`, and run
//! only as a subprocess of `junit_report_test`.

#[test]
fn this_one_passes() {}

#[test]
fn this_one_fails() {
    panic!("deliberate failure, asserted on by junit_report_test");
}
