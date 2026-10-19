-- A deleted source can never activate a transfer. Keep the receipt for audit,
-- but release its workspace fence in the same transaction as every deletion
-- path (including bulk/empty-chat cleanup). Bump the revision so an adapter
-- holding an older snapshot cannot restore the cancelled transfer.
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

-- Recover orphaned fences left by older builds. Never expire a transfer merely
-- because it is quiet or old: only absence of its source mission qualifies.
UPDATE machine_transfers
SET phase = 'cancelled',
    data = json_set(data, '$.phase', 'cancelled', '$.revision', revision + 1),
    revision = revision + 1
WHERE phase NOT IN ('activated', 'cancelled')
  AND NOT EXISTS (SELECT 1 FROM missions WHERE missions.id = machine_transfers.mission_id);
COMMIT;
