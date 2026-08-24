use serde::Deserialize;
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const GIT_HEAD_PATH: &str = ".git/HEAD";
const GIT_REF_PREFIX: &str = "ref: refs/heads/";

const FIVE_HOUR_WINDOW_SECS: i64 = 18000;
/// Ignore the first 2% of the window (6 min). This is only a residual guard against a
/// near-zero denominator and against `dry_in_suffix()` projecting off a two-minute
/// sample — BURN_MIN_GAP_PCT below is what actually keeps the opening quiet.
const BURN_MIN_ELAPSED_FRACTION: f64 = 0.02;
/// A multiple alone is not enough to warn on. Early in the window the straight-line
/// budget is near zero, so one point of measurement noise swings the ratio by ~0.6x;
/// the *difference* stays well-behaved exactly where the quotient does not. Requiring
/// both is what let the flat blackout above drop from 15 minutes to 6: a genuine 2x
/// overspend now surfaces at 7 min, while sub-point drift never warns at all. Binds
/// only early — an hour in, 1.15x is already 3 points of lead.
const BURN_MIN_GAP_PCT: f64 = 1.0;
/// Deliberately above 1.0: spending exactly on budget lands at 100% right as the
/// window resets, which is fine. Warning there would be permanently on, and would
/// flicker as the ratio crossed the threshold between refreshes.
const BURN_WARN_RATIO: f64 = 1.15;
const BURN_FIRE_RATIO: f64 = 1.4;
const BURN_HIGH_RATIO: f64 = 1.75;

/// Below this much context the cache indicator stays hidden. A cold start is all
/// cache writes by construction, so an ungated indicator would sit red on every
/// session opening. Gating on context size rather than on `read > 0` keeps a
/// genuine post-TTL 0% visible, which is the event actually worth seeing.
const CACHE_MIN_CONTEXT_PCT: f64 = 30.0;
/// These run backwards from every other threshold here: high is good.
const CACHE_WARN_RATIO: f64 = 0.85;
const CACHE_HIGH_RATIO: f64 = 0.60;

/// Under a minute there is nothing to say about a session's age.
const AGE_MIN_SECS: u64 = 60;
const AGE_WARN_SECS: u64 = 4 * 3600;
const AGE_HIGH_SECS: u64 = 8 * 3600;
/// Below an hour the API/wall ratio swings too wildly to mean anything.
const ACTIVITY_MIN_AGE_SECS: u64 = 3600;
const ACTIVITY_WARN_PCT: f64 = 5.0;

/// The branch is the only unbounded field on line 1, and it renders before the age
/// and activity indicators — so an overlong branch pushes exactly the segments that
/// prompt a /clear off the right edge. Cut the tail rather than the middle: the head
/// is where the ticket id lives, which is what identifies the branch at a glance.
const BRANCH_MAX_CHARS: usize = 40;

/// A full object id as stored in `.git/HEAD` when detached, and the prefix shown for it.
/// Slicing by byte is safe only because the value is verified all-ASCII-hex first.
const GIT_SHA_LEN: usize = 40;
const GIT_SHORT_SHA_LEN: usize = 7;

const COLOR_GREEN: &str = "\x1b[32m";
const COLOR_YELLOW: &str = "\x1b[33m";
const COLOR_RED: &str = "\x1b[31m";
const COLOR_CYAN: &str = "\x1b[36m";
const COLOR_BLUE: &str = "\x1b[34m";
const COLOR_MAGENTA: &str = "\x1b[35m";
const COLOR_RESET: &str = "\x1b[0m";
const STYLE_BOLD: &str = "\x1b[1m";

#[derive(Deserialize, Default)]
struct Root {
    model: Option<Model>,
    workspace: Option<Workspace>,
    context_window: Option<ContextWindow>,
    rate_limits: Option<RateLimits>,
    effort: Option<Effort>,
    cost: Option<Cost>,
}

