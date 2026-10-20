//! Mission search scoring, caching and search HTTP handlers.

use super::*;

pub(super) fn mission_search_synonyms(token: &str) -> &'static [&'static str] {
    match token {
        "api" => &["endpoint", "http", "rest", "rpc"],
        "auth" => &["login", "signin", "oauth", "credential", "credentials"],
        "blocked" => &["stalled", "waiting"],
        "bug" => &["issue", "error", "fix", "problem"],
        "ci" => &["pipeline", "build", "integration", "tests"],
        "crash" => &["panic", "exception", "failure"],
        "db" => &["database", "sql", "sqlite", "postgres"],
        "cd" => &["deploy", "release", "rollout", "ship"],
        "deploy" => &["release", "rollout", "ship"],
        "error" => &["bug", "issue", "failure"],
        "failed" => &["error", "failure"],
        "fix" => &["bug", "issue", "error", "repair"],
        "issue" => &["bug", "error", "problem", "fix"],
        "login" => &["auth", "signin", "oauth", "credentials"],
        "perf" => &["performance", "slow", "latency", "optimize"],
        "performance" => &["perf", "slow", "latency", "optimize"],
        "release" => &["deploy", "rollout", "ship"],
        "sid" => &["session", "id", "sessionid", "cookie", "token"],
        "signin" => &["login", "auth", "oauth", "credentials"],
        "slow" => &["performance", "latency", "timeout", "stall"],
        "sso" => &["signin", "login", "auth", "oauth"],
        "stalled" => &["blocked", "waiting", "timeout"],
        "timeout" => &["slow", "latency", "stalled", "hang"],
        "ui" => &["ux", "interface", "frontend"],
        "ux" => &["ui", "interface", "frontend"],
        _ => &[],
    }
}

pub(super) fn mission_search_phrase_expansions(token: &str) -> &'static [&'static str] {
    match token {
        "ci" => &["continuous integration"],
        "cd" => &["continuous deployment"],
        "sid" => &["session id"],
        "sso" => &["single sign on"],
        _ => &[],
    }
}

pub(super) fn expand_search_query_group(token: &str) -> Vec<String> {
    let normalized = normalize_metadata_text(token);
    if normalized.is_empty() {
        return Vec::new();
    }

    let mut values = HashSet::new();
    values.insert(normalized.clone());
    for candidate in mission_search_synonyms(&normalized) {
        let normalized_candidate = normalize_metadata_text(candidate);
        if !normalized_candidate.is_empty() {
            values.insert(normalized_candidate);
        }
    }

    values.into_iter().collect()
}

pub(super) fn search_token_match_strength(token: &str, candidate: &str) -> f64 {
    if token == candidate {
        return 1.0;
    }

    let ascii_candidate = candidate
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit());
    let candidate_len = candidate.chars().count();
    let token_len = token.chars().count();

    if token.starts_with(candidate) && (!ascii_candidate || candidate_len >= 3) {
        return 0.7;
    }
    if ascii_candidate
        && token_len >= 5
        && candidate.starts_with(token)
        && candidate_len.saturating_sub(token_len) <= 2
    {
        return 0.65;
    }
    if candidate_len >= 4 && token.contains(candidate) {
        return 0.45;
    }
    0.0
}

pub(super) fn search_token_set(text: &str) -> HashSet<String> {
    normalize_metadata_text(text)
        .split_whitespace()
        .filter(|token| !token.is_empty())
        .map(ToString::to_string)
        .collect()
}

pub(super) fn is_search_stopword(token: &str) -> bool {
    matches!(
        token,
        "a" | "an"
            | "and"
            | "at"
            | "did"
            | "do"
            | "does"
            | "for"
            | "from"
            | "how"
            | "i"
            | "in"
            | "is"
            | "it"
            | "me"
            | "my"
            | "of"
            | "on"
            | "or"
            | "our"
            | "please"
            | "show"
            | "that"
            | "the"
            | "this"
            | "to"
            | "us"
            | "was"
            | "we"
            | "what"
            | "when"
            | "where"
            | "which"
            | "who"
            | "why"
            | "with"
            | "you"
            | "your"
    )
}

#[derive(Debug, Clone)]
pub(super) struct SearchQueryTerms {
    pub(super) normalized_query: String,
    pub(super) normalized_core_query: String,
    pub(super) query_groups: Vec<Vec<String>>,
    pub(super) phrase_queries: Vec<String>,
}

