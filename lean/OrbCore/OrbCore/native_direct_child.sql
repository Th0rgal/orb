-- Parameters come from the verified parent placement, except the requested child UUID.
SELECT child.status, substr(child.model_override, 1, 256),
       CASE WHEN child.status IN ('awaiting_user', 'completed', 'done', 'succeeded') THEN
         (SELECT CASE WHEN ev.event_type = 'assistant_message' AND json_valid(ev.payload)
                           AND json_type(ev.payload, '$.content') = 'text'
                      THEN substr(json_extract(ev.payload, '$.content'), 1, 2049) END
            FROM mission_events ev
           WHERE ev.mission_id = child.id
             AND ev.event_type IN ('user_message', 'assistant_message')
           ORDER BY CASE WHEN ev.seq > 0 THEN ev.seq ELSE ev.sequence END DESC, ev.id DESC LIMIT 1)
       END
  FROM missions child
  JOIN missions parent ON parent.id = child.parent_mission_id
 WHERE parent.id = ?1 AND parent.owner_user_id = ?2 AND child.owner_user_id = ?2
   AND child.id = ?3 AND child.id <> parent.id;