#[derive(Deserialize)]
struct Model {
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct Effort {
    level: Option<String>,
}

#[derive(Deserialize)]
struct Workspace {
    current_dir: Option<String>,
}

#[derive(Deserialize)]
struct ContextWindow {
    used_percentage: Option<f64>,
    /// The most recent response's usage, not a session total. Explicitly null
    /// before the first API call and again after /compact — Option covers both
    /// that and the field being absent.
    current_usage: Option<CurrentUsage>,
}

#[derive(Deserialize)]
struct CurrentUsage {
    cache_creation_input_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
}

/// Wall-clock and API time for the session. /clear resets both, so the age is
/// really "time since the last /clear" — which is when context started growing.
#[derive(Deserialize)]
struct Cost {
    total_duration_ms: Option<u64>,
    total_api_duration_ms: Option<u64>,
}

#[derive(Deserialize)]
struct RateLimits {
    five_hour: Option<RateLimit>,
    seven_day: Option<RateLimit>,
}

#[derive(Deserialize)]
struct RateLimit {
    used_percentage: Option<f64>,
    resets_at: Option<i64>,
}

/// None when the system clock reads before 1970. Returning Option rather than unwrapping
/// keeps a broken clock to the two segments that need the time: under panic = "abort" a
/// panic here would render no status line at all, which is a poor trade for a countdown.
fn now_epoch() -> Option<i64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

/// Format "resets in" hyperlinked suffix, e.g. ", resets in 2h30m". Empty if resets_at not set/past.
fn format_reset_suffix(resets_at: Option<i64>) -> String {
    let resets_at = match resets_at {
        Some(v) if v > 0 => v,
        _ => return String::new(),
    };
    let now = match now_epoch() {
        Some(now) => now,
        // Unreadable clock: no countdown, same as a missing resets_at.
        None => return String::new(),
    };
    let remaining = resets_at - now;
    if remaining <= 0 {
        return String::new();
    }

    let days = remaining / 86400;
    let h = (remaining % 86400) / 3600;
    let m = (remaining % 3600) / 60;

    if days > 0 {
        format!(
            ", \x1b]8;;https://claude.ai/settings/usage\x1b\\resets in {}d{}h\x1b]8;;\x1b\\",
            days, h
        )
    } else if h > 0 {
        format!(
            ", \x1b]8;;https://claude.ai/settings/usage\x1b\\resets in {}h{}m\x1b]8;;\x1b\\",
            h, m
        )
    } else {
        format!(
            ", \x1b]8;;https://claude.ai/settings/usage\x1b\\resets in {}m\x1b]8;;\x1b\\",
            m
        )
    }
}

fn read_git_branch() -> String {
    let content = match std::fs::read_to_string(GIT_HEAD_PATH) {
        Ok(c) => c,
        Err(_) => return String::new(),
    };
    let line = content.lines().next().unwrap_or("");

    match line.strip_prefix(GIT_REF_PREFIX) {
        Some(branch) => {
            // Count and take chars, not bytes: git permits UTF-8 in ref names, and a
            // byte slice landing mid-codepoint panics.
            let shown = if branch.chars().count() > BRANCH_MAX_CHARS {
                let mut s: String = branch.chars().take(BRANCH_MAX_CHARS - 1).collect();
                s.push('…');
                s
            } else {
                branch.to_string()
            };
            format!(" | 🌿 {}{}{}", COLOR_GREEN, shown, COLOR_RESET)
        }
        // Detached HEAD: the file holds a raw object id instead of a ref, and rendering
        // nothing would go quiet in exactly the state most likely to leave you unsure
        // where you are. The '@' marks it as a commit rather than a branch that happens
        // to be named like hex, echoing git's own "HEAD detached at abc1234".
        None if line.len() == GIT_SHA_LEN && line.bytes().all(|b| b.is_ascii_hexdigit()) => {
            format!(
                " | 🌿 {}@{}{}",
                COLOR_GREEN,
                &line[..GIT_SHORT_SHA_LEN],
                COLOR_RESET
            )
        }
        // Anything else (a worktree's gitdir pointer, a malformed file) stays silent.
        None => String::new(),
    }
}

/// Returns the display color for a reasoning effort level.
fn effort_color(level: &str) -> &'static str {
    match level {
        "low" => COLOR_BLUE,
        "medium" => COLOR_CYAN,
        "high" => COLOR_GREEN,
        "xhigh" => COLOR_YELLOW,
        "max" => COLOR_MAGENTA,
        _ => COLOR_CYAN,
    }
}

