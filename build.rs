//! Captures the build-time commit SHA into `GIT_SHA`, read by `main.rs` for `--version`.
//!
//! Uses `std::process::Command` only — no build-dependencies, matching the crate's
//! minimal-dependency convention.
//!
//! The value is *build provenance*: the commit checked out on the machine that compiled
//! the binary, not a release identity. Since this tool is always built locally from
//! source, that is the useful reading — after a merge, `git pull` + rebuild picks up the
//! merge commit on its own.

use std::path::Path;
use std::process::Command;

/// Runs a git command, returning trimmed stdout. `None` on any failure — git missing,
/// not a checkout, non-zero exit. A version string is never worth failing a build over.
fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8(out.stdout).ok()?.trim().to_string())
}

fn main() {
    // Emitting ANY rerun-if-changed replaces cargo's default "rerun when a package file
    // changed", so every input this script depends on has to be listed explicitly.
    // Missing one here doesn't fail — it silently bakes a stale SHA into later builds.
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.toml");
    // Watching the sources is what keeps the -dirty marker honest: editing main.rs has to
    // re-run this script for the working tree to be re-examined. Only practical because
    // this crate has a single source file.
    println!("cargo:rerun-if-changed=src/main.rs");
    println!("cargo:rerun-if-changed=.git/HEAD");

    // A commit moves the branch ref, not .git/HEAD, so the ref file needs watching too.
    // Only when it exists as a loose file: naming a non-existent path makes cargo re-run
    // this script on *every* build, and the ref is absent while packed in .git/packed-refs.
    if let Ok(head) = std::fs::read_to_string(".git/HEAD") {
        if let Some(git_ref) = head.trim().strip_prefix("ref: ") {
            let ref_path = format!(".git/{}", git_ref);
            if Path::new(&ref_path).exists() {
                println!("cargo:rerun-if-changed={}", ref_path);
            }
        }
    }

    let sha = match git(&["rev-parse", "--short", "HEAD"]) {
        Some(sha) if !sha.is_empty() => sha,
        // Built outside a checkout (zip download, vendored source) or without git.
        _ => {
            println!("cargo:rustc-env=GIT_SHA=unknown");
            return;
        }
    };

    // A clean SHA on a binary built from edited sources would be a quiet lie, which is the
    // one failure mode that makes a version string worse than none.
    let dirty = git(&["status", "--porcelain"])
        .map(|s| !s.is_empty())
        .unwrap_or(false);

    if dirty {
        println!("cargo:rustc-env=GIT_SHA={}-dirty", sha);
    } else {
        println!("cargo:rustc-env=GIT_SHA={}", sha);
    }
}
