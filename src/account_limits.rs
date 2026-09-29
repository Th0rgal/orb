//! Usage-limit bookkeeping shared by every account-selection path.
//!
//! A subscription that reaches its usage limit says when the limit resets
//! ("You've hit your session limit · resets 5:30pm (Europe/Berlin)", "try
//! again at Apr 28th, 2026 10:03 PM"). This module reads that time and keeps
//! the account parked until then, in one registry that the inference proxy
//! (`ProviderHealthTracker`), the Codex lease pool and Claude rotation all
//! consult. The registry is written to disk next to the provider store, so a
//! backend restart does not send missions back to an exhausted account.
//!
//! It also keeps the remaining quota the usage endpoints last reported, so
//! that among healthy accounts the one with the most quota left goes first.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// File name of the persisted registry, inside `.sandboxed-sh/`.
pub const COOLDOWNS_FILE: &str = "account_cooldowns.json";

/// Cooldown applied when a usage-limit message carries no readable reset time.
pub const DEFAULT_LIMIT_COOLDOWN_SECS: i64 = 3600;

/// A reset announced further away than this is treated as unreadable: the
/// longest real window is a week, so anything beyond a month is a misparse.
const MAX_RESET_HORIZON_DAYS: i64 = 35;

/// An announced time that passed less than this long ago means "reset just
/// happened", not "resets tomorrow at the same time".
const JUST_PASSED_GRACE_MINUTES: i64 = 30;

// ─────────────────────────────────────────────────────────────────────────────
// Reset-time parsing
// ─────────────────────────────────────────────────────────────────────────────

/// The timezone a limit message's wall-clock time is expressed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    Named(chrono_tz::Tz),
    Fixed(chrono::FixedOffset),
}

impl Zone {
    pub const UTC: Zone = Zone::Named(chrono_tz::UTC);

    /// The zone of the machine running the harness, used when the message
    /// names none. A named zone is preferred over the current offset so a
    /// time past the next DST change is still converted correctly.
    pub fn system() -> Zone {
        let named = std::env::var("TZ")
            .ok()
            .map(|tz| tz.trim_start_matches(':').to_string())
            .or_else(|| {
                let target = std::fs::read_link("/etc/localtime").ok()?;
                let target = target.to_string_lossy();
                target
                    .split_once("zoneinfo/")
                    .map(|(_, name)| name.to_string())
            })
            .and_then(|name| name.trim().parse::<chrono_tz::Tz>().ok());
        match named {
            Some(tz) => Zone::Named(tz),
            None => {
                use chrono::Offset;
                Zone::Fixed(chrono::Local::now().offset().fix())
            }
        }
    }

    fn local(&self, at: DateTime<Utc>) -> NaiveDateTime {
        match self {
            Zone::Named(tz) => at.with_timezone(tz).naive_local(),
            Zone::Fixed(offset) => at.with_timezone(offset).naive_local(),
        }
    }

    /// Convert a wall-clock time to an instant. A time that occurs twice (DST
    /// fall-back) resolves to the later instant, so a mission never resumes
    /// before the reset; a time that does not exist (spring-forward gap) is
    /// read as the first valid time after the gap.
    fn instant(&self, local: NaiveDateTime) -> Option<DateTime<Utc>> {
        fn resolve<Tz: TimeZone>(tz: &Tz, local: NaiveDateTime) -> Option<DateTime<Utc>> {
            match tz.from_local_datetime(&local) {
                chrono::LocalResult::Single(at) => Some(at.with_timezone(&Utc)),
                chrono::LocalResult::Ambiguous(first, second) => {
                    Some(first.max(second).with_timezone(&Utc))
                }
                chrono::LocalResult::None => None,
            }
        }
        let attempt = |local| match self {
            Zone::Named(tz) => resolve(tz, local),
            Zone::Fixed(offset) => resolve(offset, local),
        };
        attempt(local).or_else(|| attempt(local + Duration::hours(1)))
    }
}

fn zone_from_label(label: &str) -> Option<Zone> {
    let label = label.trim();
    let canonical = match label.to_ascii_uppercase().as_str() {
        "UTC" | "GMT" | "Z" => "Etc/UTC",
        "PST" | "PDT" | "PT" => "America/Los_Angeles",
        "MST" | "MDT" | "MT" => "America/Denver",
        "CST" | "CDT" | "CT" => "America/Chicago",
        "EST" | "EDT" | "ET" => "America/New_York",
        "BST" => "Europe/London",
        "CET" | "CEST" => "Europe/Paris",
        "JST" => "Asia/Tokyo",
        _ => label,
    };
    canonical.parse::<chrono_tz::Tz>().ok().map(Zone::Named)
}

/// Markers that introduce the reset time, most specific first.
const RESET_MARKERS: [(&str, bool); 8] = [
    ("try again at ", false),
    ("try again in ", true),
    ("resets at ", false),
    ("resets in ", true),
    ("reset at ", false),
    ("reset in ", true),
    ("resets on ", false),
    ("resets ", false),
];

static ABSOLUTE_RESET: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(concat!(
        r"(?i)^\s*",
        r"(?:(?P<mon>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+",
        r"(?P<day>\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(?P<year>\d{4})\b)?)?",
        r"[\s,]*(?:at\s+)?",
        r"(?:(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>am|pm)\b|(?P<h24>\d{1,2}):(?P<m24>\d{2})\b)?",
        r"\s*(?:\((?P<tz>[^)]{1,40})\))?",
    ))
    .expect("valid reset regex")
});