/// Spend pace as a multiple of the 5h window's straight-line budget: 1.0 is exactly on
/// pace, above 1.0 is burning too fast. None when not derivable *or* when the lead over
/// budget is under BURN_MIN_GAP_PCT, which is the same "stay quiet" answer to callers.
///
/// Only the 5h window gets this treatment. A straight-line budget assumes uniform
/// spending, which holds within a session but not across a week — a weekday-only
/// pattern reads as 1.4x by Friday while being perfectly on track.
fn burn_ratio(used_pct: f64, resets_at: Option<i64>) -> Option<f64> {
    let elapsed = window_elapsed_secs(resets_at)?;
    let expected_pct = elapsed / FIVE_HOUR_WINDOW_SECS as f64 * 100.0;
    // None here means "nothing worth flagging", not "not derivable": being on or under
    // budget lands in the same bucket as too little lead to trust. All three consumers
    // — the label color, the icon, the projection — already treat None as "stay quiet",
    // so gating once here keeps them moving together.
    if used_pct - expected_pct < BURN_MIN_GAP_PCT {
        return None;
    }
    Some(used_pct / expected_pct)
}

/// Seconds elapsed into the 5h window. None when not derivable: missing/past
/// resets_at, clock skew, or still inside the noisy opening 2%.
fn window_elapsed_secs(resets_at: Option<i64>) -> Option<f64> {
    let resets_at = match resets_at {
        Some(v) if v > 0 => v,
        _ => return None,
    };
    // `?`: an unreadable clock lands in the same bucket as clock skew below — no burn
    // coloring and no projection.
    let remaining = resets_at - now_epoch()?;
    if remaining <= 0 || remaining > FIVE_HOUR_WINDOW_SECS {
        return None;
    }
    let elapsed = (FIVE_HOUR_WINDOW_SECS - remaining) as f64;
    if elapsed < FIVE_HOUR_WINDOW_SECS as f64 * BURN_MIN_ELAPSED_FRACTION {
        return None;
    }
    Some(elapsed)
}

/// ", dry in 1h30m" — the projected exhaustion time at the current average pace,
/// shown only once the burn ratio hits red. Empty at every other level.
fn dry_in_suffix(used_pct: f64, resets_at: Option<i64>, ratio: Option<f64>) -> String {
    match ratio {
        Some(r) if r >= BURN_HIGH_RATIO => {}
        _ => return String::new(),
    }
    let elapsed = match window_elapsed_secs(resets_at) {
        Some(e) => e,
        None => return String::new(),
    };
    if used_pct <= 0.0 || used_pct >= 100.0 {
        return String::new();
    }
    // Needing (100 - used) more at used/elapsed per second. At >=1.75x this is always
    // under 2h51m away, so no days branch is needed.
    let secs = ((100.0 - used_pct) / used_pct * elapsed) as i64;
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    if h > 0 {
        format!(", {}dry in {}h{}m{}", COLOR_RED, h, m, COLOR_RESET)
    } else {
        format!(", {}dry in {}m{}", COLOR_RED, m, COLOR_RESET)
    }
}

/// Swaps the clock for a flame once spending hits 1.4x budget.
fn burn_icon(ratio: Option<f64>) -> &'static str {
    match ratio {
        Some(r) if r >= BURN_FIRE_RATIO => "🔥",
        _ => "⏱️",
    }
}

/// Colors the "5h" label only when spending outpaces its budget.
fn burn_color(ratio: Option<f64>) -> (&'static str, &'static str) {
    match ratio {
        Some(r) if r >= BURN_HIGH_RATIO => (COLOR_RED, COLOR_RESET),
        Some(r) if r >= BURN_WARN_RATIO => (COLOR_YELLOW, COLOR_RESET),
        _ => ("", ""),
    }
}

