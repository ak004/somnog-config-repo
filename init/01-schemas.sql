-- Runs once, the first time the postgres volume is initialised. Prisma creates
-- these itself when it migrates, but having them up front means anything that
-- connects before the migrate job finishes sees the intended layout instead of
-- an empty database.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS events;
CREATE SCHEMA IF NOT EXISTS notify;
