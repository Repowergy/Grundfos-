-- pim.medium.sha256 war eindeutig. Beim Hochladen zeigte sich: dieselbe Datei (gleicher Inhalt) gehört oft zu
-- mehreren Medien (z. B. dasselbe Bild unter zwei Namen oder in zwei Quellen). Die Prüfsumme bleibt als normaler
-- Index erhalten – zum Finden von Dubletten –, ist aber kein Ausschlusskriterium mehr.
alter table pim.medium drop constraint if exists medium_sha256_key;
create index if not exists medium_sha256_idx on pim.medium (sha256);