/// Share of the last response's context tokens served from cache rather than
/// written into it. None when either count is missing or nothing was cached at all.
fn cache_hit_ratio(usage: &CurrentUsage) -> Option<f64> {
    let read = usage.cache_read_input_tokens? as f64;
    let created = usage.cache_creation_input_tokens? as f64;
    let total = read + created;
    if total <= 0.0 {
        return None;
    }
    Some(read / total)
}

/// "💾 91%" — how much of this turn's context was re-read instead of rebuilt.
/// A cache write costs roughly 12x a cache read, so this tracks what the turn
/// cost. Empty below CACHE_MIN_CONTEXT_PCT, where the number is all startup
/// writes and a rebuild is cheap anyway.
fn cache_suffix(used_pct: Option<f64>, usage: Option<&CurrentUsage>) -> String {
    match used_pct {
        Some(p) if p >= CACHE_MIN_CONTEXT_PCT => {}
        _ => return String::new(),
    }
    let ratio = match usage.and_then(cache_hit_ratio) {
        Some(r) => r,
        None => return String::new(),
    };
    let (color, reset) = cache_color(ratio);
    format!("{}💾 {:.0}%{}", color, ratio * 100.0, reset)
}

/// Colors the cache ratio. Inverted against pct_color: high is healthy.
fn cache_color(ratio: f64) -> (&'static str, &'static str) {
    if ratio < CACHE_HIGH_RATIO {
        (COLOR_RED, COLOR_RESET)
    } else if ratio < CACHE_WARN_RATIO {
        (COLOR_YELLOW, COLOR_RESET)
    } else {
        ("", "")
    }
}

/// Session age as "1d3h" / "4h02m" / "12m". Zero-padded minutes and no seconds
/// branch, which is why it isn't shared with the countdown formatters above.
fn format_age(secs: u64) -> String {
    let days = secs / 86400;
    let h = (secs % 86400) / 3600;
    let m = (secs % 3600) / 60;
    if days > 0 {
        format!("{}d{}h", days, h)
    } else if h > 0 {
        format!("{}h{:02}m", h, m)
    } else {
        format!("{}m", m)
    }
}

/// " | ⏳ 4h02m ⚡8%" — how long this context has been accumulating, and how much
/// of that was actually spent waiting on the model. A long session that is mostly
/// idle is a large context held open for nothing, and re-sent on every turn.
fn session_suffix(cost: &Cost) -> String {
    let secs = match cost.total_duration_ms {
        Some(ms) if ms / 1000 >= AGE_MIN_SECS => ms / 1000,
        _ => return String::new(),
    };
    let (color, reset) = if secs >= AGE_HIGH_SECS {
        (COLOR_RED, COLOR_RESET)
    } else if secs >= AGE_WARN_SECS {
        (COLOR_YELLOW, COLOR_RESET)
    } else {
        ("", "")
    };

    let mut out = format!(" | ⏳ {}{}{}", color, format_age(secs), reset);

    // Both conditions have to hold: a low active share only means something once
    // the session has been open long enough for the idling to have cost anything.
    if secs >= ACTIVITY_MIN_AGE_SECS {
        if let Some(api_ms) = cost.total_api_duration_ms {
            // Clamped: total_api_duration_ms sums per-request durations, so parallel
            // subagents push it past wall clock. This answers "how much of the session
            // was real work" — a bounded share — so 100% is the honest ceiling; degree
            // of parallelism is a different question this cue isn't for.
            let pct = (api_ms as f64 / (secs * 1000) as f64 * 100.0).min(100.0);
            let (c, r) = if secs >= AGE_WARN_SECS && pct < ACTIVITY_WARN_PCT {
                (COLOR_YELLOW, COLOR_RESET)
            } else {
                ("", "")
            };
            out.push_str(&format!(" {}⚡{:.0}%{}", c, pct, r));
        }
    }
    out
}

/// Returns (color, reset) escape codes for a percentage: yellow at 60%, red at 90%.
fn pct_color(pct: f64) -> (&'static str, &'static str) {
    if pct >= 90.0 {
        (COLOR_RED, COLOR_RESET)
    } else if pct >= 60.0 {
        (COLOR_YELLOW, COLOR_RESET)
    } else {
        ("", "")
    }
}

