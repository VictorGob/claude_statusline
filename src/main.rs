use serde::Deserialize;
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const GIT_HEAD_PATH: &str = ".git/HEAD";
const GIT_REF_PREFIX: &str = "ref: refs/heads/";

const FIVE_HOUR_WINDOW_SECS: i64 = 18000;
/// Ignore the first 5% of the window — the average is too noisy to mean anything.
const BURN_MIN_ELAPSED_FRACTION: f64 = 0.05;
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

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

/// Format "resets in" hyperlinked suffix, e.g. ", resets in 2h30m". Empty if resets_at not set/past.
fn format_reset_suffix(resets_at: Option<i64>) -> String {
    let resets_at = match resets_at {
        Some(v) if v > 0 => v,
        _ => return String::new(),
    };
    let remaining = resets_at - now_epoch();
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
/// pace, above 1.0 is burning too fast. None if not derivable.
///
/// Only the 5h window gets this treatment. A straight-line budget assumes uniform
/// spending, which holds within a session but not across a week — a weekday-only
/// pattern reads as 1.4x by Friday while being perfectly on track.
fn burn_ratio(used_pct: f64, resets_at: Option<i64>) -> Option<f64> {
    let elapsed = window_elapsed_secs(resets_at)?;
    let expected_pct = elapsed / FIVE_HOUR_WINDOW_SECS as f64 * 100.0;
    Some(used_pct / expected_pct)
}

/// Seconds elapsed into the 5h window. None when not derivable: missing/past
/// resets_at, clock skew, or still inside the noisy opening 5%.
fn window_elapsed_secs(resets_at: Option<i64>) -> Option<f64> {
    let resets_at = match resets_at {
        Some(v) if v > 0 => v,
        _ => return None,
    };
    let remaining = resets_at - now_epoch();
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

/// `claude_statusline 0.1.0 (0f06173)`, with `-dirty` when built from an edited tree and
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
    if let Some("--version") | Some("-V") = std::env::args().nth(1).as_deref() {
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
