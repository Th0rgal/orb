SELECT m.id, u.id, u.unix_username, j.job_id, j.node_id, g.account_id, g.model,
       m.authority_mode, m.run_generation, m.owner_epoch, m.placement_revision,
       v.country, v.generation, t.expires_at_epoch
FROM native_antigravity_grants AS g
JOIN mission_proxy_tokens AS t USING (token_sha256)
JOIN native_shared_workspace_bindings AS b USING (token_sha256)
JOIN remote_node_jobs AS j ON j.job_id = g.job_id AND j.mission_id = t.mission_id
JOIN missions AS m ON m.id = j.mission_id AND m.placement_job_id = j.job_id
JOIN users AS u ON u.id = t.owner_user_id AND u.id = m.owner_user_id
JOIN account_vpn_routes AS v ON v.account_id = g.account_id
LEFT JOIN user_provider_prefs AS f ON f.user_id = u.id AND f.provider_id = g.account_id
WHERE b.node_id = j.node_id AND b.route_generation = v.generation
  AND g.token_sha256 = ?1 AND j.job_id = ?2 AND j.node_id = ?3 AND u.id = ?4
  AND t.revoked = 0 AND t.expires_at_epoch > CAST(?5 AS INTEGER)
  AND j.state = 'running' AND m.status = 'active' AND m.backend = 'antigravity'
  AND m.authority_mode IN ('writer', 'readonly')
  AND u.disabled = 0 AND u.role IN ('member', 'admin') AND length(u.unix_username) > 0
  AND COALESCE(f.enabled, 1) = 1 AND v.generation > 0
  AND ((b.route_kind='vpn' AND v.country GLOB '[A-Z][A-Z]') OR (b.route_kind='direct' AND v.country=''));
