-- Fixture for SPPostgresCatalogTests. Idempotent. Statements are separated by lines starting with "-- @@";
-- the test runner executes one statement per chunk (extended protocol allows only one).
-- "-- @@ db <name>" switches the connection to database <name>; "-- @@ createdb <name>" creates it if missing
-- (CREATE DATABASE cannot run in a transaction/DO block, so the runner checks pg_database first).
-- @@ db pgkit_test
CREATE SCHEMA IF NOT EXISTS public
-- @@
CREATE SCHEMA IF NOT EXISTS "Sales Data"
-- @@
CREATE SCHEMA IF NOT EXISTS "a""b"
-- @@
CREATE TABLE IF NOT EXISTS public.customers (id integer PRIMARY KEY, name text)
-- @@
CREATE TABLE IF NOT EXISTS "Sales Data"."Orders 2026" (id integer PRIMARY KEY)
-- @@
CREATE TABLE IF NOT EXISTS "a""b"."x" (id integer PRIMARY KEY)
-- @@
CREATE OR REPLACE VIEW public.v_customers AS SELECT id, name FROM public.customers
-- @@
CREATE EXTENSION IF NOT EXISTS pg_trgm
-- @@ createdb pgkit_nopublic
-- @@ db pgkit_nopublic
CREATE SCHEMA IF NOT EXISTS app
-- @@
DROP SCHEMA IF EXISTS public CASCADE
-- @@
CREATE TABLE IF NOT EXISTS app.items (id integer PRIMARY KEY)
