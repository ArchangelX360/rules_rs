//! Collects Rust code coverage after a `nextest_test` has run.
//!
//! A variant of rules_rust's `//util/collect_coverage` with one necessary difference: it
//! exports coverage for *several* instrumented objects rather than the single one that rule
//! derives from `TEST_BINARY`. Under nextest, `TEST_BINARY` is the runner symlink, which
//! carries no instrumented code, and one `nextest_test` may drive several test binaries.
//!
//! Everything else -- the empty-profraw short circuit, the "no coverage data found" handling,
//! the path rewriting and the intermediate cleanup -- matches rules_rust so that
//! `bazel coverage` behaves the same as it does for `rust_test`.
//!
//! Environment:
//! - `COVERAGE_DIR`: holds the `.profraw` files and receives `coverage.dat`.
//! - `ROOT`: the execroot the coverage action was invoked from.
//! - `RUNFILES_DIR` (optional): absent under `--experimental_split_coverage_postprocessing`.
//! - `RUST_LLVM_COV`, `RUST_LLVM_PROFDATA`: the llvm tools.
//! - `RULES_RS_NEXTEST_COVERAGE_OBJECTS`: path-separator-separated instrumented objects.
//! - `VERBOSE_COVERAGE`: print debug information.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if env::var("VERBOSE_COVERAGE").is_ok() {
            eprintln!($($arg)*);
        }
    };
}

/// Resolves a file that may live in the execroot or in the runfiles tree.
fn find_metadata_file(execroot: &Path, runfiles_dir: Option<&Path>, path: &str) -> PathBuf {
    if execroot.join(path).exists() {
        return execroot.join(path);
    }
    match runfiles_dir {
        Some(runfiles_dir) => {
            debug_log!("not in execroot, falling back to runfiles: {}", path);
            runfiles_dir.join(path)
        }
        None => execroot.join(path),
    }
}

fn main() {
    let coverage_dir = PathBuf::from(env::var("COVERAGE_DIR").expect("COVERAGE_DIR must be set"));
    let execroot = PathBuf::from(env::var("ROOT").expect("ROOT must be set"));

    // Bazel removes RUNFILES_DIR in split coverage postprocessing mode.
    let runfiles_dir = env::var("RUNFILES_DIR").ok().map(|dir| {
        let path = PathBuf::from(dir);
        if path.is_absolute() {
            path
        } else {
            execroot.join(path)
        }
    });

    let coverage_output_file = coverage_dir.join("coverage.dat");
    let profdata_file = coverage_dir.join("coverage.profdata");

    let llvm_cov = find_metadata_file(
        &execroot,
        runfiles_dir.as_deref(),
        &env::var("RUST_LLVM_COV").expect("RUST_LLVM_COV must be set"),
    );
    let llvm_profdata = find_metadata_file(
        &execroot,
        runfiles_dir.as_deref(),
        &env::var("RUST_LLVM_PROFDATA").expect("RUST_LLVM_PROFDATA must be set"),
    );

    let objects: Vec<PathBuf> = env::var("RULES_RS_NEXTEST_COVERAGE_OBJECTS")
        .expect("RULES_RS_NEXTEST_COVERAGE_OBJECTS must be set by the nextest rule")
        .split(if cfg!(windows) { ';' } else { ':' })
        .filter(|entry| !entry.is_empty())
        .map(|entry| find_metadata_file(&execroot, runfiles_dir.as_deref(), entry))
        .collect();

    if objects.is_empty() {
        debug_log!("no instrumented objects; writing an empty report");
        fs::write(&coverage_output_file, "").unwrap();
        return;
    }

    let profraw_files: Vec<PathBuf> = fs::read_dir(&coverage_dir)
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "profraw"))
        .collect();

    // A test that ran without `-Cinstrument-coverage` (filtered out by
    // --instrumentation_filter, say) produces no .profraw files. Write an empty report rather
    // than letting `llvm-profdata merge` fail on empty input.
    if profraw_files.is_empty() {
        debug_log!("no .profraw files in COVERAGE_DIR; writing an empty report");
        fs::write(&coverage_output_file, "").unwrap();
        return;
    }

    let mut merge = process::Command::new(&llvm_profdata);
    merge
        .arg("merge")
        .arg("--sparse")
        .args(&profraw_files)
        .arg("--output")
        .arg(&profdata_file);

    debug_log!("spawning {:#?}", merge);
    let status = merge.status().expect("failed to spawn llvm-profdata");
    if !status.success() {
        process::exit(status.code().unwrap_or(1));
    }

    let mut export = process::Command::new(&llvm_cov);
    export
        .arg("export")
        .arg("-format=lcov")
        .arg("-instr-profile")
        .arg(&profdata_file)
        .arg("-ignore-filename-regex=.*external/.+")
        .arg("-ignore-filename-regex=/tmp/.+")
        .arg(format!("-path-equivalence=.,{}", execroot.display()));

    // llvm-cov takes the first object positionally and the rest with -object.
    let mut objects = objects.into_iter();
    export.arg(objects.next().expect("checked non-empty above"));
    for object in objects {
        export.arg("-object").arg(object);
    }
    export.stdout(process::Stdio::piped()).stderr(process::Stdio::piped());

    debug_log!("spawning {:#?}", export);
    let output = export
        .spawn()
        .expect("failed to spawn llvm-cov")
        .wait_with_output()
        .expect("llvm-cov failed");

    if !output.status.success() {
        let stderr = std::str::from_utf8(&output.stderr).unwrap_or("<non-utf8>");
        if stderr.contains("no coverage data found") {
            debug_log!("no coverage data in the objects; writing an empty report");
            fs::write(&coverage_output_file, "").unwrap();
            fs::remove_file(&profdata_file).ok();
            return;
        }
        eprintln!("llvm-cov export failed:\n{stderr}");
        process::exit(output.status.code().unwrap_or(1));
    }

    let report = std::str::from_utf8(&output.stdout).expect("failed to parse llvm-cov output");
    debug_log!("writing output to {}", coverage_output_file.display());
    fs::write(
        coverage_output_file,
        report
            .replace("#/proc/self/cwd/", "")
            .replace(&execroot.display().to_string(), ""),
    )
    .unwrap();

    // Remove the intermediate file so lcov_merger does not parse it as a report.
    fs::remove_file(profdata_file).unwrap();
    debug_log!("success");
}
