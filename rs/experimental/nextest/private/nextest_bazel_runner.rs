//! Bazel test driver for `cargo-nextest`.
//!
//! Bazel executes this binary as the test. It reads a plan file naming the nextest binary and
//! the generated metadata, translates the Bazel test protocol into nextest flags and
//! configuration, runs nextest, and maps the result back onto Bazel's expectations.
//!
//! Deliberately `std`-only and free of any shell, so one implementation covers Linux, macOS
//! and Windows on x86_64 and aarch64.

use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

/// Plan format version understood by this runner. Must match `PLAN_VERSION` in constants.bzl.
const PLAN_VERSION: &str = "1";

/// nextest exit codes, from nextest-metadata/src/exit_codes.rs.
const NEXTEST_TEST_RUN_FAILED: i32 = 100;
const NEXTEST_NO_TESTS_RUN: i32 = 4;

fn main() {
    let code = match run() {
        Ok(code) => code,
        Err(err) => {
            eprintln!("nextest runner: {err}");
            record_infrastructure_failure(&err);
            1
        }
    };
    std::process::exit(code);
}

// ---------------------------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------------------------

fn var(name: &str) -> Option<String> {
    match env::var(name) {
        Ok(value) if !value.is_empty() => Some(value),
        _ => None,
    }
}

/// Writes a diagnostic to `TEST_INFRASTRUCTURE_FAILURE_FILE`, telling Bazel that the failure
/// is in the harness rather than in the code under test.
fn record_infrastructure_failure(message: &str) {
    if let Some(path) = var("TEST_INFRASTRUCTURE_FAILURE_FILE") {
        let _ = fs::write(path, format!("nextest runner: {message}\n"));
    }
}

// ---------------------------------------------------------------------------------------------
// Runfiles
// ---------------------------------------------------------------------------------------------

/// Resolution of runfiles paths to real filesystem paths.
///
/// nextest needs a real directory tree: every `binary-path` must be an existing file and every
/// test's working directory must be an existing directory. When Bazel provides only a manifest
/// (Windows without symlink privileges, `--noenable_runfiles`), the tree is materialized under
/// `TEST_TMPDIR` so the rule works without requiring any repo-wide flag change.
struct Runfiles {
    root: PathBuf,
}

impl Runfiles {
    /// Locates the runfiles, materializing them from a manifest if there is no usable tree.
    ///
    /// `canary` is a runfiles path that must resolve; the plan file is used, since it is always
    /// required. A staged directory is preferred whenever it actually contains that file, even
    /// when `RUNFILES_MANIFEST_ONLY` is set: Bazel sets that variable under
    /// `--noenable_runfiles` but still stages runfiles as action inputs on platforms with
    /// symlinks, and it does not always set `RUNFILES_MANIFEST_FILE` to go with it.
    fn discover(scratch: &Path, canary: &str) -> Result<Self, String> {
        let mut tried = Vec::new();

        let mut candidates: Vec<PathBuf> = ["RUNFILES_DIR", "TEST_SRCDIR"]
            .iter()
            .filter_map(|name| var(name))
            .map(PathBuf::from)
            .collect();
        if let Some(argv0) = env::args_os().next() {
            let mut path = PathBuf::from(argv0);
            if let Some(name) = path.file_name() {
                let mut name = name.to_os_string();
                name.push(".runfiles");
                path.set_file_name(name);
            }
            candidates.push(path);
        }

        for dir in candidates {
            if dir.is_dir() && dir.join(canary).exists() {
                return Ok(Self { root: dir });
            }
            tried.push(format!("directory {}", dir.display()));
        }

        // No usable tree, so build one from a manifest.
        let mut manifests: Vec<PathBuf> = Vec::new();
        if let Some(manifest) = var("RUNFILES_MANIFEST_FILE") {
            manifests.push(PathBuf::from(manifest));
        }
        for name in ["RUNFILES_DIR", "TEST_SRCDIR"] {
            if let Some(dir) = var(name) {
                manifests.push(PathBuf::from(&dir).join("MANIFEST"));
                manifests.push(PathBuf::from(format!("{dir}_manifest")));
            }
        }
        if let Some(argv0) = env::args_os().next() {
            let mut path = PathBuf::from(argv0);
            if let Some(name) = path.file_name() {
                let mut name = name.to_os_string();
                name.push(".runfiles_manifest");
                path.set_file_name(name);
            }
            manifests.push(path);
        }

        for manifest in manifests {
            if manifest.is_file() {
                let root = scratch.join("runfiles");
                materialize(&manifest, &root)?;
                if !root.join(canary).exists() {
                    return Err(format!(
                        "materialized runfiles from {} but {canary} is still missing",
                        manifest.display()
                    ));
                }
                return Ok(Self { root });
            }
            tried.push(format!("manifest {}", manifest.display()));
        }

        Err(format!(
            "could not locate runfiles containing {canary}. Tried:\n  {}",
            tried.join("\n  ")
        ))
    }