/// `claude_statusline 0.2.0 (8d879d1)`, with `-dirty` when built from an edited tree and
/// `unknown` when built outside a git checkout. GIT_SHA is captured at compile time by
/// build.rs, so it names the commit the binary was *built* from.
fn print_version() {
    println!(
        "{} {} ({})",
        env!("CARGO_PKG_NAME"),
        env!("CARGO_PKG_VERSION"),
        env!("GIT_SHA")
    );
}

fn main() {
    // Before the stdin read, not after: --version run from a terminal has no pipe feeding
    // it, so reading first would block forever instead of printing. Any other argument
    // falls through and is ignored, so a future Claude Code that passes one still renders.
    //
    // args_os, not args: args() panics on an argument that isn't valid UTF-8, and with
    // panic="abort" that renders no status line at all rather than ignoring the argument
    // as the line above promises. OsStr implements PartialEq<str>, so the comparison stays
    // direct with no lossy conversion. Reachable on Unix, where argv is raw bytes; on
    // Windows argv arrives as UTF-16 and invalid means an unpaired surrogate, which is why
    // there is no smoke assertion for this (see AGENTS.md).
    if matches!(std::env::args_os().nth(1).as_deref(),
                Some(arg) if arg == "--version" || arg == "-V") {
        print_version();
        return;
    }

    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("Error: Failed to read stdin");
        std::process::exit(1);
    }

    let root: Root = match serde_json::from_str(&input) {
        Ok(r) => r,
        Err(_) => {
            eprintln!("Error: Failed to parse JSON");
            std::process::exit(1);
        }
    };

    let model_name = root
        .model
        .and_then(|m| m.display_name)
        .unwrap_or_else(|| "Unknown".to_string());

    let current_dir_full = root
        .workspace
        .and_then(|w| w.current_dir)
        .unwrap_or_default();

    let effort_level = root.effort.and_then(|e| e.level);

    let context_window = root.context_window;
    let used_pct = context_window.as_ref().and_then(|c| c.used_percentage);
    let current_usage = context_window
        .as_ref()
        .and_then(|c| c.current_usage.as_ref());

    let (five_hour_pct, five_hour_resets_at) = root
        .rate_limits
        .as_ref()
        .and_then(|r| r.five_hour.as_ref())
        .map(|f| (f.used_percentage, f.resets_at))
        .unwrap_or((None, None));

    let (seven_day_pct, seven_day_resets_at) = root
        .rate_limits
        .as_ref()
        .and_then(|r| r.seven_day.as_ref())
        .map(|f| (f.used_percentage, f.resets_at))
        .unwrap_or((None, None));

    // Get basename of current directory. std::path applies the platform's own separator
    // rules: on Windows both '\' and '/' split, on Unix only '/', so a Unix filename
    // containing a backslash survives intact.
    let dir_basename = Path::new(current_dir_full.as_str())
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(&current_dir_full);

    // Get git branch
    let git_branch = read_git_branch();

    // Effort level suffix (e.g. " high"), space-joined with no "|" separator
    let effort_suffix = match effort_level {
        Some(level) => format!(" {}{}{}", effort_color(&level), level, COLOR_RESET),
        None => String::new(),
    };

    // Session age and active share, when the session is old enough to have any
    let age_suffix = root.cost.as_ref().map(session_suffix).unwrap_or_default();

    // Build line 1: [Model] effort | 📁 dir | 🌿 branch | ⏳ age ⚡active
    let line1 = format!(
        "{}{}{}{} | 📁 {}{}{}{}{}",
        STYLE_BOLD,
        model_name,
        COLOR_RESET,
        effort_suffix,
        COLOR_CYAN,
        dir_basename,
        COLOR_RESET,
        git_branch,
        age_suffix
    );

    // Build line 2 (only if there's data)
    let mut line2 = String::new();
    let mut has_content = false;

    if let Some(pct) = used_pct {
        let (color, reset) = pct_color(pct);
        line2.push_str(&format!("{}🎫 {:.0}%{}", color, pct, reset));
        has_content = true;
    }

    let cache = cache_suffix(used_pct, current_usage);
    if !cache.is_empty() {
        if has_content {
            line2.push_str(" | ");
        }
        line2.push_str(&cache);
        has_content = true;
    }

    if let Some(pct) = five_hour_pct {
        let (color, reset) = pct_color(pct);
        let ratio = burn_ratio(pct, five_hour_resets_at);
        let (burn, burn_reset) = burn_color(ratio);
        if has_content {
            line2.push_str(" | ");
        }
        let reset_suffix = format_reset_suffix(five_hour_resets_at);
        let dry_suffix = dry_in_suffix(pct, five_hour_resets_at, ratio);
        line2.push_str(&format!(
            "{} {}5h{}: {}{:.0}%{}{}{}",
            burn_icon(ratio),
            burn,
            burn_reset,
            color,
            pct,
            reset,
            reset_suffix,
            dry_suffix
        ));
        has_content = true;
    }

    if let Some(pct) = seven_day_pct {
        let (color, reset) = pct_color(pct);
        if has_content {
            line2.push_str(" | ");
        }
        let reset_suffix = format_reset_suffix(seven_day_resets_at);
        line2.push_str(&format!(
            "📅 7d: {}{:.0}%{}{}",
            color, pct, reset, reset_suffix
        ));
        has_content = true;
    }

    println!("{}", line1);
    if has_content {
        println!("{}", line2);
    }
}

