-- ============================================================
-- Matrix Synapse — PostgreSQL Initialization
-- ============================================================
-- This script is executed once when the PostgreSQL container
-- first initializes (i.e., when postgres-data volume is empty).
--
-- The database and user are already created by the
-- POSTGRES_DB, POSTGRES_USER, and POSTGRES_PASSWORD environment
-- variables set in compose.yaml.
--
-- Synapse creates its own schema and runs all migrations on
-- first startup — there is no need to create tables here.
--
-- The POSTGRES_INITDB_ARGS in compose.yaml ensure the database
-- is created with:
--   encoding: UTF-8
--   lc_collate: C
--   lc_ctype: C
--
-- These are REQUIRED by Synapse. If the database is created
-- with any other locale, Synapse will refuse to start.
-- ============================================================

-- Verify database encoding and locale settings
DO $$
DECLARE
    db_encoding text;
    db_collate  text;
    db_ctype    text;
BEGIN
    SELECT
        pg_encoding_to_char(encoding),
        datcollate,
        datctype
    INTO
        db_encoding,
        db_collate,
        db_ctype
    FROM
        pg_database
    WHERE
        datname = current_database();

    RAISE NOTICE 'Database: %', current_database();
    RAISE NOTICE 'Encoding: %', db_encoding;
    RAISE NOTICE 'LC_COLLATE: %', db_collate;
    RAISE NOTICE 'LC_CTYPE: %', db_ctype;

    IF db_encoding != 'UTF8' THEN
        RAISE WARNING 'Database encoding is %, expected UTF8. Synapse may not work correctly.', db_encoding;
    END IF;

    IF db_collate != 'C' THEN
        RAISE WARNING 'LC_COLLATE is %, expected C. Synapse may not work correctly.', db_collate;
    END IF;

    IF db_ctype != 'C' THEN
        RAISE WARNING 'LC_CTYPE is %, expected C. Synapse may not work correctly.', db_ctype;
    END IF;
END $$;

-- Grant schema privileges to the synapse user
-- (redundant since POSTGRES_USER created the DB, but explicit is good)
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;
GRANT ALL ON SCHEMA public TO synapse;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO synapse;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO synapse;
