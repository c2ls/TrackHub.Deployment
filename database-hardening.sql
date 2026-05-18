-- TrackHub Production Hardening - Database Schema Changes
-- Generated: 2026-04-01
-- Apply these scripts to the production database BEFORE deploying the updated application.
-- All scripts are idempotent (safe to re-run).

-- =============================================================================
-- 1. Manager schema (app) - Unique index on users (accountid, username)
-- Ensures no duplicate usernames within the same account.
-- WARNING: If duplicate (accountid, username) pairs exist, this will fail.
--          Run the verification query first.
-- =============================================================================

-- Verification: Check for existing duplicates before creating unique index
-- SELECT accountid, username, COUNT(*) 
-- FROM app.users 
-- GROUP BY accountid, username 
-- HAVING COUNT(*) > 1;

CREATE UNIQUE INDEX IF NOT EXISTS ix_users_accountid_username
    ON app.users (accountid, username);

-- =============================================================================
-- 2. Geofencing schema - Index on geofences.accountid
-- Speeds up queries that filter geofences by account.
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_geofences_accountid
    ON geofencing.geofences (accountid);