    fn rlocation(&self, path: &str) -> PathBuf {
        self.root.join(path)
    }

    /// Resolves a runfiles path, failing when it is absent so the error names the missing file
    /// rather than surfacing later as an opaque nextest error.
    fn require(&self, path: &str, what: &str) -> Result<PathBuf, String> {
        let resolved = self.rlocation(path);
        if resolved.exists() {
            Ok(resolved)
        } else {
            Err(format!(
                "{what} is missing from runfiles: {path} (looked in {})",
                self.root.display()
            ))
        }
    }
}

/// Parses a runfiles manifest and builds a real directory tree from it.
///
/// Handles both manifest dialects: the plain `<rlocation> <path>` form split at the first
/// space, and the escaped form, marked by a leading space, in which `\n` and `\b` stand for a
/// newline and a backslash. An empty target means an intentionally empty file.
fn materialize(manifest: &Path, root: &Path) -> Result<(), String> {
    let contents = fs::read_to_string(manifest)
        .map_err(|err| format!("failed to read runfiles manifest {}: {err}", manifest.display()))?;

    for line in contents.lines() {
        if line.is_empty() {
            continue;
        }
        let (rlocation, target) = if let Some(rest) = line.strip_prefix(' ') {
            let (key, value) = split_escaped(rest);
            (unescape(&key), unescape(&value))
        } else {
            match line.split_once(' ') {
                Some((key, value)) => (key.to_owned(), value.to_owned()),
                None => (line.to_owned(), String::new()),
            }
        };

        let dest = root.join(&rlocation);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)
                .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
        }
        if dest.exists() {
            continue;
        }
        if target.is_empty() {
            fs::File::create(&dest)
                .map_err(|err| format!("failed to create {}: {err}", dest.display()))?;
            continue;
        }
        // Hard links keep materialization cheap; copying is the fallback across devices and
        // for filesystems that do not support them.
        if fs::hard_link(&target, &dest).is_err() {
            fs::copy(&target, &dest).map_err(|err| {
                format!("failed to stage {target} as {}: {err}", dest.display())
            })?;
        }
    }
    Ok(())
}

/// Splits an escaped manifest line at the first unescaped space.
fn split_escaped(line: &str) -> (String, String) {
    let bytes = line.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index += 2,
            b' ' => return (line[..index].to_owned(), line[index + 1..].to_owned()),
            _ => index += 1,
        }
    }
    (line.to_owned(), String::new())
}

fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('b') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Plan file
// ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct Plan {
    single: BTreeMap<String, String>,
    repeated: BTreeMap<String, Vec<String>>,
}

const SINGLE_KEYS: &[&str] = &[
    "version",
    "nextest",
    "binaries_metadata",
    "cargo_metadata",
    "workspace_manifest",
    "user_config",
    "profile",
    "fail_fast",
    "test_threads",
    "filter_expr",
    "allow_no_tests",
];
const REPEATED_KEYS: &[&str] = &["dylib_dir", "nextest_arg"];

