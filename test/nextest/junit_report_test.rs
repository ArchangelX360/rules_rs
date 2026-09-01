//! Asserts on the JUnit report a real nextest run produces.
//!
//! `rust_test` gives Bazel a bare libtest binary, so `XML_OUTPUT_FILE` goes unused and Bazel
//! synthesizes a stub report from the test log. The whole point of this rule is that the
//! report is real, so it is worth asserting on rather than trusting.
//!
//! `failing_test` is run as a subprocess with a temporary `XML_OUTPUT_FILE`. It is a `data`
//! dependency, so its runfiles are merged into this test's and the two share one tree.

use std::path::PathBuf;
use std::process::Command;

#[test]
fn junit_report_describes_each_test() {
    let workspace = std::env::var("TEST_WORKSPACE").expect("TEST_WORKSPACE");
    let runfiles = PathBuf::from(std::env::var("TEST_SRCDIR").expect("TEST_SRCDIR"));

    // `$(rootpath)` on an executable target resolves to the executable. The rule names its
    // plan after the executable, so the plan is derived rather than expanded separately.
    let executable = std::env::var("FAILING_TEST").expect("FAILING_TEST");
    let plan = format!("{workspace}/{executable}.nextest-plan");

    let tmp = PathBuf::from(std::env::var("TEST_TMPDIR").expect("TEST_TMPDIR")).join("junit");
    std::fs::create_dir_all(&tmp).expect("scratch dir");
    let xml_path = tmp.join("report.xml");

    let status = Command::new(runfiles.join(&workspace).join(&executable))
        .env("RULES_RS_NEXTEST_PLAN", &plan)
        .env("TEST_SRCDIR", &runfiles)
        .env("RUNFILES_DIR", &runfiles)
        .env("TEST_TMPDIR", &tmp)
        .env("XML_OUTPUT_FILE", &xml_path)
        .env("TEST_TARGET", "//nextest:failing_test")
        .env_remove("TEST_TOTAL_SHARDS")
        .env_remove("TEST_SHARD_INDEX")
        .env_remove("TESTBRIDGE_TEST_ONLY")
        .env_remove("TEST_PREMATURE_EXIT_FILE")
        .env_remove("TEST_INFRASTRUCTURE_FAILURE_FILE")
        .env_remove("TEST_UNDECLARED_OUTPUTS_DIR")
        .status()
        .expect("failed to run the nested nextest test");

    // A test failure must surface as a plain non-zero exit, not as nextest's own code 100.
    assert_eq!(status.code(), Some(1), "expected a test failure to exit 1");

    let xml = std::fs::read_to_string(&xml_path)
        .unwrap_or_else(|err| panic!("no JUnit report at {}: {err}", xml_path.display()));

    // One <testsuite> per binary and one <testcase> per test: the structure rust_test cannot
    // produce, since Bazel only sees a single opaque process.
    assert!(xml.contains("<testsuite "), "no testsuite element in:\n{xml}");
    assert!(xml.contains("name=\"this_one_fails\""), "missing the failing test:\n{xml}");
    assert!(xml.contains("name=\"this_one_passes\""), "missing the passing test:\n{xml}");
    assert!(xml.contains("<failure"), "no failure element in:\n{xml}");
    assert!(xml.contains("deliberate failure"), "the panic message was not captured:\n{xml}");
    assert!(xml.contains("tests=\"2\""), "expected two tests in:\n{xml}");
    assert!(xml.contains("failures=\"1\""), "expected one failure in:\n{xml}");
    // Named after the Bazel target, so reports stay identifiable once collected.
    assert!(xml.contains("//nextest:failing_test"), "report-name not from TEST_TARGET:\n{xml}");
}