/// Unit tests for the threshold and formatting logic.
///
/// These exist because the Makefile / build.ps1 smoke suites cannot do two things: pin a
/// threshold's *exact* boundary (they assert a comfortable midpoint, so a constant could
/// drift some way before any of them notices), and run deterministically (they derive
/// `resets_at` from the wall clock). Both suites still matter — they test the real binary
/// end to end, including the ANSI output and the `.git/HEAD` read this module skips.
///
/// Compiled out of the release build, so none of this reaches the binary.
#[cfg(test)]
mod tests {
    use super::*;

    /// Both sides of every threshold. A test at a comfortable midpoint passes just as
    /// happily with the constant moved, which makes it worthless for catching drift.
    #[test]
    fn pct_color_boundaries() {
        assert_eq!(pct_color(59.9).0, "");
        assert_eq!(pct_color(60.0).0, COLOR_YELLOW);
        assert_eq!(pct_color(89.9).0, COLOR_YELLOW);
        assert_eq!(pct_color(90.0).0, COLOR_RED);
    }

    /// Inverted against every other indicator here: high is good.
    #[test]
    fn cache_color_boundaries() {
        assert_eq!(cache_color(0.85).0, "", "at/above warn ratio is plain");
        assert_eq!(cache_color(0.849).0, COLOR_YELLOW);
        assert_eq!(cache_color(0.60).0, COLOR_YELLOW, "exactly at high ratio");
        assert_eq!(cache_color(0.599).0, COLOR_RED);
    }

    #[test]
    fn burn_color_boundaries() {
        assert_eq!(burn_color(None).0, "", "no ratio means no cue");
        assert_eq!(burn_color(Some(1.149)).0, "");
        assert_eq!(burn_color(Some(BURN_WARN_RATIO)).0, COLOR_YELLOW);
        assert_eq!(burn_color(Some(1.749)).0, COLOR_YELLOW);
        assert_eq!(burn_color(Some(BURN_HIGH_RATIO)).0, COLOR_RED);
    }

    /// The flame sits at its own threshold, between warn and red, so it needs its own
    /// test — a yellow label with no flame is a real, intended state.
    #[test]
    fn burn_icon_threshold_is_independent_of_color() {
        assert_eq!(burn_icon(None), "⏱️");
        assert_eq!(burn_icon(Some(1.399)), "⏱️");
        assert_eq!(burn_icon(Some(BURN_FIRE_RATIO)), "🔥");
        assert_eq!(
            burn_color(Some(1.399)).0,
            COLOR_YELLOW,
            "yellow but not yet flaming"
        );
    }

    fn usage(read: Option<u64>, created: Option<u64>) -> CurrentUsage {
        CurrentUsage {
            cache_read_input_tokens: read,
            cache_creation_input_tokens: created,
        }
    }