impl Plan {
    fn load(path: &Path) -> Result<Self, String> {
        let contents = fs::read_to_string(path)
            .map_err(|err| format!("failed to read plan {}: {err}", path.display()))?;
        let mut plan = Plan::default();
        for (number, line) in contents.lines().enumerate() {
            if line.is_empty() {
                continue;
            }
            let (key, value) = line.split_once('\t').ok_or_else(|| {
                format!("plan {}:{}: expected a tab-separated key and value", path.display(), number + 1)
            })?;
            if REPEATED_KEYS.contains(&key) {
                plan.repeated.entry(key.to_owned()).or_default().push(value.to_owned());
            } else if SINGLE_KEYS.contains(&key) {
                plan.single.insert(key.to_owned(), value.to_owned());
            } else {
                // A key this runner does not know means the rule and the runner disagree,
                // which is a bug rather than something to paper over.
                return Err(format!(
                    "plan {}:{}: unknown key {key:?}. The nextest rule and runner are out of sync.",
                    path.display(),
                    number + 1
                ));
            }
        }
        match plan.single.get("version").map(String::as_str) {
            Some(PLAN_VERSION) => {}
            other => {
                return Err(format!(
                    "plan {} has version {:?}, this runner understands {PLAN_VERSION:?}",
                    path.display(),
                    other.unwrap_or("<missing>")
                ));
            }
        }
        Ok(plan)
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.single.get(key).map(String::as_str)
    }

    fn require(&self, key: &str) -> Result<&str, String> {
        self.get(key).ok_or_else(|| format!("plan is missing the required key {key:?}"))
    }

    fn list(&self, key: &str) -> &[String] {
        self.repeated.get(key).map(Vec::as_slice).unwrap_or(&[])
    }

    fn flag(&self, key: &str) -> bool {
        self.get(key) == Some("true")
    }
}

// ---------------------------------------------------------------------------------------------
// TOML
// ---------------------------------------------------------------------------------------------

/// Escapes a string as a TOML basic string.
///
/// Basic strings rather than literal strings, because Windows paths are full of backslashes
/// and `TEST_TMPDIR` can contain almost anything.
fn toml_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\u{:04X}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Builds the nextest configuration for this run.
///
/// `store.dir` and `junit.path` are absolute on purpose. nextest resolves `store.dir` as
/// `workspace_root.join(store.dir)` and `junit.path` as `store_dir.join(profile).join(path)`,
/// and Rust's `Path::join` replaces the whole path when its argument is absolute. So both land
/// exactly where Bazel wants them: no writable workspace is needed, and the JUnit report is
/// written straight to `XML_OUTPUT_FILE` with no copy step.
fn write_config(
    path: &Path,
    profile: &str,
    store_dir: &Path,
    xml_output: Option<&str>,
    fail_fast: bool,
    global_timeout_secs: Option<u64>,
) -> Result<(), String> {
    let mut toml = String::new();
    let _ = writeln!(toml, "[store]");
    let _ = writeln!(toml, "dir = {}", toml_string(&store_dir.to_string_lossy()));

    for name in profile_chain(profile) {
        let _ = writeln!(toml, "\n[profile.{name}]");
        // libtest runs every test in the binary, while nextest stops at the first failure.
        // Matching rust_test means turning fail-fast off, which also keeps the JUnit report
        // complete instead of truncated at the first failure.
        let _ = writeln!(toml, "fail-fast = {fail_fast}");
        let _ = writeln!(toml, "status-level = \"fail\"");
        let _ = writeln!(toml, "final-status-level = \"fail\"");
        let _ = writeln!(toml, "failure-output = \"immediate\"");
        let _ = writeln!(toml, "success-output = \"never\"");
        if let Some(secs) = global_timeout_secs {
            // Self-terminating a little before Bazel's deadline is what turns a timeout into a
            // report: nextest kills the run and flushes the JUnit XML, where a Bazel
            // SIGTERM/SIGKILL would leave no report at all.
            let _ = writeln!(toml, "global-timeout = \"{secs}s\"");
        }

        if let Some(xml) = xml_output {
            let _ = writeln!(toml, "\n[profile.{name}.junit]");
            let _ = writeln!(toml, "path = {}", toml_string(xml));
            let _ = writeln!(
                toml,
                "report-name = {}",
                toml_string(&var("TEST_TARGET").unwrap_or_else(|| "nextest-run".to_owned()))
            );
            let _ = writeln!(toml, "store-success-output = false");
            let _ = writeln!(toml, "store-failure-output = true");
            // "ignored" rather than "all": it reports #[ignore]d tests as skipped, which is
            // what a libtest XML conventionally shows, without also reporting every test that
            // a filter or a shard partition excluded. Under "all" each shard would list the
            // whole suite, so a merged report would show one entry per test per shard.
            let _ = writeln!(toml, "report-skipped = \"ignored\"");
        }
    }

    fs::write(path, toml).map_err(|err| format!("failed to write {}: {err}", path.display()))
}

