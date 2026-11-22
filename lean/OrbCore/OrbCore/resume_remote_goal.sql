UPDATE missions
SET status = 'awaiting_user', terminal_reason = 'remote_goal_continuation',
    state_revision = state_revision + 1, updated_at = ?3
WHERE id = ?1 AND run_generation = CAST(?2 AS INTEGER) AND goal_mode = 1
  AND length(trim(goal_objective)) > 0
  AND (
    (status = 'interrupted' AND terminal_reason = 'remote_goal_stopped') OR
    (status = 'awaiting_user' AND terminal_reason = 'remote_goal_blocked') OR
    (status = 'failed' AND terminal_reason = 'remote_job_failed' AND EXISTS (
      SELECT 1 FROM remote_node_jobs AS j
      JOIN mission_runs AS r ON r.mission_id = j.mission_id AND r.remote_job_id = j.job_id
      WHERE j.mission_id = missions.id AND j.job_id = missions.placement_job_id
        AND r.generation = missions.run_generation AND r.execution_state = 'terminal'
        AND j.state = 'failed' AND json_type(j.payload_json, '$.goal_claim') = 'text'
        AND json_type(j.payload_json, '$.goal_generation') = 'integer'
        AND json_extract(j.payload_json, '$.goal_generation') BETWEEN 1 AND r.generation
    ))
  )
  AND NOT EXISTS (SELECT 1 FROM mission_continuations WHERE mission_id = ?1 AND phase IN (1, 2))
  AND NOT EXISTS (
    SELECT 1 FROM remote_node_jobs WHERE mission_id = ?1
      AND state NOT IN ('succeeded', 'failed', 'cancelled', 'lost', 'terminal', 'completed', 'aborted')
  )
RETURNING goal_objective, backend, session_id;
