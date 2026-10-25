-- GPC-Software 09/2023: Rohzeilen (gpc2023.zeile) in auswertbare Tabellen zerlegen.
-- Die Rohdaten bleiben unverändert; die Tabellen hier sind nur aufbereitet und jederzeit neu erzeugbar.
-- Die beiden Caches (je eine JSON-Zeile, bis 75 MB) werden NICHT in der Datenbank zerlegt – jsonb in dieser
-- Größe hat den Server per Speichermangel neu starten lassen. Sie lädt tools/import/gpc2023_caches.py stückweise.
--
--  gpc2023.sortiment        Control/ProductRange/ProductRange_<kürzel>.txt  (Artikelnr;Preis;Fasttrack;Status;)
--  gpc2023.vvs              VVSNo.cache  (Produktliste mit EAN, VVS-Nr., Typ, Kennlinie; DB-Stand 16.09.2019)
--  gpc2023.schnellaustausch QuickReplacement.cache  (Wettbewerberpumpen mit Eckdaten für den Schnellaustausch)

create table if not exists gpc2023.sortiment (
  kuerzel    text not null,      -- z. B. 'gws' (Deutschland)
  productno  text not null,
  norm       text not null,      -- Großbuchstaben ohne Leerzeichen (= pim.artikel.artikelnummer_norm)
  preis      text,
  fasttrack  text,
  status     text
);
create table if not exists gpc2023.vvs (nr integer, daten jsonb);
create table if not exists gpc2023.schnellaustausch (cache_id integer primary key, daten jsonb);
alter table gpc2023.sortiment enable row level security;
alter table gpc2023.vvs enable row level security;
alter table gpc2023.schnellaustausch enable row level security;

create or replace function gpc2023.aufbereiten()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = gpc2023, public
as $body$
declare n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  truncate gpc2023.sortiment;
  insert into gpc2023.sortiment (kuerzel, productno, norm, preis, fasttrack, status)
  select lower(substring(d.name from '^ProductRange_(.*)\.txt$')),
         trim(split_part(z.text, ';', 1)),
         upper(replace(trim(split_part(z.text, ';', 1)), ' ', '')),
         nullif(trim(split_part(z.text, ';', 2)), ''),
         nullif(trim(split_part(z.text, ';', 3)), ''),
         nullif(trim(split_part(z.text, ';', 4)), '')
    from gpc2023.datei d
    join gpc2023.zeile z on z.datei_id = d.id
   where d.pfad like 'datafile/Control/ProductRange/ProductRange\_%.txt'
     and z.text like '%;%' and trim(split_part(z.text, ';', 1)) <> '';
  get diagnostics n = row_count;
  schritt := 'Sortimentszeilen'; anzahl := n; return next;
  create index if not exists sortiment_norm_idx on gpc2023.sortiment (norm);

end;
$body$;
revoke execute on function gpc2023.aufbereiten() from public, anon, authenticated;