/// Settings must be declared on the profile in use; `default` is also emitted so that a
/// custom profile inheriting from it still picks up the Bazel behaviour.
fn profile_chain(profile: &str) -> Vec<&str> {
    if profile == "default" {
        vec!["default"]
    } else {
        vec!["default", profile]
    }
}

// ---------------------------------------------------------------------------------------------
// Test filters
// ---------------------------------------------------------------------------------------------

/// Filterset function names, used to tell a filterset from a plain substring filter.
const FILTERSET_PREFIXES: &[&str] = &[
    "test(", "package(", "deps(", "rdeps(", "kind(", "binary(", "binary_id(", "platform(",
    "test_id(", "all()", "none()", "not ", "not(",
];

/// Interpretation of `--test_filter` / `TESTBRIDGE_TEST_ONLY`.
enum Filter {
    /// A nextest filterset expression, passed with `-E`.
    Filterset(String),
    /// A substring match, passed as a positional filter, matching libtest and so `rust_test`.
    Substring(String),
    /// An exact test name, passed after `--` as `--exact`.
    Exact(String),
}

fn parse_filter(value: &str) -> Filter {
    if let Some(rest) = value.strip_prefix("expr:") {
        return Filter::Filterset(rest.to_owned());
    }
    if let Some(rest) = value.strip_prefix("exact:") {
        return Filter::Exact(rest.to_owned());
    }
    if let Some(rest) = value.strip_prefix("substring:") {
        return Filter::Substring(rest.to_owned());
    }
    let trimmed = value.trim_start();
    if FILTERSET_PREFIXES.iter().any(|prefix| trimmed.starts_with(prefix)) {
        Filter::Filterset(value.to_owned())
    } else {
        Filter::Substring(value.to_owned())
    }
}

// ---------------------------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------------------------

fn dylib_path_var() -> &'static str {
    if cfg!(target_os = "windows") {
        "PATH"
    } else if cfg!(target_os = "macos") {
        "DYLD_FALLBACK_LIBRARY_PATH"
    } else {
        "LD_LIBRARY_PATH"
    }
}