static RELATIVE_PART: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r"(?i)^[\s,]*(?:and\s+)?(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b",
    )
    .expect("valid duration regex")
});

fn parse_relative(window: &str) -> Option<Duration> {
    let mut rest = window;
    let mut total = Duration::zero();
    let mut matched = false;
    while let Some(caps) = RELATIVE_PART.captures(rest) {
        let amount: i64 = caps.get(1)?.as_str().parse().ok()?;
        let unit = caps.get(2)?.as_str().to_ascii_lowercase();
        let part = match unit.chars().next()? {
            'd' => Duration::try_days(amount),
            'h' => Duration::try_hours(amount),
            'm' => Duration::try_minutes(amount),
            _ => Duration::try_seconds(amount),
        }?;
        total = total.checked_add(&part)?;
        matched = true;
        rest = &rest[caps.get(0)?.end()..];
    }
    matched.then_some(total)
}

fn parse_absolute(window: &str, now: DateTime<Utc>, default_zone: Zone) -> Option<DateTime<Utc>> {
    let caps = ABSOLUTE_RESET.captures(window)?;
    let number = |name: &str| -> Option<u32> { caps.name(name)?.as_str().parse().ok() };

    let time = if let Some(hour) = number("h") {
        let pm = caps
            .name("ap")
            .is_some_and(|ap| ap.as_str().eq_ignore_ascii_case("pm"));
        if !(1..=12).contains(&hour) {
            return None;
        }
        Some((
            (hour % 12) + if pm { 12 } else { 0 },
            number("m").unwrap_or(0),
        ))
    } else {
        number("h24").map(|hour| (hour, number("m24").unwrap_or(0)))
    };
    let date = match (caps.name("mon"), number("day")) {
        (Some(month), Some(day)) => {
            const MONTHS: [&str; 12] = [
                "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            ];
            let month = month.as_str().to_ascii_lowercase();
            let month = MONTHS.iter().position(|name| *name == month)? as u32 + 1;
            Some((month, day, caps.name("year").map(|_| number("year"))))
        }
        _ => None,
    };
    if time.is_none() && date.is_none() {
        return None;
    }
    let zone = match caps.name("tz") {
        // A zone we cannot name would shift the time by hours: unreadable.
        Some(label) => zone_from_label(label.as_str())?,
        None => default_zone,
    };
    // A date without a time is the start of that day: resuming early costs
    // one turn that fails with the exact time, resuming late costs a day.
    let (hour, minute) = time.unwrap_or((0, 0));
    let at = |day: NaiveDate| zone.instant(day.and_hms_opt(hour, minute, 0)?);
    let just_passed = now - Duration::minutes(JUST_PASSED_GRACE_MINUTES);
    let today = zone.local(now).date();

    let reset = match date {
        None => {
            let reset = at(today)?;
            if reset >= just_passed {
                reset
            } else {
                at(today.succ_opt()?)?
            }
        }
        Some((month, day, Some(year))) => at(NaiveDate::from_ymd_opt(year? as i32, month, day)?)?,
        Some((month, day, None)) => {
            let this_year = at(NaiveDate::from_ymd_opt(today.year(), month, day)?);
            match this_year {
                Some(reset) if reset >= just_passed - Duration::days(1) => reset,
                _ => at(NaiveDate::from_ymd_opt(today.year() + 1, month, day)?)?,
            }
        }
    };
    Some(reset)
}

/// Read the reset time a usage-limit message announces.
///
/// Understands a time alone ("resets 5:30pm", "resets 17:30"), with a
/// timezone in parentheses, a date alone ("resets Oct 3"), a date and a time
/// ("try again at Apr 28th, 2026 10:03 PM") and a delay ("try again in 2
/// hours 5 minutes"). Times without a timezone are read in `default_zone`.
/// Returns `None` when nothing readable follows, or when the result is not a
/// plausible reset (long past, or more than a month away).
pub fn parse_limit_reset(
    message: &str,
    now: DateTime<Utc>,
    default_zone: Zone,
) -> Option<DateTime<Utc>> {
    let lower = message.to_ascii_lowercase();
    // ASCII lowercasing keeps byte offsets aligned with `message`.
    let (start, relative) = RESET_MARKERS
        .iter()
        .filter_map(|(marker, relative)| {
            lower
                .find(marker)
                .map(|at| (at, at + marker.len(), *relative))
        })
        .min_by_key(|(at, end, _)| (*at, std::cmp::Reverse(*end)))
        .map(|(_, end, relative)| (end, relative))?;
    let rest = &message[start..];
    let window = rest.lines().next().unwrap_or(rest);
    let window: String = window.chars().take(96).collect();

    let reset = if relative {
        now.checked_add_signed(parse_relative(&window)?)?
    } else {
        parse_absolute(&window, now, default_zone)?
    };
    let earliest = now - Duration::minutes(JUST_PASSED_GRACE_MINUTES) - Duration::days(1);
    let latest = now + Duration::days(MAX_RESET_HORIZON_DAYS);
    (reset >= earliest && reset <= latest).then_some(reset)
}

/// Read the reset time from a provider error body: the structured fields
/// ChatGPT and CLIProxyAPI send (`resets_at`, `resets_in_seconds`,
/// `reset_seconds`), else the message text.
pub fn parse_limit_reset_from_body(body: &[u8], now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let latest = now + Duration::days(MAX_RESET_HORIZON_DAYS);
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(body) {
        let error = value.get("error").unwrap_or(&value);
        let field = |name: &str| {
            error
                .get(name)
                .or_else(|| value.get(name))
                .and_then(|v| v.as_f64())
        };
        let structured = field("resets_at")
            .and_then(|at| DateTime::<Utc>::from_timestamp(at as i64, 0))
            .or_else(|| {
                field("resets_in_seconds")
                    .or_else(|| field("reset_seconds"))
                    .and_then(|secs| now.checked_add_signed(Duration::try_seconds(secs as i64)?))
            });
        if let Some(reset) = structured {
            if reset > now && reset <= latest {
                return Some(reset);
            }
        }
        let message = error
            .get("message")
            .or_else(|| value.get("message"))
            .and_then(|m| m.as_str());
        if let Some(message) = message {
            return parse_limit_reset(message, now, Zone::system());
        }
    }
    parse_limit_reset(&String::from_utf8_lossy(body), now, Zone::system())
}

/// True when the message reports an exhausted usage allowance (session,
/// weekly, credits), as opposed to a transient rate limit or an overloaded
/// provider, which recover within a retry budget.
pub fn is_usage_limit_message(message: &str) -> bool {
    let lower = message.replace('\u{2019}', "'").to_ascii_lowercase();
    const USAGE_LIMIT_MARKERS: [&str; 16] = [
        "hit your limit",
        "hit your usage limit",
        "usage limit",
        "usage_limit",
        "session limit",
        "weekly limit",
        "weekly quota exhausted",
        "weekly quota exceeded",
        "out of usage credits",
        "out of credits",
        "out of extra usage",
        "out of regular usage",
        "purchase more credits",
        "insufficient_quota",
        "exceeded your current quota",
        "switch to another model to continue",
    ];
    if USAGE_LIMIT_MARKERS
        .iter()
        .any(|marker| lower.contains(marker))
    {
        return true;
    }
    // "You've hit your Opus limit" and other named allowances.
    ["you've hit your ", "you have hit your "]
        .iter()
        .any(|start| {
            lower.find(start).is_some_and(|at| {
                let rest = &lower[at + start.len()..];
                rest.find("limit").is_some_and(|end| {
                    end <= 24
                        && rest[..end]
                            .chars()
                            .all(|c| c.is_ascii_alphabetic() || c == ' ' || c == '-')
                })
            })
        })
}

/// Name the limit for the operator: "Claude session limit", "Codex usage
/// limit". `account_kind` is the product name ("Claude", "Codex").
pub fn describe_limit(account_kind: &str, message: &str) -> String {
    let lower = message.replace('\u{2019}', "'").to_ascii_lowercase();
    let named = ["you've hit your ", "you have hit your "]
        .iter()
        .find_map(|start| {
            let rest = &lower[lower.find(start)? + start.len()..];
            let end = rest.find("limit")?;
            let name = rest[..end].trim();
            (end <= 24
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphabetic() || c == ' ' || c == '-'))
            .then(|| name.to_string())
        });
    match named {
        Some(name) if !name.is_empty() => format!("{account_kind} {name} limit"),
        Some(_) => format!("{account_kind} usage limit"),
        None if lower.contains("weekly") => format!("{account_kind} weekly limit"),
        None if lower.contains("credits") => format!("{account_kind} usage credits"),
        None => format!("{account_kind} usage limit"),
    }
}

