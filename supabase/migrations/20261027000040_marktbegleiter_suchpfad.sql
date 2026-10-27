-- Sicherheitsprüfung (Supabase Advisor): feste search_path für die Hilfsfunktionen im Schema marktbegleiter
alter function marktbegleiter.nr_norm(text) set search_path = pg_catalog;
alter function marktbegleiter.domain_norm(text) set search_path = pg_catalog;
alter function marktbegleiter.gtin_norm(text) set search_path = pg_catalog;
alter function marktbegleiter.hersteller_norm(text) set search_path = pg_catalog;
alter function marktbegleiter.preise_unveraenderlich() set search_path = pg_catalog;