pub(super) fn build_search_query_terms(search_query: &str) -> Option<SearchQueryTerms> {
    let normalized_query = normalize_metadata_text(search_query);
    if normalized_query.is_empty() {
        return None;
    }

    let query_tokens: Vec<&str> = normalized_query.split_whitespace().collect();
    if query_tokens.is_empty() {
        return None;
    }

    let mut filtered_tokens: Vec<&str> = query_tokens
        .iter()
        .copied()
        .filter(|token| !is_search_stopword(token))
        .collect();
    if filtered_tokens.is_empty() {
        filtered_tokens = query_tokens.clone();
    }
    let normalized_core_query = filtered_tokens.join(" ");

    let query_groups: Vec<Vec<String>> = filtered_tokens
        .iter()
        .map(|token| expand_search_query_group(token))
        .filter(|group| !group.is_empty())
        .collect();
    if query_groups.is_empty() {
        return None;
    }

    let mut phrase_queries = Vec::new();
    phrase_queries.push(normalized_core_query.clone());
    for token in &filtered_tokens {
        for phrase in mission_search_phrase_expansions(token) {
            let normalized_phrase = normalize_metadata_text(phrase);
            if !normalized_phrase.is_empty() {
                phrase_queries.push(normalized_phrase);
            }
        }
    }
    phrase_queries.sort();
    phrase_queries.dedup();

    Some(SearchQueryTerms {
        normalized_query,
        normalized_core_query,
        query_groups,
        phrase_queries,
    })
}

pub(super) fn group_match_strength_for_token_set(
    group: &[String],
    token_set: &HashSet<String>,
) -> f64 {
    let mut best = 0.0;
    for candidate in group {
        if candidate.is_empty() {
            continue;
        }
        for token in token_set {
            let strength = search_token_match_strength(token, candidate);
            if strength > best {
                best = strength;
            }
            if best >= 1.0 {
                return best;
            }
        }
    }
    best
}

pub(super) fn mission_search_relevance_score(
    mission: &Mission,
    search_query: &str,
    workspace_label: Option<&str>,
) -> f64 {
    let Some(query_terms) = build_search_query_terms(search_query) else {
        return 0.0;
    };
    let phrase_queries = if query_terms.phrase_queries.is_empty() {
        vec![if query_terms.normalized_core_query.is_empty() {
            query_terms.normalized_query.clone()
        } else {
            query_terms.normalized_core_query.clone()
        }]
    } else {
        query_terms.phrase_queries.clone()
    };

    let title = mission.title.as_deref().unwrap_or("").trim();
    let short_description = mission.short_description.as_deref().unwrap_or("").trim();
    let backend = mission.backend.trim();
    let status = mission.status.to_string();
    let display_name = workspace_label.unwrap_or("");
    let combined = format!(
        "{} {} {} {} {}",
        display_name, title, short_description, backend, status
    );
    let normalized_combined = normalize_metadata_text(&combined);
    if normalized_combined.is_empty() {
        return 0.0;
    }

    let fields = [
        (5.0, search_token_set(display_name)),
        (8.0, search_token_set(title)),
        (7.0, search_token_set(short_description)),
        (3.0, search_token_set(backend)),
        (2.0, search_token_set(&status)),
        (1.0, search_token_set(&combined)),
    ];

    let mut score = 0.0;
    for group in &query_terms.query_groups {
        let mut best_group_score: f64 = 0.0;
        for (weight, token_set) in &fields {
            let strength = group_match_strength_for_token_set(group, token_set);
            if strength > 0.0 {
                best_group_score = best_group_score.max(strength * weight);
            }
        }
        if best_group_score <= 0.0 {
            return 0.0;
        }
        score += best_group_score;
    }

    let phrase_boost_targets = [
        (normalize_metadata_text(title), 14.0),
        (normalize_metadata_text(short_description), 12.0),
        (normalize_metadata_text(display_name), 8.0),
        (normalize_metadata_text(&combined), 5.0),
    ];
    for (target, boost) in phrase_boost_targets {
        if target.is_empty() {
            continue;
        }
        if phrase_queries
            .iter()
            .any(|phrase_query| !phrase_query.is_empty() && target.contains(phrase_query))
        {
            score += boost;
        }
    }

    score
}

