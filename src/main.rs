use serde::Deserialize;
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

const GIT_HEAD_PATH: &str = ".git/HEAD";
const GIT_REF_PREFIX: &str = "ref: refs/heads/";

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

/// Format "resets in" hyperlinked suffix, e.g. ", resets in 2h30m". Empty if resets_at not set/past.
fn format_reset_suffix(resets_at: Option<i64>) -> String {
    let resets_at = match resets_at {
        Some(v) if v > 0 => v,
        _ => return String::new(),
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
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
        Some(branch) => format!(" | 🌿 {}{}{}", COLOR_GREEN, branch, COLOR_RESET),
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

/// Returns (color, reset) escape codes for a percentage, matching the C thresholds.
fn pct_color(pct: f64) -> (&'static str, &'static str) {
    if pct >= 90.0 {
        (COLOR_RED, COLOR_RESET)
    } else if pct >= 60.0 {
        (COLOR_YELLOW, COLOR_RESET)
    } else {
        ("", "")
    }
}

fn main() {
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

    let used_pct = root.context_window.and_then(|c| c.used_percentage);

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

    // Get basename of current directory
    let dir_basename = current_dir_full
        .rsplit('/')
        .next()
        .unwrap_or(&current_dir_full);

    // Get git branch
    let git_branch = read_git_branch();

    // Effort level suffix (e.g. " high"), space-joined with no "|" separator
    let effort_suffix = match effort_level {
        Some(level) => format!(" {}{}{}", effort_color(&level), level, COLOR_RESET),
        None => String::new(),
    };

    // Build line 1: [Model] effort | 📁 dir | 🌿 branch
    let line1 = format!(
        "{}{}{}{} | 📁 {}{}{}{}",
        STYLE_BOLD,
        model_name,
        COLOR_RESET,
        effort_suffix,
        COLOR_CYAN,
        dir_basename,
        COLOR_RESET,
        git_branch
    );

    // Build line 2 (only if there's data)
    let mut line2 = String::new();
    let mut has_content = false;

    if let Some(pct) = used_pct {
        let (color, reset) = pct_color(pct);
        line2.push_str(&format!("{}🎫 {:.0}%{}", color, pct, reset));
        has_content = true;
    }

    if let Some(pct) = five_hour_pct {
        let (color, reset) = pct_color(pct);
        if has_content {
            line2.push_str(" | ");
        }
        let reset_suffix = format_reset_suffix(five_hour_resets_at);
        line2.push_str(&format!(
            "⏱️ 5h: {}{:.0}%{}{}",
            color, pct, reset, reset_suffix
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
