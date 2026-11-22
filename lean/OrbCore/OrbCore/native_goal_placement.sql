SELECT 1
FROM missions AS m
JOIN remote_node_jobs AS j ON j.job_id = m.placement_job_id AND j.mission_id = m.id
JOIN mission_runs AS r ON r.mission_id = m.id AND r.remote_job_id = j.job_id
                      AND r.generation = m.run_generation
WHERE m.id = ?1 AND j.job_id = ?2 AND m.owner_user_id = ?3
  AND m.run_generation = CAST(?4 AS INTEGER)
  AND m.goal_mode = 1 AND m.status = 'active'
  AND j.state = 'running' AND r.execution_state = 'running'
  AND json_type(j.payload_json, '$.goal_claim') = 'text'
  AND json_type(j.payload_json, '$.goal_generation') = 'integer'
  AND json_extract(j.payload_json, '$.goal_generation') BETWEEN 1 AND r.generation;
