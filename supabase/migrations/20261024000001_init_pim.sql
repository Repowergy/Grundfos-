-- Grundfos-PIM: Grundschema
-- raw = Rohdaten 1:1 aus den Quelldateien (nie verändern, nur ergänzen)
-- pim = zusammengeführte Stammdaten mit Herkunft je Wert
-- Beide Schemas sind nicht über die öffentliche API erreichbar; Zugriff nur mit Service-Rolle.

create extension if not exists pg_trgm;  -- wird in 0002 nach "extensions" verschoben

create schema if not exists raw;
create schema if not exists pim;

-- ═════════════════════════════ RAW ═════════════════════════════

create table raw.import_lauf (
  id            bigint generated always as identity primary key,
  gestartet_am  timestamptz not null default now(),
  beendet_am    timestamptz,
  werkzeug      text not null,            -- z. B. 'datanorm_import v1'
  notiz         text
);

create table raw.quelldatei (
  id            bigint generated always as identity primary key,
  lauf_id       bigint references raw.import_lauf(id),
  pfad          text not null,            -- Pfad im Drive
  sha256        text not null unique,     -- gleiche Datei wird nur einmal importiert
  groesse       bigint,
  format        text not null,            -- datanorm4, datanorm5, csv, xlsx, mdb, mdf, gpc_txt, gpc_cache …
  lieferant     text,                     -- aus V-Satz / Ordner, z. B. 'GRUNDFOS GMBH'
  datenstand    date,
  sprache       text,                     -- falls dateiweit eindeutig (de, en …)
  kopfzeile     text,                     -- V-Satz o. ä.
  zeilen        bigint,
  importiert_am timestamptz not null default now()
);

-- jede DATANORM-Zeile unverändert
create table raw.datanorm_satz (
  id        bigint generated always as identity primary key,
  datei_id  bigint not null references raw.quelldatei(id) on delete cascade,
  zeile     integer not null,
  satzart   char(1) not null,
  felder    text[] not null,
  unique (datei_id, zeile)
);
create index on raw.datanorm_satz (datei_id, satzart);
create index on raw.datanorm_satz ((felder[3])) where satzart in ('A','B','D');

-- jede Zeile aus Tabellen (CSV, Excel, Access, SQL Server, GPC-Listen) als JSON
create table raw.tabellen_zeile (
  id        bigint generated always as identity primary key,
  datei_id  bigint not null references raw.quelldatei(id) on delete cascade,
  tabelle   text not null,
  zeile     integer not null,
  daten     jsonb not null,
  unique (datei_id, tabelle, zeile)
);
create index on raw.tabellen_zeile (datei_id, tabelle);

-- ═════════════════════════════ PIM ═════════════════════════════

create table pim.quelle (
  id          bigint generated always as identity primary key,
  datei_id    bigint references raw.quelldatei(id),
  typ         text not null,              -- hersteller_datanorm, grosshandel_datanorm, gpc, artikelliste, oxomi, manuell …
  bezeichnung text not null,
  datenstand  date,
  prioritaet  smallint not null default 50 -- höher = vertrauenswürdiger (Hersteller > Großhandel > Altbestand)
);

create table pim.hersteller (
  id    smallint generated always as identity primary key,
  name  text not null unique
);
insert into pim.hersteller (name) values ('Grundfos');

create table pim.kategorie (
  id         bigint generated always as identity primary key,
  parent_id  bigint references pim.kategorie(id),
  code       text not null unique,        -- z. B. 'cr-cre-cri-crie-crn-crne-crt-crte/cr'
  ebene      text,                        -- familie, serie …
  pfad       text,
  quelle_id  bigint references pim.quelle(id)
);

create table pim.artikel (
  id                 bigint generated always as identity primary key,
  hersteller_id      smallint not null references pim.hersteller(id),
  artikelnummer      text not null,       -- wie in der Quelle (führende Nullen bleiben)
  artikelnummer_norm text not null,       -- Großbuchstaben, ohne Leerzeichen
  ean                text,
  familie            text,
  serie              text,
  kategorie_id       bigint references pim.kategorie(id),
  status             text not null default 'unbekannt'
                     check (status in ('aktiv','auslaufend','ersetzt','historisch','unbekannt')),
  hersteller_url     text,
  angelegt_am        timestamptz not null default now(),
  aktualisiert_am    timestamptz not null default now(),
  unique (hersteller_id, artikelnummer_norm)
);
create index on pim.artikel (ean);
create index on pim.artikel using gin (artikelnummer_norm gin_trgm_ops);

-- Kennung aus anderen Systemen (Großhändler-Nr., alte Nummern, VVS-Nr. …)
create table pim.artikel_alias (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  typ        text not null,               -- grosshandel, alt, vvs, matchcode …
  wert       text not null,
  quelle_id  bigint references pim.quelle(id),
  primary key (artikel_id, typ, wert)
);
create index on pim.artikel_alias (wert);

create table pim.artikel_text (
  id         bigint generated always as identity primary key,
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  sprache    text not null,               -- ISO 639-1: de, en, fr … (Markt separat)
  art        text not null check (art in ('kurz1','kurz2','titel','lang','technik','ausschreibung','seo_titel','seo_beschreibung')),
  text       text not null,
  quelle_id  bigint not null references pim.quelle(id),
  unique (artikel_id, sprache, art, quelle_id)
);
create index on pim.artikel_text using gin (to_tsvector('german', text)) where sprache = 'de';