/// When a usage limit lets the account work again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LimitReset {
    pub at: DateTime<Utc>,
    /// The provider announced this time; false when it is the default delay.
    pub announced: bool,
}

/// The announced reset of a usage-limit message, or the conservative default
/// when the message carries none we can read.
pub fn limit_reset(message: &str, now: DateTime<Utc>, default_zone: Zone) -> LimitReset {
    match parse_limit_reset(message, now, default_zone) {
        Some(at) => LimitReset {
            at,
            announced: true,
        },
        None => LimitReset {
            at: now + Duration::seconds(DEFAULT_LIMIT_COOLDOWN_SECS),
            announced: false,
        },
    }
}

/// Render a reset time for the operator, in the zone the limit was announced
/// in when known, else UTC.
pub fn format_reset(at: DateTime<Utc>, zone: Zone) -> String {
    match zone {
        Zone::Named(tz) => {
            let local = at.with_timezone(&tz);
            format!("{} ({})", local.format("%b %-d, %Y %-I:%M %p"), tz.name())
        }
        Zone::Fixed(offset) => {
            let local = at.with_timezone(&offset);
            format!("{} (UTC{})", local.format("%b %-d, %Y %-I:%M %p"), offset)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cooldown registry
// ─────────────────────────────────────────────────────────────────────────────

/// One account parked until its usage limit resets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LimitCooldown {
    /// When the account may be used again.
    pub until: DateTime<Utc>,
    /// Provider type id ("anthropic", "openai").
    pub provider: String,
    /// Which limit was hit, for the operator.
    #[serde(default)]
    pub limit: String,
    /// Whether `until` was announced by the provider or is the default delay.
    #[serde(default)]
    pub announced: bool,
    pub recorded_at: DateTime<Utc>,
}

impl LimitCooldown {
    pub fn new(provider: &str, limit: impl Into<String>, reset: LimitReset) -> Self {
        Self {
            until: reset.at,
            provider: provider.to_string(),
            limit: limit.into(),
            announced: reset.announced,
            recorded_at: Utc::now(),
        }
    }

    /// Build the cooldown for a usage-limit message from `provider`.
    pub fn from_message(provider: &str, account_kind: &str, message: &str) -> Self {
        let now = Utc::now();
        Self::new(
            provider,
            describe_limit(account_kind, message),
            limit_reset(message, now, Zone::system()),
        )
    }
}

#[derive(Serialize, Deserialize, Default)]
struct CooldownsFile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    cooldowns: HashMap<String, LimitCooldown>,
}

/// Registry key of a provider-store account.
pub fn account_key(account_id: Uuid) -> String {
    account_id.to_string()
}

/// Registry key of a shared subscription (several credentials, one allowance).
pub fn subscription_key(subscription: &str) -> String {
    format!("subscription:{subscription}")
}

/// Registry key of a credential that is not a provider-store account. Only a
/// digest is kept: the registry is persisted and must not hold secrets.
pub fn credential_key(secret: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(secret.as_bytes());
    format!("credential:{}", hex::encode(&digest[..8]))
}

/// Accounts parked until their usage limit resets, keyed by
/// [`account_key`], [`subscription_key`] or [`credential_key`].
#[derive(Debug, Default)]
pub struct AccountCooldowns {
    path: Mutex<Option<PathBuf>>,
    entries: Mutex<HashMap<String, LimitCooldown>>,
}

impl AccountCooldowns {
    /// A registry that lives only in memory.
    pub fn in_memory() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// A registry backed by `path`, loaded from it when it exists.
    pub fn load(path: PathBuf) -> Arc<Self> {
        let registry = Self::default();
        registry.attach(path);
        Arc::new(registry)
    }

    /// Back the registry with `path`: entries stored there that have not
    /// expired are loaded (an entry already in memory wins), and every later
    /// change is written back.
    pub fn attach(&self, path: PathBuf) {
        let loaded = read_cooldowns(&path);
        let now = Utc::now();
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let stored = loaded.len();
        for (key, cooldown) in loaded {
            if cooldown.until > now {
                entries.entry(key).or_insert(cooldown);
            }
        }
        tracing::info!(
            path = %path.display(),
            stored,
            active = entries.len(),
            "Loaded account usage-limit cooldowns"
        );
        *self.path.lock().unwrap_or_else(|e| e.into_inner()) = Some(path);
        let expired_on_disk = stored > entries.len();
        if expired_on_disk {
            self.persist(&entries);
        }
    }

    /// Park `key` until `cooldown.until`. A newer announcement replaces the
    /// previous one, since it is what the provider says now.
    pub fn set(&self, key: &str, cooldown: LimitCooldown) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        if entries.get(key) == Some(&cooldown) {
            return;
        }
        entries.insert(key.to_string(), cooldown);
        self.persist(&entries);
    }

    /// Forget the cooldown of `key`. Returns whether one was recorded.
    pub fn clear(&self, key: &str) -> bool {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        let removed = entries.remove(key).is_some();
        if removed {
            self.persist(&entries);
        }
        removed
    }

    /// The cooldown of `key`, when it has not expired at `now`.
    pub fn active_at(&self, key: &str, now: DateTime<Utc>) -> Option<LimitCooldown> {
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries
            .get(key)
            .filter(|cooldown| cooldown.until > now)
            .cloned()
    }

    pub fn active(&self, key: &str) -> Option<LimitCooldown> {
        self.active_at(key, Utc::now())
    }

    pub fn is_cooling(&self, key: &str) -> bool {
        self.active(key).is_some()
    }

    /// Time left before `key` may be used again.
    pub fn remaining(&self, key: &str) -> Option<std::time::Duration> {
        let now = Utc::now();
        self.active_at(key, now)
            .and_then(|cooldown| (cooldown.until - now).to_std().ok())
    }

    /// Every cooldown still running at `now`.
    pub fn all_active_at(&self, now: DateTime<Utc>) -> Vec<(String, LimitCooldown)> {
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries
            .iter()
            .filter(|(_, cooldown)| cooldown.until > now)
            .map(|(key, cooldown)| (key.clone(), cooldown.clone()))
            .collect()
    }

    /// Write the registry, without the entries that have expired. The file is
    /// replaced atomically so a crash cannot leave it half written.
    fn persist(&self, entries: &HashMap<String, LimitCooldown>) {
        let Some(path) = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return;
        };
        let now = Utc::now();
        let file = CooldownsFile {
            version: 1,
            cooldowns: entries
                .iter()
                .filter(|(_, cooldown)| cooldown.until > now)
                .map(|(key, cooldown)| (key.clone(), cooldown.clone()))
                .collect(),
        };
        if let Err(error) = write_cooldowns(&path, &file) {
            tracing::warn!(
                path = %path.display(),
                error = %error,
                "Could not persist account usage-limit cooldowns"
            );
        }
    }
}

