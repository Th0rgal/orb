BEGIN IMMEDIATE;
CREATE TRIGGER IF NOT EXISTS cancel_machine_transfers_after_mission_delete
AFTER DELETE ON missions
BEGIN
    UPDATE machine_transfers
    SET phase = 'cancelled',
        data = json_set(data, '$.phase', 'cancelled', '$.revision', revision + 1),
        revision = revision + 1
    WHERE mission_id = OLD.id AND phase NOT IN ('activated', 'cancelled');
END;
UPDATE machine_transfers
SET phase = 'cancelled',
    data = json_set(data, '$.phase', 'cancelled', '$.revision', revision + 1),
    revision = revision + 1
WHERE phase NOT IN ('activated', 'cancelled')
  AND NOT EXISTS (SELECT 1 FROM missions WHERE missions.id = machine_transfers.mission_id);
COMMIT;