#[derive(Debug, Clone)]
pub(super) struct MissionMomentMatch {
    pub(super) entry_index: usize,
    pub(super) role: String,
    pub(super) snippet: String,
    pub(super) rationale: String,
    pub(super) relevance_score: f64,
}

pub(super) fn mission_moment_snippet(content: &str, max_chars: usize) -> String {
    let collapsed = content.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return String::new();
    }
    if collapsed.chars().count() <= max_chars {
        return collapsed;
    }
    let mut result = String::new();
    for ch in collapsed.chars().take(max_chars) {
        result.push(ch);
    }
    result.push('…');
    result
}

pub(super) fn mission_moment_relevance_score(role: &str, content: &str, search_query: &str) -> f64 {
    let Some(query_terms) = build_search_query_terms(search_query) else {
        return 0.0;
    };
    let phrase_queries = if query_terms.phrase_queries.is_empty() {
        vec![if query_terms.normalized_core_query.is_empty() {
            query_terms.normalized_query.clone()
        } else {
            query_terms.normalized_core_query.clone()
        }]
    } else {
        query_terms.phrase_queries.clone()
    };
    let normalized_content = normalize_metadata_text(content);
    if normalized_content.is_empty() {
        return 0.0;
    }

    let content_tokens = search_token_set(content);
    let role_tokens = search_token_set(role);
    let mut score = 0.0;
    for group in &query_terms.query_groups {
        let content_strength = group_match_strength_for_token_set(group, &content_tokens);
        let role_strength = group_match_strength_for_token_set(group, &role_tokens);
        let best = (content_strength * 8.0).max(role_strength * 1.5);
        if best <= 0.0 {
            return 0.0;
        }
        score += best;
    }

    if phrase_queries
        .iter()
        .any(|phrase_query| !phrase_query.is_empty() && normalized_content.contains(phrase_query))
    {
        score += 10.0;
    }
    score
}

pub(super) fn mission_moment_rationale(role: &str, content: &str, search_query: &str) -> String {
    let query_terms = match build_search_query_terms(search_query) {
        Some(query_terms) => query_terms,
        None => return format!("Keyword match in {} message", role),
    };

    let phrase_queries = if query_terms.phrase_queries.is_empty() {
        vec![if query_terms.normalized_core_query.is_empty() {
            query_terms.normalized_query.clone()
        } else {
            query_terms.normalized_core_query.clone()
        }]
    } else {
        query_terms.phrase_queries.clone()
    };

    let normalized_content = normalize_metadata_text(content);
    if phrase_queries
        .iter()
        .any(|phrase_query| !phrase_query.is_empty() && normalized_content.contains(phrase_query))
    {
        return format!("Phrase match in {} message", role);
    }

    let content_tokens = search_token_set(content);
    let mut matched_terms = Vec::new();
    for group in &query_terms.query_groups {
        let mut best_candidate: Option<(&str, f64)> = None;
        for candidate in group {
            for token in &content_tokens {
                let strength = search_token_match_strength(token, candidate)
                    .max(search_token_match_strength(candidate, token));
                if strength <= 0.0 {
                    continue;
                }
                match best_candidate {
                    Some((_, best_strength)) if best_strength >= strength => {}
                    _ => best_candidate = Some((candidate.as_str(), strength)),
                }
            }
        }
        if let Some((candidate, _)) = best_candidate {
            matched_terms.push(candidate.to_string());
        }
    }

    if !matched_terms.is_empty() {
        matched_terms.sort();
        matched_terms.dedup();
        let matched_summary = matched_terms
            .into_iter()
            .take(3)
            .collect::<Vec<_>>()
            .join(", ");
        return format!("Matched {} in {} message", matched_summary, role);
    }

    format!("Keyword match in {} message", role)
}

pub(super) fn best_mission_moment(
    mission: &Mission,
    search_query: &str,
) -> Option<MissionMomentMatch> {
    let mut best: Option<MissionMomentMatch> = None;
    for (idx, entry) in mission.history.iter().enumerate() {
        let score = mission_moment_relevance_score(&entry.role, &entry.content, search_query);
        if score <= 0.0 {
            continue;
        }
        let candidate = MissionMomentMatch {
            entry_index: idx,
            role: entry.role.clone(),
            snippet: mission_moment_snippet(&entry.content, 180),
            rationale: mission_moment_rationale(&entry.role, &entry.content, search_query),
            relevance_score: score,
        };
        match &best {
            Some(existing) if existing.relevance_score >= candidate.relevance_score => {}
            _ => best = Some(candidate),
        }
    }
    best
}