fn read_cooldowns(path: &Path) -> HashMap<String, LimitCooldown> {
    let contents = match std::fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return HashMap::new(),
        Err(error) => {
            tracing::warn!(path = %path.display(), error = %error, "Could not read account cooldowns");
            return HashMap::new();
        }
    };
    match serde_json::from_str::<CooldownsFile>(&contents) {
        Ok(file) => file.cooldowns,
        Err(error) => {
            tracing::warn!(path = %path.display(), error = %error, "Ignoring unreadable account cooldowns file");
            HashMap::new()
        }
    }
}

fn write_cooldowns(path: &Path, file: &CooldownsFile) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(file)?)?;
    std::fs::rename(&tmp, path)
}

static SHARED: LazyLock<Arc<AccountCooldowns>> = LazyLock::new(AccountCooldowns::in_memory);

/// The process-wide registry. In memory until [`AccountCooldowns::attach`]
/// gives it a file at startup.
pub fn shared() -> Arc<AccountCooldowns> {
    Arc::clone(&SHARED)
}

// ─────────────────────────────────────────────────────────────────────────────
// Remaining quota
// ─────────────────────────────────────────────────────────────────────────────

/// Usage older than this no longer orders accounts: the allowance may have
/// reset or been spent since.
pub const QUOTA_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// Accounts whose remaining quota differs by less than this many points keep
/// their configured order, so selection does not flap between two accounts
/// that are about as full (each switch costs the provider-side prompt cache).
const QUOTA_STEP_PERCENT: f64 = 10.0;