    #[test]
    fn cache_hit_ratio_handles_missing_and_empty() {
        let ratio = cache_hit_ratio(&usage(Some(80000), Some(3150))).unwrap();
        assert!((ratio - 0.9621).abs() < 0.001, "got {}", ratio);
        assert_eq!(cache_hit_ratio(&usage(Some(0), Some(0))), None, "no tokens");
        assert_eq!(cache_hit_ratio(&usage(None, Some(10))), None, "no read field");
        assert_eq!(cache_hit_ratio(&usage(Some(10), None)), None, "no write field");
    }

    /// The floor exists so a cold start — all cache writes by construction — doesn't sit
    /// red at the top of every session.
    #[test]
    fn cache_suffix_respects_the_context_floor() {
        let u = usage(Some(20000), Some(80000));
        assert_eq!(cache_suffix(Some(29.9), Some(&u)), "");
        assert!(cache_suffix(Some(CACHE_MIN_CONTEXT_PCT), Some(&u)).contains("💾"));
        assert_eq!(cache_suffix(None, Some(&u)), "", "no context reading");
        assert_eq!(cache_suffix(Some(60.0), None), "", "post-/compact null usage");
    }

    #[test]
    fn format_age_branches() {
        assert_eq!(format_age(0), "0m");
        assert_eq!(format_age(60), "1m");
        assert_eq!(format_age(3600), "1h00m", "minutes are zero-padded");
        assert_eq!(format_age(18120), "5h02m");
        assert_eq!(format_age(86400), "1d0h", "day branch drops minutes");
        assert_eq!(format_age(90000), "1d1h");
    }

    fn cost(total_ms: Option<u64>, api_ms: Option<u64>) -> Cost {
        Cost {
            total_duration_ms: total_ms,
            total_api_duration_ms: api_ms,
        }
    }

    #[test]
    fn session_suffix_age_and_activity_gates() {
        assert_eq!(session_suffix(&cost(Some(59_000), None)), "", "under a minute");
        assert!(session_suffix(&cost(Some(60_000), None)).contains("⏳"));

        // The activity share is meaningless on a short session, so it stays hidden.
        let short = session_suffix(&cost(Some(600_000), Some(120_000)));
        assert!(short.contains("⏳ 10m") && !short.contains("⚡"));
        assert!(session_suffix(&cost(Some(3_600_000), Some(120_000))).contains("⚡"));
    }

    /// Needs *both* conditions: a low active share only means something once the session
    /// has been open long enough for the idling to have cost anything.
    #[test]
    fn session_suffix_activity_warns_only_when_old_and_idle() {
        let old_idle = session_suffix(&cost(Some(18_120_000), Some(300_000)));
        assert!(old_idle.contains("⚡2%") && old_idle.contains(COLOR_YELLOW));

        // Old but busy: the age still colours, so check the activity segment itself is
        // plain — a bare space before the bolt means no escape was emitted.
        let old_busy = session_suffix(&cost(Some(18_120_000), Some(18_000_000)));
        assert!(old_busy.contains(" ⚡99%"), "busy session, uncoloured: {}", old_busy);

        // Parallel subagents sum past wall clock; 100% is the honest ceiling.
        let parallel = session_suffix(&cost(Some(7_200_000), Some(18_000_000)));
        assert!(parallel.contains("⚡100%"), "clamped, not 250%: {}", parallel);

        // Young and idle: under AGE_WARN_SECS the share is shown but never coloured.
        let young_idle = session_suffix(&cost(Some(3_600_000), Some(1_000)));
        assert!(young_idle.contains("⚡0%") && !young_idle.contains(COLOR_YELLOW));
    }

    #[test]
    fn effort_levels_are_distinct() {
        let levels = ["low", "medium", "high", "xhigh", "max"];
        let colors: Vec<&str> = levels.iter().map(|l| effort_color(l)).collect();
        for (i, a) in colors.iter().enumerate() {
            for (j, b) in colors.iter().enumerate() {
                assert!(i == j || a != b, "{} and {} share a color", levels[i], levels[j]);
            }
        }
        assert_eq!(effort_color("something-new"), COLOR_CYAN, "unknown falls back");
    }