#[derive(Debug, Clone)]
pub(super) struct MissionSearchCandidate {
    pub(super) mission: Mission,
    pub(super) relevance_score: f64,
}

pub(super) async fn list_missions_for_search(
    state: &Arc<AppState>,
    control: &ControlState,
    query: &str,
    limit: usize,
) -> Result<Vec<MissionSearchCandidate>, (StatusCode, String)> {
    const SEARCH_PAGE_SIZE_MIN: usize = 50;
    const SEARCH_PAGE_SIZE_MAX: usize = 200;
    const SEARCH_TARGET_MATCH_MULTIPLIER: usize = 8;
    const SEARCH_MAX_SCAN: usize = 10_000;

    let page_size = (limit.saturating_mul(5)).clamp(SEARCH_PAGE_SIZE_MIN, SEARCH_PAGE_SIZE_MAX);
    let target_matches = limit
        .saturating_mul(SEARCH_TARGET_MATCH_MULTIPLIER)
        .max(limit);

    let mut all = Vec::new();
    let mut offset = 0;
    let mut matched_total = 0usize;

    while offset < SEARCH_MAX_SCAN {
        let mut page = control
            .mission_store
            .list_missions(page_size, offset)
            .await
            .map_err(internal_error)?;
        if page.is_empty() {
            break;
        }
        populate_workspace_names(state, &mut page).await;
        let page_len = page.len();
        let mut matched_in_page = 0usize;
        for mission in page {
            let relevance_score =
                mission_search_relevance_score(&mission, query, mission.workspace_name.as_deref());
            if relevance_score > 0.0 {
                matched_in_page += 1;
            }
            all.push(MissionSearchCandidate {
                mission,
                relevance_score,
            });
        }
        matched_total += matched_in_page;
        if page_len < page_size {
            break;
        }
        offset += page_size;
        if matched_total >= target_matches {
            break;
        }
    }

    if offset >= SEARCH_MAX_SCAN {
        tracing::warn!(
            "Mission search scan hit cap ({} missions); some older missions may not be searched",
            SEARCH_MAX_SCAN
        );
    }

    Ok(all)
}

