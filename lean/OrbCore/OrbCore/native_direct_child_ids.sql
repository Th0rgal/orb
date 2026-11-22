SELECT child.id
FROM missions parent JOIN missions child ON child.parent_mission_id = parent.id
WHERE parent.id = ?1 AND parent.owner_user_id = ?2 AND child.owner_user_id = ?2
  AND child.id <> parent.id
ORDER BY child.created_at DESC, child.id
LIMIT 17;