-- Langtext-/Textbausteine je Baureihe (DATANORM T/E, GPC CTF)
create table pim.textbaustein (
  quelle_id  bigint not null references pim.quelle(id),
  schluessel text not null,
  sprache    text not null,
  zeile      integer not null,
  text       text not null,
  primary key (quelle_id, schluessel, sprache, zeile)
);

create table pim.artikel_preis (
  id            bigint generated always as identity primary key,
  artikel_id    bigint not null references pim.artikel(id) on delete cascade,
  markt         text not null default 'DE',  -- DE, AT, CH
  preisart      text not null check (preisart in ('listenpreis','uvp','ek','vk')),
  betrag        numeric(12,2) not null,
  waehrung      char(3) not null default 'EUR',
  preiseinheit  integer not null default 1,   -- Preis gilt für n Stück
  mengeneinheit text,
  rabattgruppe  text,
  gueltig_ab    date,
  gueltig_bis   date,
  quelle_id     bigint not null references pim.quelle(id)
);
create index on pim.artikel_preis (artikel_id, markt, preisart);

create table pim.merkmal (
  code        text primary key,           -- z. B. leistung_kw, spannung_v, anschluss_dn
  bezeichnung text not null,
  einheit     text
);

create table pim.artikel_merkmal (
  artikel_id   bigint not null references pim.artikel(id) on delete cascade,
  merkmal_code text not null references pim.merkmal(code),
  wert         text not null,
  wert_num     numeric,
  sprache      text not null default '-', -- '-' = sprachneutral
  quelle_id    bigint not null references pim.quelle(id),
  primary key (artikel_id, merkmal_code, sprache, quelle_id)
);

create table pim.artikel_markt (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  markt      text not null,               -- DE, AT, CH …
  status     text,
  quelle_id  bigint not null references pim.quelle(id),
  primary key (artikel_id, markt, quelle_id)
);

create table pim.warengruppe (
  hersteller_id smallint not null references pim.hersteller(id),
  code          text not null,
  hauptgruppe   text,
  bezeichnung   text,
  quelle_id     bigint references pim.quelle(id),
  primary key (hersteller_id, code)
);

create table pim.rabattgruppe (
  hersteller_id smallint not null references pim.hersteller(id),
  code          text not null,
  bezeichnung   text,
  quelle_id     bigint references pim.quelle(id),
  primary key (hersteller_id, code)
);

create table pim.medium (
  id             bigint generated always as identity primary key,
  typ            text not null check (typ in ('bild','datenblatt','anleitung','service','massbild','schaltbild','explosionszeichnung','kennlinie','cad','video','sonstiges')),
  dateiname      text not null,
  dokumentnummer text,
  sprache        text,
  storage_pfad   text,                    -- Pfad in Supabase Storage (wenn hochgeladen)
  extern_url     text,                    -- oder Link beim Hersteller
  sha256         text unique,
  lizenz         text not null default 'ungeklaert' check (lizenz in ('ungeklaert','freigegeben','nur_intern')),
  quelle_id      bigint references pim.quelle(id)
);

create table pim.artikel_medium (
  artikel_id  bigint not null references pim.artikel(id) on delete cascade,
  medium_id   bigint not null references pim.medium(id) on delete cascade,
  rolle       text not null default 'standard', -- hauptbild, galerie, datenblatt …
  sortierung  smallint not null default 0,
  quelle_id   bigint references pim.quelle(id),
  primary key (artikel_id, medium_id, rolle)
);

create table pim.artikel_beziehung (
  id               bigint generated always as identity primary key,
  von_artikel_id   bigint not null references pim.artikel(id) on delete cascade,
  zu_artikel_id    bigint not null references pim.artikel(id) on delete cascade,
  typ              text not null check (typ in ('ersatzteil','reparatursatz','zubehoer','nachfolger','alternative','verpackungseinheit','variante','bestandteil')),
  menge            numeric,
  position         text,                  -- Positionsnummer in der Zeichnung
  produktion_von   date,                  -- gültig für Pumpen produziert ab …
  produktion_bis   date,
  status           text not null default 'kandidat' check (status in ('kandidat','geprueft','abgelehnt')),
  nachweis         text,
  quelle_id        bigint not null references pim.quelle(id),
  unique nulls not distinct (von_artikel_id, zu_artikel_id, typ, position, produktion_von, quelle_id)
);
create index on pim.artikel_beziehung (zu_artikel_id, typ);

create table pim.zeichnung_position (
  medium_id   bigint not null references pim.medium(id) on delete cascade,
  position    text not null,
  x1 real, y1 real, x2 real, y2 real,     -- Hotspot relativ (0..1)
  artikel_id  bigint references pim.artikel(id),
  quelle_id   bigint references pim.quelle(id),
  primary key (medium_id, position)
);

-- ═══════════════════ Sicherheit: kein öffentlicher Zugriff ═══════════════════
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname in ('raw','pim') loop
    execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
  end loop;
end $$;
revoke all on schema raw, pim from anon, authenticated;