#[derive(Debug, Deserialize)]
pub struct SearchMissionsQuery {
    pub q: String,
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct SearchMissionMomentsQuery {
    pub q: String,
    pub mission_id: Option<Uuid>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MissionSearchResult {
    pub mission: Mission,
    pub relevance_score: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct MissionMomentSearchResult {
    pub mission: Mission,
    pub entry_index: usize,
    pub role: String,
    pub snippet: String,
    pub rationale: String,
    pub relevance_score: f64,
}

#[derive(Debug, Clone)]
pub struct MissionSearchCacheEntry {
    pub cached_at: std::time::Instant,
    pub freshness_key: u64,
    pub recency_fingerprint: u64,
    pub results: Vec<MissionSearchResult>,
}

pub(super) const MISSION_SEARCH_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(5);

pub(super) fn mission_search_cache_hit_by_ttl(
    entry: &MissionSearchCacheEntry,
    recency_fingerprint: u64,
) -> bool {
    entry.cached_at.elapsed() <= MISSION_SEARCH_CACHE_TTL
        && entry.recency_fingerprint == recency_fingerprint
}

pub(super) fn mission_search_cache_hit_by_freshness(
    entry: &MissionSearchCacheEntry,
    recency_fingerprint: u64,
    freshness_key: u64,
) -> bool {
    entry.recency_fingerprint == recency_fingerprint && entry.freshness_key == freshness_key
}

pub(super) fn mission_search_query_hash(query: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    normalize_metadata_text(query).hash(&mut hasher);
    hasher.finish()
}

pub(super) fn mission_search_freshness_key(
    missions: &[MissionSearchCandidate],
    page_size: usize,
) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    missions.len().hash(&mut hasher);
    page_size.hash(&mut hasher);
    for candidate in missions {
        let mission = &candidate.mission;
        mission.id.hash(&mut hasher);
        mission.updated_at.hash(&mut hasher);
        mission.metadata_updated_at.hash(&mut hasher);
        mission.workspace_name.hash(&mut hasher);
    }
    hasher.finish()
}

pub(super) async fn mission_search_recency_fingerprint(
    mission_store: &Arc<dyn MissionStore>,
) -> Result<u64, String> {
    const MISSION_SEARCH_RECENCY_FINGERPRINT_LIMIT: usize = 64;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let recent = mission_store
        .list_missions(MISSION_SEARCH_RECENCY_FINGERPRINT_LIMIT, 0)
        .await?;
    recent.len().hash(&mut hasher);
    for mission in recent {
        mission.id.hash(&mut hasher);
        mission.updated_at.hash(&mut hasher);
        mission.metadata_updated_at.hash(&mut hasher);
        mission.title.hash(&mut hasher);
        mission.short_description.hash(&mut hasher);
        mission.workspace_name.hash(&mut hasher);
    }
    Ok(hasher.finish())
}

/// Search missions with semantic-aware ranking.
#[derive(Debug, serde::Deserialize)]
pub struct ResolveMissionQuery {
    /// A full mission UUID or an unambiguous leading fragment of one.
    pub id: String,
}

/// Resolve the id humans actually have — the 8-character prefix dashboards,
/// logs and transcripts display — into a full mission UUID.
///
/// Ambiguity is reported as a conflict listing the candidates rather than
/// silently picking the newest: a controller acting on the wrong mission is
/// far worse than one that has to ask again with more characters.
pub async fn resolve_mission_id(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<ResolveMissionQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let raw = query.id.trim().to_ascii_lowercase();
    if let Ok(id) = Uuid::parse_str(&raw) {
        return Ok(Json(serde_json::json!({
            "mission_id": id.to_string(),
            "match": "exact",
        })));
    }
    // Anything shorter is not worth resolving: at 4 hex characters a
    // collision is already likely enough to be a nuisance, and a 1-character
    // "prefix" would scan half the fleet.
    if raw.len() < 4 || !raw.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return Err((
            StatusCode::BAD_REQUEST,
            "id must be a mission UUID or at least 4 hex characters of one".to_string(),
        ));
    }

    let control = control_for_user(&state, &user).await;
    // One more than we report, so "exactly one" is provably unambiguous.
    let candidates = control
        .mission_store
        .find_missions_by_id_prefix(&raw, 11)
        .await
        .map_err(internal_error)?;

    match candidates.len() {
        0 => Err((StatusCode::NOT_FOUND, format!("no mission matches '{raw}'"))),
        1 => Ok(Json(serde_json::json!({
            "mission_id": candidates[0].id.to_string(),
            "match": "prefix",
        }))),
        _ => {
            let listed: Vec<serde_json::Value> = candidates
                .iter()
                .take(10)
                .map(|m| {
                    serde_json::json!({
                        "id": m.id.to_string(),
                        "title": m.title,
                        "status": m.status.to_string(),
                        "updated_at": m.updated_at,
                    })
                })
                .collect();
            Err((
                StatusCode::CONFLICT,
                serde_json::json!({
                    "error": "ambiguous",
                    "prefix": raw,
                    "candidates": listed,
                })
                .to_string(),
            ))
        }
    }
}

pub async fn search_missions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(params): Query<SearchMissionsQuery>,
) -> Result<Json<Vec<MissionSearchResult>>, (StatusCode, String)> {
    let query = params.q.trim();
    if query.is_empty() {
        return Ok(Json(Vec::new()));
    }

    let limit = params.limit.unwrap_or(20).clamp(1, 100);
    let query_hash = mission_search_query_hash(query);
    let control = control_for_user(&state, &user).await;
    let recency_fingerprint = mission_search_recency_fingerprint(&control.mission_store)
        .await
        .map_err(internal_error)?;
    if let Some(cached_results) = {
        let cache = control.mission_search_cache.read().await;
        cache.get(&query_hash).and_then(|entry| {
            if mission_search_cache_hit_by_ttl(entry, recency_fingerprint) {
                Some(entry.results.clone())
            } else {
                None
            }
        })
    } {
        let mut results = cached_results;
        results.truncate(limit);
        return Ok(Json(results));
    }

    let page_size = (limit.saturating_mul(5)).clamp(50, 200);
    let mission_candidates = list_missions_for_search(&state, &control, query, limit).await?;
    let freshness_key = mission_search_freshness_key(&mission_candidates, page_size);

    if let Some(cached_results) = {
        let cache = control.mission_search_cache.read().await;
        cache.get(&query_hash).and_then(|entry| {
            if mission_search_cache_hit_by_freshness(entry, recency_fingerprint, freshness_key) {
                Some(entry.results.clone())
            } else {
                None
            }
        })
    } {
        let mut results = cached_results;
        results.truncate(limit);
        return Ok(Json(results));
    }

    let mut scored: Vec<MissionSearchResult> = mission_candidates
        .into_iter()
        .filter_map(|candidate| {
            if candidate.relevance_score > 0.0 {
                Some(MissionSearchResult {
                    mission: candidate.mission,
                    relevance_score: candidate.relevance_score,
                })
            } else {
                None
            }
        })
        .collect();

    scored.sort_by(|a, b| {
        b.relevance_score
            .total_cmp(&a.relevance_score)
            .then_with(|| b.mission.updated_at.cmp(&a.mission.updated_at))
    });
    {
        const MISSION_SEARCH_CACHE_MAX_ENTRIES: usize = 128;
        let mut cache = control.mission_search_cache.write().await;
        if cache.len() >= MISSION_SEARCH_CACHE_MAX_ENTRIES {
            if let Some(key_to_drop) = cache.keys().next().copied() {
                cache.remove(&key_to_drop);
            }
        }
        cache.insert(
            query_hash,
            MissionSearchCacheEntry {
                cached_at: std::time::Instant::now(),
                freshness_key,
                recency_fingerprint,
                results: scored.clone(),
            },
        );
    }

    scored.truncate(limit);
    Ok(Json(scored))
}