fn run() -> Result<i32, String> {
    let tmp = var("TEST_TMPDIR").map(PathBuf::from).unwrap_or_else(env::temp_dir);
    let scratch = tmp.join("nextest");
    fs::create_dir_all(&scratch)
        .map_err(|err| format!("failed to create {}: {err}", scratch.display()))?;

    let plan_path = var("RULES_RS_NEXTEST_PLAN")
        .ok_or("RULES_RS_NEXTEST_PLAN is not set; the nextest rule sets it via RunEnvironmentInfo")?;
    let runfiles = Runfiles::discover(&scratch, &plan_path)?;
    let plan = Plan::load(&runfiles.require(&plan_path, "the nextest plan")?)?;

    // Announce sharding support before anything can fail: without this file Bazel assumes the
    // target ignores sharding and silently runs the whole suite in every shard.
    let sharding = sharding()?;
    if sharding.is_some() {
        if let Some(status_file) = var("TEST_SHARD_STATUS_FILE") {
            fs::write(&status_file, b"")
                .map_err(|err| format!("failed to touch {status_file}: {err}"))?;
        }
    }

    let premature_exit_file = var("TEST_PREMATURE_EXIT_FILE");
    if let Some(path) = &premature_exit_file {
        fs::write(path, b"")
            .map_err(|err| format!("failed to create {path}: {err}"))?;
    }

    let nextest = runfiles.require(plan.require("nextest")?, "the cargo-nextest binary")?;
    let binaries_metadata =
        runfiles.require(plan.require("binaries_metadata")?, "the binaries metadata")?;
    let cargo_metadata = runfiles.require(plan.require("cargo_metadata")?, "the cargo metadata")?;

    // nextest requires a manifest at the workspace root. It only checks that the file exists
    // and never parses it, so a stub is enough. It is normally supplied as a runfiles root
    // symlink; create it here when the tree was materialized from a manifest.
    let root_manifest = runfiles.root.join("Cargo.toml");
    if !root_manifest.exists() {
        fs::write(&root_manifest, b"[workspace]\n").map_err(|err| {
            format!(
                "failed to create the stub workspace manifest {}: {err}",
                root_manifest.display()
            )
        })?;
    }

    let profile = plan.get("profile").unwrap_or("default").to_owned();
    let store_dir = var("TEST_UNDECLARED_OUTPUTS_DIR")
        .map(|dir| PathBuf::from(dir).join("nextest"))
        .unwrap_or_else(|| scratch.join("store"));
    fs::create_dir_all(&store_dir)
        .map_err(|err| format!("failed to create {}: {err}", store_dir.display()))?;

    let config_path = scratch.join("nextest-bazel.toml");
    write_config(
        &config_path,
        &profile,
        &store_dir,
        var("XML_OUTPUT_FILE").as_deref(),
        plan.flag("fail_fast"),
        global_timeout_secs(),
    )?;

    let mut command = Command::new(&nextest);
    // `nextest` as argv[1] is required when driving the standalone cargo-nextest binary
    // without cargo.
    command.arg("nextest").arg("run");
    command.arg("--config-file").arg(&config_path);
    command.arg("--profile").arg(&profile);
    command.arg("--binaries-metadata").arg(&binaries_metadata);
    command.arg("--cargo-metadata").arg(&cargo_metadata);
    command.arg("--workspace-remap").arg(&runfiles.root);
    command.arg("--target-dir-remap").arg(&runfiles.root);

    if let Some(user_config) = plan.get("user_config") {
        // A tool config sits below --config-file in nextest's precedence chain, so users get
        // profiles, overrides and test groups while the Bazel-owned junit and store settings
        // still win.
        let resolved = runfiles.require(user_config, "the nextest config file")?;
        let mut arg = OsString::from("rules_rs:");
        arg.push(resolved.as_os_str());
        command.arg("--tool-config-file").arg(arg);
    }

    if !plan.flag("fail_fast") {
        command.arg("--no-fail-fast");
    }
    if let Some(threads) = plan.get("test_threads") {
        command.arg("--test-threads").arg(threads);
    }
    if let Some((index, total)) = sharding {
        // nextest partitions are 1-based, Bazel shard indices are 0-based.
        command.arg("--partition").arg(format!("hash:{}/{}", index + 1, total));
    }
    if let Some(expr) = plan.get("filter_expr") {
        command.arg("-E").arg(expr);
    }
    for arg in plan.list("nextest_arg") {
        command.arg(arg);
    }

    let mut positional: Vec<OsString> = Vec::new();
    let mut libtest: Vec<OsString> = Vec::new();

    if let Some(value) = var("TESTBRIDGE_TEST_ONLY") {
        match parse_filter(&value) {
            Filter::Filterset(expr) => {
                command.arg("-E").arg(expr);
            }
            Filter::Substring(text) => positional.push(OsString::from(text)),
            Filter::Exact(name) => {
                libtest.push(OsString::from("--exact"));
                libtest.push(OsString::from(name));
            }
        }
    }

    // Runtime arguments come from the `args` attribute and `--test_arg`. Bazel appends the
    // `args` attribute itself, so the rule must not embed them in the plan as well.
    //
    // Everything is forwarded after `--`, where nextest emulates the libtest command line:
    // filters there are substring matches by default and exact ones under `--exact`, and
    // `--skip`, `--ignored`, `--include-ignored` and `--nocapture` are accepted natively. That
    // is precisely `rust_test`'s behaviour, and keeping flags and their filters together in
    // one block is what makes `--exact <name>` work. Only arguments nextest does not accept in
    // that position are translated.
    let mut runtime = env::args_os().skip(1);
    while let Some(arg) = runtime.next() {
        let text = arg.to_string_lossy().into_owned();
        if let Some(rest) = text.strip_prefix("--nextest-arg=") {
            // Escape hatch for nextest's own flags, which have no libtest equivalent.
            command.arg(rest);
        } else if let Some(rest) = text.strip_prefix("--test-threads=") {
            command.arg("--test-threads").arg(rest);
        } else if text == "--test-threads" {
            if let Some(value) = runtime.next() {
                command.arg("--test-threads").arg(value);
            }
        } else {
            libtest.push(arg);
        }
    }

    for arg in positional {
        command.arg(arg);
    }
    if !libtest.is_empty() {
        command.arg("--");
        for arg in libtest {
            command.arg(arg);
        }
    }

    configure_environment(&mut command, &plan, &runfiles, &tmp, &scratch)?;

    let status = command
        .status()
        .map_err(|err| format!("failed to run {}: {err}", nextest.display()))?;

    let code = map_exit_status(status, sharding.is_some())?;
    if let Some(path) = &premature_exit_file {
        let _ = fs::remove_file(path);
    }
    Ok(code)
}