/// Remaining quota per account, as last reported by the usage endpoints the
/// Providers page reads. Filled when that data is fetched; selection only
/// reads it, it never calls a provider.
#[derive(Debug, Default)]
pub struct QuotaHints {
    entries: Mutex<HashMap<String, (f64, std::time::Instant)>>,
}

impl QuotaHints {
    pub fn in_memory() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Record that `key` has `remaining_percent` (0-100) of its most
    /// constrained usage window left.
    pub fn record(&self, key: &str, remaining_percent: f64) {
        self.record_at(key, remaining_percent, std::time::Instant::now());
    }

    fn record_at(&self, key: &str, remaining_percent: f64, at: std::time::Instant) {
        if !remaining_percent.is_finite() {
            return;
        }
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.insert(key.to_string(), (remaining_percent.clamp(0.0, 100.0), at));
    }

    /// Remaining quota of `key`, when it was reported recently enough.
    pub fn remaining(&self, key: &str) -> Option<f64> {
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries
            .get(key)
            .filter(|(_, at)| at.elapsed() < QUOTA_MAX_AGE)
            .map(|(remaining, _)| *remaining)
    }

    pub fn forget(&self, key: &str) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.remove(key);
    }
}

static SHARED_QUOTA: LazyLock<Arc<QuotaHints>> = LazyLock::new(QuotaHints::in_memory);

/// The process-wide remaining-quota hints.
pub fn shared_quota() -> Arc<QuotaHints> {
    Arc::clone(&SHARED_QUOTA)
}

/// Remaining quota (0-100) of a subscription account, from the usage payload
/// the Providers page shows: the most constrained of its subscription windows
/// (Claude 5-hour and 7-day, Codex primary and secondary). Per-minute request
/// and token windows are not quota and are ignored.
pub fn remaining_quota_from_usage(usage: &serde_json::Value) -> Option<f64> {
    const SUBSCRIPTION_WINDOWS: [&str; 4] = [
        "anthropic_5h",
        "anthropic_7d",
        "codex_primary",
        "codex_secondary",
    ];
    usage
        .get("optimize")?
        .get("windows")?
        .as_array()?
        .iter()
        .filter(|window| {
            window
                .get("key")
                .and_then(|key| key.as_str())
                .is_some_and(|key| SUBSCRIPTION_WINDOWS.contains(&key))
        })
        .filter_map(|window| window.get("pct_remaining")?.as_f64())
        .filter(|remaining| remaining.is_finite())
        .min_by(|a, b| a.total_cmp(b))
}

