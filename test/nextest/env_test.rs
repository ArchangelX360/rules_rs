//! `env`, `env_inherit` and `args` all have to survive the extra hop through the runner and
//! nextest. `env_inherit` in particular is missing from the existing miri_test rule.

#[test]
fn env_attribute_reaches_the_test() {
    assert_eq!(std::env::var("FROM_ENV_ATTR").as_deref(), Ok("set-by-rule"));
}

#[test]
fn env_inherit_reaches_the_test() {
    assert_eq!(std::env::var("RULES_RS_NEXTEST_E2E_INHERITED").as_deref(), Ok("from-outside"));
}

#[test]
fn tmpdir_points_at_test_tmpdir() {
    let tmp = std::env::var("TMPDIR")
        .or_else(|_| std::env::var("TMP"))
        .or_else(|_| std::env::var("TEMP"))
        .expect("a temporary directory");
    assert!(!tmp.is_empty());
    assert!(std::path::Path::new(&tmp).is_dir(), "{tmp} should exist");
}