    // --- Clock-dependent -----------------------------------------------------------
    // These read now_epoch() internally, so inputs are derived from it and compared with
    // a tolerance: a second can tick between the test computing `now` and the function
    // reading it, which would make exact equality flaky.

    fn resets_in(secs: i64) -> Option<i64> {
        Some(now_epoch().expect("system clock readable in tests") + secs)
    }

    #[test]
    fn window_elapsed_guards() {
        assert_eq!(window_elapsed_secs(None), None, "missing resets_at");
        assert_eq!(window_elapsed_secs(Some(0)), None, "zero is not a timestamp");
        assert_eq!(window_elapsed_secs(resets_in(-60)), None, "already past");
        assert_eq!(
            window_elapsed_secs(resets_in(FIVE_HOUR_WINDOW_SECS + 600)),
            None,
            "remaining beyond the window means clock skew"
        );
        assert_eq!(
            window_elapsed_secs(resets_in(FIVE_HOUR_WINDOW_SECS - 60)),
            None,
            "inside the noisy opening 2%"
        );
        assert_eq!(
            window_elapsed_secs(resets_in(FIVE_HOUR_WINDOW_SECS - 300)),
            None,
            "5m in is still under the 6m floor"
        );
        let early =
            window_elapsed_secs(resets_in(FIVE_HOUR_WINDOW_SECS - 420)).expect("7m in clears it");
        assert!((early - 420.0).abs() < 5.0, "got {}", early);
        let elapsed = window_elapsed_secs(resets_in(14400)).expect("1h in is derivable");
        assert!((elapsed - 3600.0).abs() < 5.0, "got {}", elapsed);
    }

    /// 1h into the window is 20% of the budget, so 24% used is 1.2x.
    #[test]
    fn burn_ratio_is_a_multiple_of_budget() {
        let ratio = burn_ratio(24.0, resets_in(14400)).expect("derivable");
        assert!((ratio - 1.2).abs() < 0.01, "got {}", ratio);

        assert_eq!(burn_ratio(50.0, None), None, "no window, no ratio");
    }

    /// The gap gate. Both sides of BURN_MIN_GAP_PCT, on a 1h-elapsed window where the
    /// straight-line budget is 20% and one point of lead is therefore the threshold.
    #[test]
    fn burn_ratio_needs_an_absolute_lead() {
        let at = resets_in(14400);
        assert_eq!(burn_ratio(20.5, at), None, "half a point of lead is noise");
        let ratio = burn_ratio(21.5, at).expect("a point and a half clears the gate");
        assert!((ratio - 1.075).abs() < 0.01, "got {}", ratio);

        assert_eq!(burn_ratio(20.0, at), None, "on budget is not over");
        assert_eq!(burn_ratio(5.0, at), None, "under budget is not a burn");
        assert_eq!(burn_color(None).0, "", "and None must not warn");
    }

    /// What the gate buys: 7m in, the budget is 2.33%, so 5% used is 2.14x with 2.7
    /// points of lead. The flat 15-minute blackout it replaced hid this entirely.
    #[test]
    fn burn_ratio_surfaces_early_overspend() {
        let at = resets_in(FIVE_HOUR_WINDOW_SECS - 420);
        let ratio = burn_ratio(5.0, at).expect("derivable 7m in");
        assert!(ratio >= BURN_HIGH_RATIO, "got {}", ratio);
        assert!(dry_in_suffix(5.0, at, Some(ratio)).contains("dry in"));
    }

    /// Confined to red so line 2 keeps its usual width at every other level.
    #[test]
    fn dry_in_only_appears_at_red() {
        let at = resets_in(14400);
        assert_eq!(dry_in_suffix(30.0, at, Some(1.5)), "", "yellow stays quiet");
        assert_eq!(dry_in_suffix(40.0, at, None), "", "no ratio, no projection");
        assert!(dry_in_suffix(40.0, at, Some(2.0)).contains("dry in"));
        assert_eq!(dry_in_suffix(0.0, at, Some(2.0)), "", "nothing used yet");
        assert_eq!(dry_in_suffix(100.0, at, Some(2.0)), "", "already dry");
    }
}
