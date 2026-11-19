-- One statement: mission metadata and current turn text share a SQLite snapshot.
-- Never return a user row's content, auxiliary JSON, file path, or mission history.
WITH latest AS (
  SELECT id FROM mission_events
  WHERE mission_id = ?1
    AND event_type IN ('user_message','text_delta','assistant_message','assistant_message_canonical')
    AND CASE WHEN event_type != 'user_message' THEN 1 ELSE COALESCE(
      CASE WHEN json_valid(payload) THEN COALESCE(json_type(payload,'$.metadata.queued'), json_type(payload,'$.queued')) END,
      CASE WHEN json_valid(metadata) THEN json_type(metadata,'$.queued') END, 'false') != 'true' END
  ORDER BY (CASE WHEN seq > 0 THEN seq ELSE COALESCE(sequence,0) END) DESC, id DESC LIMIT 1
)
SELECT substr(m.title,1,512), substr(m.status,1,128),
  CASE WHEN e.event_type IS NULL OR e.event_type = 'user_message' THEN '' ELSE substr(COALESCE(
    CASE WHEN json_valid(e.payload) THEN CASE
      WHEN json_type(e.payload,'$.content') = 'text' THEN json_extract(e.payload,'$.content')
      WHEN json_type(e.payload,'$.message') = 'text' THEN json_extract(e.payload,'$.message') END END,
    e.content,''),1,65537) END
FROM missions m LEFT JOIN mission_events e ON e.id = CASE WHEN ?4 = '1' THEN NULL ELSE (SELECT id FROM latest) END
WHERE m.id = ?1 AND (?2 = '1' OR m.owner_user_id = ?3 OR EXISTS
  (SELECT 1 FROM mission_shares s WHERE s.mission_id = m.id AND s.user_id = ?3));