/// Reads Bazel's sharding environment.
fn sharding() -> Result<Option<(u64, u64)>, String> {
    let total = match var("TEST_TOTAL_SHARDS") {
        Some(value) => value
            .parse::<u64>()
            .map_err(|err| format!("TEST_TOTAL_SHARDS={value:?} is not a number: {err}"))?,
        None => return Ok(None),
    };
    if total <= 1 {
        return Ok(None);
    }
    let index = var("TEST_SHARD_INDEX")
        .unwrap_or_else(|| "0".to_owned())
        .parse::<u64>()
        .map_err(|err| format!("TEST_SHARD_INDEX is not a number: {err}"))?;
    Ok(Some((index, total)))
}

/// Derives nextest's `global-timeout` from Bazel's deadline, leaving room to write the report.
fn global_timeout_secs() -> Option<u64> {
    let timeout = var("TEST_TIMEOUT")?.parse::<u64>().ok()?;
    if timeout == 0 {
        return None;
    }
    let grace = std::cmp::min(15, std::cmp::max(1, timeout / 10));
    Some(timeout.saturating_sub(grace).max(1))
}

fn configure_environment(
    command: &mut Command,
    plan: &Plan,
    runfiles: &Runfiles,
    tmp: &Path,
    scratch: &Path,
) -> Result<(), String> {
    // Variables that would let cargo's view of the world leak in, or that would fight the
    // flags this runner passes explicitly.
    for name in [
        "CARGO",
        "CARGO_BUILD_TARGET",
        "CARGO_TARGET_DIR",
        "RUST_TARGET_PATH",
        "RUSTC",
        "RUSTFLAGS",
        "NEXTEST_PROFILE",
    ] {
        command.env_remove(name);
    }
    for (key, _) in env::vars() {
        if key.starts_with("CARGO_TARGET_") && key.ends_with("_RUNNER") {
            command.env_remove(key);
        }
    }

    // nextest reads $CARGO_HOME/config.toml and walks every ancestor of its working directory
    // looking for .cargo/config.toml, from which it honours `[env]`, `build.target` and
    // `target.<triple>.runner`. Pointing CARGO_HOME at an empty directory removes the dominant
    // leak, since a developer's ~/.cargo/config.toml is exactly that file.
    let cargo_home = scratch.join("cargo-home");
    fs::create_dir_all(&cargo_home)
        .map_err(|err| format!("failed to create {}: {err}", cargo_home.display()))?;
    command.env("CARGO_HOME", &cargo_home);

    // The same discovery walk starts at the working directory, so nextest runs from an empty
    // scratch directory rather than from the runfiles tree, where a checked-in
    // .cargo/config.toml would otherwise be picked up. Each test's own working directory is
    // unaffected: nextest sets it from the remapped manifest directory.
    let cwd = scratch.join("cwd");
    fs::create_dir_all(&cwd)
        .map_err(|err| format!("failed to create {}: {err}", cwd.display()))?;
    command.current_dir(&cwd);
    check_cargo_config_leaks(&cwd)?;

    for name in ["TMPDIR", "TMP", "TEMP"] {
        command.env(name, tmp);
    }

    command.env("NEXTEST_HIDE_PROGRESS_BAR", "1");
    command.env("NEXTEST_NO_INPUT_HANDLER", "1");
    if var("CARGO_TERM_COLOR").is_none() {
        command.env("CARGO_TERM_COLOR", "never");
    }
    if var("RUST_BACKTRACE").is_none() {
        command.env("RUST_BACKTRACE", "1");
    }

    // nextest runs one process per test, so the profile pattern must vary per process or the
    // profiles overwrite each other. Bazel's own coverage driver usually sets this; only fill
    // it in when it has not.
    if let (Some(coverage_dir), None) = (var("COVERAGE_DIR"), var("LLVM_PROFILE_FILE")) {
        command.env(
            "LLVM_PROFILE_FILE",
            Path::new(&coverage_dir).join("nextest-%p-%m.profraw"),
        );
    }

    // The working directory is no longer the runfiles root, so the runfiles library
    // directories are added explicitly. nextest prepends its own entries and preserves this
    // value, so both sets are searched.
    let dylib_dirs = plan.list("dylib_dir");
    if !dylib_dirs.is_empty() {
        let mut paths: Vec<PathBuf> = dylib_dirs
            .iter()
            .map(|dir| runfiles.rlocation(dir))
            .filter(|dir| dir.is_dir())
            .collect();
        if let Some(existing) = env::var_os(dylib_path_var()) {
            paths.extend(env::split_paths(&existing));
        }
        if let Ok(joined) = env::join_paths(paths.iter().map(|p| p.as_os_str())) {
            command.env(dylib_path_var(), joined);
        }
    }

    Ok(())
}