/// Put the accounts with the most remaining quota first. Only the accounts
/// whose quota is known move, and only among the positions they already hold:
/// with no usage data, or a single account, the order is unchanged.
pub fn prefer_most_remaining_quota<T>(
    items: Vec<T>,
    remaining: impl Fn(&T) -> Option<f64>,
) -> Vec<T> {
    let steps: Vec<Option<i64>> = items
        .iter()
        .map(|item| remaining(item).map(|left| (left / QUOTA_STEP_PERCENT).floor() as i64))
        .collect();
    if steps.iter().flatten().count() < 2 {
        return items;
    }
    let mut known = Vec::new();
    let mut slots: Vec<Option<T>> = Vec::with_capacity(items.len());
    for (item, step) in items.into_iter().zip(&steps) {
        match step {
            Some(step) => {
                known.push((*step, item));
                slots.push(None);
            }
            None => slots.push(Some(item)),
        }
    }
    // Stable: equally full accounts keep their configured order.
    known.sort_by_key(|(step, _)| std::cmp::Reverse(*step));
    let mut known = known.into_iter().map(|(_, item)| item);
    slots
        .into_iter()
        .filter_map(|slot| slot.or_else(|| known.next()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    fn berlin() -> Zone {
        Zone::Named(chrono_tz::Europe::Berlin)
    }

    #[test]
    fn claude_time_with_timezone() {
        // 14:00 UTC is 16:00 in Berlin (CEST); 5:30pm Berlin is 15:30 UTC.
        let now = utc("2026-09-29T14:00:00Z");
        let reset = parse_limit_reset(
            "You've hit your session limit · resets 5:30pm (Europe/Berlin)",
            now,
            Zone::UTC,
        );
        assert_eq!(reset, Some(utc("2026-09-29T15:30:00Z")));
    }

    #[test]
    fn claude_time_without_minutes_or_timezone_uses_the_default_zone() {
        let now = utc("2026-09-29T14:00:00Z");
        assert_eq!(
            parse_limit_reset("You've hit your limit · resets 9pm", now, Zone::UTC),
            Some(utc("2026-09-29T21:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("You've hit your limit · resets 9pm", now, berlin()),
            Some(utc("2026-09-29T19:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("Limit reached. resets at 17:45 (UTC)", now, berlin()),
            Some(utc("2026-09-29T17:45:00Z"))
        );
    }

    #[test]
    fn a_time_already_passed_today_means_tomorrow() {
        let now = utc("2026-09-29T20:00:00Z");
        assert_eq!(
            parse_limit_reset("resets 3am (UTC)", now, Zone::UTC),
            Some(utc("2026-09-30T03:00:00Z"))
        );
        // Midnight and noon in 12-hour notation.
        assert_eq!(
            parse_limit_reset("resets 12am (UTC)", now, Zone::UTC),
            Some(utc("2026-09-30T00:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("resets 12:15pm (UTC)", now, Zone::UTC),
            Some(utc("2026-09-30T12:15:00Z"))
        );
    }

    #[test]
    fn a_time_that_just_passed_is_not_pushed_to_tomorrow() {
        let now = utc("2026-09-29T15:40:00Z");
        assert_eq!(
            parse_limit_reset("resets 5:30pm (Europe/Berlin)", now, Zone::UTC),
            Some(utc("2026-09-29T15:30:00Z"))
        );
    }

    #[test]
    fn claude_date_forms() {
        let now = utc("2026-09-29T14:00:00Z");
        // Date alone: start of that day in the announced zone.
        assert_eq!(
            parse_limit_reset(
                "You've hit your weekly limit · resets Oct 3",
                now,
                Zone::UTC
            ),
            Some(utc("2026-10-03T00:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset(
                "You've hit your weekly limit · resets Oct 3 (Europe/Berlin)",
                now,
                Zone::UTC
            ),
            Some(utc("2026-10-02T22:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset(
                "You've hit your weekly limit · resets Oct 3, 5pm (Europe/Berlin)",
                now,
                Zone::UTC
            ),
            Some(utc("2026-10-03T15:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("resets Oct 3 at 5:15pm (UTC)", now, Zone::UTC),
            Some(utc("2026-10-03T17:15:00Z"))
        );
    }

    #[test]
    fn full_month_names_are_read() {
        let now = utc("2026-09-29T14:00:00Z");
        assert_eq!(
            parse_limit_reset("resets October 3 (UTC)", now, Zone::UTC),
            Some(utc("2026-10-03T00:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("try again at October 3rd, 2026 6:58 PM.", now, Zone::UTC),
            Some(utc("2026-10-03T18:58:00Z"))
        );
        assert_eq!(
            parse_limit_reset("resets Sept. 30, 9am (UTC)", now, Zone::UTC),
            Some(utc("2026-09-30T09:00:00Z"))
        );
    }

    #[test]
    fn a_date_without_year_rolls_over_new_year() {
        let now = utc("2026-12-30T10:00:00Z");
        assert_eq!(
            parse_limit_reset("resets Jan 2 (UTC)", now, Zone::UTC),
            Some(utc("2027-01-02T00:00:00Z"))
        );
    }

    #[test]
    fn codex_date_and_time() {
        let now = utc("2026-04-27T09:00:00Z");
        let message = "You've hit your usage limit. Visit \
            https://chatgpt.com/codex/settings/usage to purchase more credits or try again at \
            Apr 28th, 2026 10:03 PM.";
        assert_eq!(
            parse_limit_reset(message, now, Zone::UTC),
            Some(utc("2026-04-28T22:03:00Z"))
        );
        assert_eq!(
            parse_limit_reset(message, now, berlin()),
            Some(utc("2026-04-28T20:03:00Z"))
        );
        for (ordinal, day) in [("1st", 1), ("2nd", 2), ("3rd", 3), ("21st", 21)] {
            let message = format!("try again at May {ordinal}, 2026 7:00 AM.");
            assert_eq!(
                parse_limit_reset(&message, now, Zone::UTC),
                Some(Utc.with_ymd_and_hms(2026, 5, day, 7, 0, 0).unwrap()),
                "{message}"
            );
        }
        assert_eq!(
            parse_limit_reset("try again at 3:12 PM.", now, Zone::UTC),
            Some(utc("2026-04-27T15:12:00Z"))
        );
    }

    #[test]
    fn relative_delays() {
        let now = utc("2026-04-27T09:00:00Z");
        assert_eq!(
            parse_limit_reset("try again in 2 hours 5 minutes.", now, Zone::UTC),
            Some(utc("2026-04-27T11:05:00Z"))
        );
        assert_eq!(
            parse_limit_reset("Usage limit reached, resets in 3d 4h", now, Zone::UTC),
            Some(utc("2026-04-30T13:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("try again in a while", now, Zone::UTC),
            None
        );
    }

    #[test]
    fn dst_changes_do_not_shift_the_reset() {
        // Europe/Berlin leaves DST on 2026-10-25 at 03:00 local (01:00 UTC).
        // Read the evening before, "resets 9am" is 08:00 UTC, not 07:00.
        let now = utc("2026-10-24T20:00:00Z");
        assert_eq!(
            parse_limit_reset("resets 9am (Europe/Berlin)", now, Zone::UTC),
            Some(utc("2026-10-25T08:00:00Z"))
        );
        // 02:30 happens twice that night: the later instant is used.
        assert_eq!(
            parse_limit_reset("resets 2:30am (Europe/Berlin)", now, Zone::UTC),
            Some(utc("2026-10-25T01:30:00Z"))
        );
        // Europe/Berlin enters DST on 2026-03-29: 02:30 does not exist and
        // is read as 03:30 local (01:30 UTC).
        let now = utc("2026-03-28T20:00:00Z");
        assert_eq!(
            parse_limit_reset("resets 2:30am (Europe/Berlin)", now, Zone::UTC),
            Some(utc("2026-03-29T01:30:00Z"))
        );
        assert_eq!(
            parse_limit_reset("resets 9am (Europe/Berlin)", now, Zone::UTC),
            Some(utc("2026-03-29T07:00:00Z"))
        );
        // America/New_York, abbreviations included.
        let now = utc("2026-07-01T12:00:00Z");
        assert_eq!(
            parse_limit_reset("resets 5pm (America/New_York)", now, Zone::UTC),
            Some(utc("2026-07-01T21:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset("resets 5pm (PST)", now, Zone::UTC),
            Some(utc("2026-07-02T00:00:00Z"))
        );
    }

    #[test]
    fn unreadable_messages_fall_back_to_the_default_delay() {
        let now = utc("2026-09-29T14:00:00Z");
        for message in [
            "You've hit your session limit",
            "You've hit your session limit · resets soon",
            "resets 5pm (Mars/Olympus_Mons)",
            "resets 25:99",
            "resets 13pm",
            "try again at Feb 31st, 2027 1:00 AM.",
            "try again at Apr 28th, 2020 10:03 PM.",
            "try again at Apr 28th, 2031 10:03 PM.",
            "",
        ] {
            assert_eq!(
                parse_limit_reset(message, now, Zone::UTC),
                None,
                "{message}"
            );
            let reset = limit_reset(message, now, Zone::UTC);
            assert!(!reset.announced);
            assert_eq!(reset.at, now + Duration::hours(1));
        }
        let reset = limit_reset("resets 5pm (UTC)", now, Zone::UTC);
        assert!(reset.announced);
        assert_eq!(reset.at, utc("2026-09-29T17:00:00Z"));
    }

    #[test]
    fn reset_from_error_bodies() {
        let now = utc("2026-09-29T14:00:00Z");
        let at = now.timestamp() + 7200;
        let body = format!(
            r#"{{"error":{{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_at":{at}}}}}"#
        );
        assert_eq!(
            parse_limit_reset_from_body(body.as_bytes(), now),
            Some(utc("2026-09-29T16:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset_from_body(
                br#"{"error":{"type":"usage_limit_reached","resets_in_seconds":600}}"#,
                now
            ),
            Some(utc("2026-09-29T14:10:00Z"))
        );
        assert_eq!(
            parse_limit_reset_from_body(
                br#"{"error":{"message":"You've hit your usage limit. Try again at Sep 30th, 2026 1:00 AM (UTC)."}}"#,
                now
            ),
            Some(utc("2026-09-30T01:00:00Z"))
        );
        assert_eq!(
            parse_limit_reset_from_body(br#"{"error":{"message":"rate limited"}}"#, now),
            None
        );
    }

    #[test]
    fn usage_limits_are_told_apart_from_transient_rate_limits() {
        for message in [
            "You've hit your session limit · resets 5:30pm (Europe/Berlin)",
            "You\u{2019}ve hit your limit · resets 9pm",
            "You've hit your Opus limit · resets Oct 3",
            "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage",
            "You're out of usage credits. Switch to another model to continue.",
            r#"{"error":{"type":"usage_limit_reached"}}"#,
        ] {
            assert!(is_usage_limit_message(message), "{message}");
        }
        for message in [
            "overloaded_error",
            "Error: 429 Too Many Requests",
            "rate_limit_error: This request would exceed your rate limit",
            "status code: 529",
            "The build hit its limit of retries",
        ] {
            assert!(!is_usage_limit_message(message), "{message}");
        }
    }

    #[test]
    fn limits_are_named_for_the_operator() {
        assert_eq!(
            describe_limit("Claude", "You've hit your session limit · resets 5:30pm"),
            "Claude session limit"
        );
        assert_eq!(
            describe_limit("Claude", "You've hit your limit · resets 9pm"),
            "Claude usage limit"
        );
        assert_eq!(
            describe_limit("Codex", "You've hit your usage limit. Visit …"),
            "Codex usage limit"
        );
        assert_eq!(
            describe_limit("Claude", "You're out of usage credits."),
            "Claude usage credits"
        );
    }

    fn cooldown(until: DateTime<Utc>) -> LimitCooldown {
        LimitCooldown {
            until,
            provider: "anthropic".to_string(),
            limit: "Claude session limit".to_string(),
            announced: true,
            recorded_at: utc("2026-09-29T14:00:00Z"),
        }
    }

    #[test]
    fn cooldowns_survive_a_restart() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join(".sandboxed-sh").join(COOLDOWNS_FILE);
        let account = account_key(Uuid::new_v4());
        let other = credential_key("sk-secret-value");
        let expired = account_key(Uuid::new_v4());
        let until = Utc::now() + Duration::hours(3);

        let registry = AccountCooldowns::load(path.clone());
        registry.set(&account, cooldown(until));
        registry.set(&other, cooldown(until + Duration::hours(1)));
        registry.set(&expired, cooldown(Utc::now() - Duration::minutes(1)));
        assert!(registry.is_cooling(&account));
        assert!(!registry.is_cooling(&expired));

        let stored = std::fs::read_to_string(&path).unwrap();
        assert!(!stored.contains("sk-secret-value"), "no secret on disk");
        assert!(!stored.contains(&expired), "expired entries are dropped");

        let restarted = AccountCooldowns::load(path.clone());
        assert_eq!(restarted.active(&account), Some(cooldown(until)));
        assert!(restarted.is_cooling(&other));
        assert!(!restarted.is_cooling(&expired));
        let remaining = restarted.remaining(&account).unwrap();
        assert!(remaining > std::time::Duration::from_secs(3 * 3600 - 60));

        assert!(restarted.clear(&account));
        assert!(!restarted.clear(&account));
        let again = AccountCooldowns::load(path);
        assert!(!again.is_cooling(&account));
        assert!(again.is_cooling(&other));
    }

    #[test]
    fn expired_entries_on_disk_are_dropped_at_load() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join(COOLDOWNS_FILE);
        let live = account_key(Uuid::new_v4());
        let stale = account_key(Uuid::new_v4());
        let file = CooldownsFile {
            version: 1,
            cooldowns: HashMap::from([
                (live.clone(), cooldown(Utc::now() + Duration::hours(1))),
                (stale.clone(), cooldown(Utc::now() - Duration::hours(1))),
            ]),
        };
        std::fs::write(&path, serde_json::to_vec(&file).unwrap()).unwrap();

        let registry = AccountCooldowns::load(path.clone());
        assert!(registry.is_cooling(&live));
        assert!(!registry.is_cooling(&stale));
        assert_eq!(registry.all_active_at(Utc::now()).len(), 1);
        let rewritten = std::fs::read_to_string(&path).unwrap();
        assert!(rewritten.contains(&live));
        assert!(!rewritten.contains(&stale));
    }

    #[test]
    fn an_unreadable_file_starts_empty_and_is_replaced() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join(COOLDOWNS_FILE);
        std::fs::write(&path, "{ not json").unwrap();
        let registry = AccountCooldowns::load(path.clone());
        assert!(registry.all_active_at(Utc::now()).is_empty());
        let key = account_key(Uuid::new_v4());
        registry.set(&key, cooldown(Utc::now() + Duration::hours(1)));
        assert!(AccountCooldowns::load(path).is_cooling(&key));
    }

    #[test]
    fn most_remaining_quota_comes_first() {
        let quota = HashMap::from([("a", 53.0), ("b", 96.0), ("c", 12.0)]);
        let ordered =
            prefer_most_remaining_quota(vec!["a", "b", "c"], |account| quota.get(account).copied());
        assert_eq!(ordered, vec!["b", "a", "c"]);
    }

    #[test]
    fn order_is_unchanged_without_usage_data_or_with_one_account() {
        let none = |_: &&str| None;
        assert_eq!(
            prefer_most_remaining_quota(vec!["a", "b", "c"], none),
            vec!["a", "b", "c"]
        );
        assert_eq!(
            prefer_most_remaining_quota(vec!["a"], |_| Some(3.0)),
            vec!["a"]
        );
        // One account with data has nothing to be compared with.
        assert_eq!(
            prefer_most_remaining_quota(vec!["a", "b"], |account| {
                (*account == "b").then_some(99.0)
            }),
            vec!["a", "b"]
        );
        assert_eq!(
            prefer_most_remaining_quota(Vec::<&str>::new(), |_| Some(1.0)),
            Vec::<&str>::new()
        );
    }

    #[test]
    fn accounts_without_usage_data_keep_their_position() {
        let quota = HashMap::from([("a", 20.0), ("c", 90.0)]);
        let ordered = prefer_most_remaining_quota(vec!["a", "b", "c", "d"], |account| {
            quota.get(account).copied()
        });
        assert_eq!(ordered, vec!["c", "b", "a", "d"]);
    }

    #[test]
    fn about_equally_full_accounts_keep_their_configured_order() {
        let quota = HashMap::from([("a", 61.0), ("b", 68.9), ("c", 70.0)]);
        let ordered =
            prefer_most_remaining_quota(vec!["a", "b", "c"], |account| quota.get(account).copied());
        assert_eq!(ordered, vec!["c", "a", "b"]);
    }

    #[test]
    fn quota_hints_expire() {
        let hints = QuotaHints::default();
        hints.record("fresh", 40.0);
        hints.record("clamped", 140.0);
        hints.record("nan", f64::NAN);
        assert_eq!(hints.remaining("fresh"), Some(40.0));
        assert_eq!(hints.remaining("clamped"), Some(100.0));
        assert_eq!(hints.remaining("nan"), None);
        assert_eq!(hints.remaining("unknown"), None);

        let Some(long_ago) = std::time::Instant::now()
            .checked_sub(QUOTA_MAX_AGE + std::time::Duration::from_secs(1))
        else {
            // The machine booted less than QUOTA_MAX_AGE ago.
            return;
        };
        hints.record_at("old", 40.0, long_ago);
        assert_eq!(hints.remaining("old"), None);
        hints.forget("fresh");
        assert_eq!(hints.remaining("fresh"), None);
    }

    #[test]
    fn remaining_quota_is_the_most_constrained_subscription_window() {
        let usage = serde_json::json!({
            "optimize": { "windows": [
                { "key": "anthropic_5h", "pct_remaining": 96.0 },
                { "key": "anthropic_7d", "pct_remaining": 53.0 },
                { "key": "requests", "pct_remaining": 2.0 }
            ]}
        });
        assert_eq!(remaining_quota_from_usage(&usage), Some(53.0));
        let codex = serde_json::json!({
            "optimize": { "windows": [
                { "key": "codex_primary", "pct_remaining": 80.0 },
                { "key": "codex_secondary", "pct_remaining": 0.0 }
            ]}
        });
        assert_eq!(remaining_quota_from_usage(&codex), Some(0.0));
        for no_quota in [
            serde_json::json!({}),
            serde_json::json!({ "optimize": { "windows": [] } }),
            serde_json::json!({ "optimize": { "windows": [
                { "key": "tokens", "pct_remaining": 10.0 },
                { "key": "anthropic_5h", "pct_remaining": null }
            ]}}),
        ] {
            assert_eq!(remaining_quota_from_usage(&no_quota), None);
        }
    }
}
