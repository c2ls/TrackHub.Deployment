-- TrackHub Structural Domain Fixes - Database Schema Changes
-- Purpose: Add AccountId to transporters and devices tables for direct tenant isolation.
-- Apply BEFORE deploying the updated application.
-- All scripts are idempotent (safe to re-run).

-- =============================================================================
-- 1. Add accountid column to transporters table
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'transporters' AND column_name = 'accountid'
    ) THEN
        ALTER TABLE app.transporters ADD COLUMN accountid UUID;
    END IF;
END $$;

-- =============================================================================
-- 2. Backfill transporters.accountid from existing relationships
--    Primary path: Device -> Operator -> Account
--    Fallback path: TransporterGroup -> Group -> Account
-- =============================================================================

-- Path 1: Via Devices -> Operators -> Accounts
UPDATE app.transporters t
SET accountid = sub.accountid
FROM (
    SELECT DISTINCT ON (d.transporterid)
        d.transporterid,
        o.accountid
    FROM app.devices d
    JOIN app.operators o ON d.operatorid = o.id
    WHERE d.transporterid IS NOT NULL
    ORDER BY d.transporterid
) sub
WHERE t.id = sub.transporterid
  AND t.accountid IS NULL;

-- Path 2: Via TransporterGroups -> Groups -> Accounts
UPDATE app.transporters t
SET accountid = sub.accountid
FROM (
    SELECT DISTINCT ON (tg.transporterid)
        tg.transporterid,
        g.accountid
    FROM app.transporter_group tg
    JOIN app.groups g ON tg.groupid = g.id
    ORDER BY tg.transporterid
) sub
WHERE t.id = sub.transporterid
  AND t.accountid IS NULL;

-- =============================================================================
-- 3. Verify: Check for transporters with NULL accountid (orphaned)
--    If any rows are returned, they need manual assignment or deletion.
-- =============================================================================

-- Uncomment to check:
-- SELECT id, name FROM app.transporters WHERE accountid IS NULL;

-- To delete orphaned transporters (use with caution):
-- DELETE FROM app.transporters WHERE accountid IS NULL;

-- =============================================================================
-- 4. Set NOT NULL constraint on transporters.accountid
--    WARNING: This will fail if any rows still have NULL accountid.
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'transporters'
          AND column_name = 'accountid' AND is_nullable = 'YES'
    ) THEN
        ALTER TABLE app.transporters ALTER COLUMN accountid SET NOT NULL;
    END IF;
END $$;

-- =============================================================================
-- 5. Add foreign key constraint from transporters to accounts
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_transporters_accountid'
          AND table_schema = 'app' AND table_name = 'transporters'
    ) THEN
        ALTER TABLE app.transporters
            ADD CONSTRAINT fk_transporters_accountid
            FOREIGN KEY (accountid) REFERENCES app.accounts(id);
    END IF;
END $$;

-- =============================================================================
-- 6. Add index on transporters.accountid
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_transporters_accountid
    ON app.transporters (accountid);

-- =============================================================================
-- 7. Add accountid column to devices table
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'devices' AND column_name = 'accountid'
    ) THEN
        ALTER TABLE app.devices ADD COLUMN accountid UUID;
    END IF;
END $$;

-- =============================================================================
-- 8. Backfill devices.accountid from Operator -> Account
-- =============================================================================

UPDATE app.devices d
SET accountid = o.accountid
FROM app.operators o
WHERE d.operatorid = o.id
  AND d.accountid IS NULL;

-- =============================================================================
-- 9. Set NOT NULL constraint on devices.accountid
--    WARNING: This will fail if any rows still have NULL accountid.
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'devices'
          AND column_name = 'accountid' AND is_nullable = 'YES'
    ) THEN
        ALTER TABLE app.devices ALTER COLUMN accountid SET NOT NULL;
    END IF;
END $$;

-- =============================================================================
-- 10. Add foreign key constraint from devices to accounts
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_devices_accountid'
          AND table_schema = 'app' AND table_name = 'devices'
    ) THEN
        ALTER TABLE app.devices
            ADD CONSTRAINT fk_devices_accountid
            FOREIGN KEY (accountid) REFERENCES app.accounts(id);
    END IF;
END $$;

-- =============================================================================
-- 11. Add index on devices.accountid
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_devices_accountid
    ON app.devices (accountid);