/// Search mission history and return the best matching moment per mission.
pub async fn search_mission_moments(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(params): Query<SearchMissionMomentsQuery>,
) -> Result<Json<Vec<MissionMomentSearchResult>>, (StatusCode, String)> {
    let query = params.q.trim();
    if query.is_empty() {
        return Ok(Json(Vec::new()));
    }

    let limit = params.limit.unwrap_or(10).clamp(1, 50);
    let control = control_for_user(&state, &user).await;

    let mut missions: Vec<Mission> = if let Some(mission_id) = params.mission_id {
        let Some(mission) = control
            .mission_store
            .get_mission(mission_id)
            .await
            .map_err(internal_error)?
        else {
            return Ok(Json(Vec::new()));
        };
        vec![mission]
    } else {
        const SEARCH_PAGE_SIZE: usize = 100;
        const SEARCH_MAX_SCAN: usize = 2_000;
        let mut all = Vec::new();
        let mut offset = 0usize;
        while offset < SEARCH_MAX_SCAN {
            let page = control
                .mission_store
                .list_missions(SEARCH_PAGE_SIZE, offset)
                .await
                .map_err(internal_error)?;
            if page.is_empty() {
                break;
            }
            let page_len = page.len();
            all.extend(page);
            if page_len < SEARCH_PAGE_SIZE {
                break;
            }
            offset += SEARCH_PAGE_SIZE;
        }
        if offset >= SEARCH_MAX_SCAN {
            tracing::warn!(
                "Mission moment search scan hit cap ({} missions); some older missions may not be searched",
                SEARCH_MAX_SCAN
            );
        }
        all
    };

    populate_workspace_names(&state, &mut missions).await;

    let mut results: Vec<MissionMomentSearchResult> = missions
        .into_iter()
        .filter_map(|mission| {
            let best = best_mission_moment(&mission, query)?;
            Some(MissionMomentSearchResult {
                mission,
                entry_index: best.entry_index,
                role: best.role,
                snippet: best.snippet,
                rationale: best.rationale,
                relevance_score: best.relevance_score,
            })
        })
        .collect();

    results.sort_by(|a, b| {
        b.relevance_score
            .total_cmp(&a.relevance_score)
            .then_with(|| b.mission.updated_at.cmp(&a.mission.updated_at))
            .then_with(|| a.entry_index.cmp(&b.entry_index))
    });
    results.truncate(limit);
    Ok(Json(results))
}