/// Reports Cargo configuration files that nextest will read despite the isolation above.
///
/// nextest walks every ancestor of its working directory looking for `.cargo/config[.toml]`
/// and honours `[env]`, `build.target` and `target.<triple>.runner` from what it finds. That
/// walk cannot be bounded from outside the process, and Cargo's `[env]` merge is per key, so
/// an ancestor entry cannot be neutralized by asserting anything nearer.
///
/// What is possible is to make it visible: a leak that shows up as a named warning is a
/// support question, whereas a silent one is a mystery. Sandboxed and remotely executed runs
/// never reach a real `.cargo` directory, so this is quiet exactly when it should be.
///
/// Set `RULES_RS_NEXTEST_STRICT_CARGO_CONFIG=1` to turn the warning into an error.
fn check_cargo_config_leaks(cwd: &Path) -> Result<(), String> {
    let strict = var("RULES_RS_NEXTEST_STRICT_CARGO_CONFIG").as_deref() == Some("1");
    let mut found = Vec::new();

    for ancestor in cwd.ancestors() {
        for name in ["config.toml", "config"] {
            let candidate = ancestor.join(".cargo").join(name);
            if !candidate.is_file() {
                continue;
            }
            // A substring check rather than a TOML parse: it keeps the runner dependency-free
            // and only the keys nextest actually reads are worth reporting.
            let interesting = match fs::read_to_string(&candidate) {
                Ok(text) => text.lines().any(|line| {
                    let line = line.trim_start();
                    line.starts_with("[env]")
                        || line.starts_with("[env.")
                        || line.starts_with("runner")
                        || line.starts_with("target =")
                }),
                // Unreadable is worth reporting too, since nextest may still read it.
                Err(_) => true,
            };
            if interesting {
                found.push(candidate.display().to_string());
            }
            break;
        }
    }

    if found.is_empty() {
        return Ok(());
    }
    let message = format!(
        "cargo-nextest reads Cargo configuration from every ancestor of its working \
         directory, and these files set keys it honours ([env], build.target or a target \
         runner), so they may affect this test:\n  {}\nRun with sandboxing or remote \
         execution to isolate the test from them.",
        found.join("\n  ")
    );
    if strict {
        return Err(message);
    }
    eprintln!("nextest runner: warning: {message}");
    Ok(())
}

fn map_exit_status(status: ExitStatus, sharded: bool) -> Result<i32, String> {
    match status.code() {
        Some(0) => Ok(0),
        Some(NEXTEST_TEST_RUN_FAILED) => Ok(1),
        Some(NEXTEST_NO_TESTS_RUN) => {
            // An empty shard is legitimate: with hash partitioning some shards can receive no
            // tests, and failing them would make sharding unusable.
            if sharded {
                Ok(0)
            } else {
                Err("no tests were run".to_owned())
            }
        }
        Some(code) => Err(format!(
            "cargo-nextest exited with code {code}, which indicates a harness error rather \
             than a test failure"
        )),
        None => Err(signal_description(&status)),
    }
}

#[cfg(unix)]
fn signal_description(status: &ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;
    match status.signal() {
        Some(signal) => format!("cargo-nextest was terminated by signal {signal}"),
        None => "cargo-nextest exited abnormally".to_owned(),
    }
}

#[cfg(not(unix))]
fn signal_description(_status: &ExitStatus) -> String {
    "cargo-nextest exited abnormally".to_owned()
}
