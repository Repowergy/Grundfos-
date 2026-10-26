-- Website-Daten 08/2026 (Zentrale Projektablage: GRUNDFOS_Active_*_de_DE*.xlsx, GRUNDFOS_Pump_SparePart_Mapping…)
--
--  1. pim.artikel_webkategorie   Kategoriepfad der Grundfos-Website je Artikel (290.000 Artikel), z. B.
--                                „Zubehör > Elektrisches Zubehör > Elektro“ + Familien-/Serien-Slug
--  2. Service-Sonderausführungen  Pumpe → „service-special“-Artikel mit gleichem Typnamen (100.000 Paare,
--                                laut Datei 98,5 % geprüft) als artikel_beziehung typ 'alternative', Status 'kandidat'
-- Quelle 'website2026' (Priorität 40). Bild-/Kennlinien-Links der Grundfos-API bleiben nur in den Rohdaten
-- (kein Massenabruf von der Website).

insert into pim.quelle (typ, bezeichnung, datenstand, prioritaet)
select 'website2026', 'Grundfos-Website de_DE, Produktdaten 08/2026 (Projektablage)', date '2026-08-03', 40
 where not exists (select 1 from pim.quelle where typ = 'website2026');

create table if not exists pim.artikel_webkategorie (
  artikel_id   bigint primary key references pim.artikel(id) on delete cascade,
  pfad         text not null,                 -- „Pumpen > Umwälzpumpen > …“
  haupt        text,
  kategorie    text,
  unter        text,
  familie_slug text,
  serie_slug   text,
  quelle_id    bigint not null references pim.quelle(id)
);
create index if not exists artikel_webkategorie_pfad_idx on pim.artikel_webkategorie (pfad);
alter table pim.artikel_webkategorie enable row level security;

create or replace function pim.website_2026_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'website2026' order by id limit 1);
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  insert into pim.artikel_webkategorie (artikel_id, pfad, haupt, kategorie, unter, familie_slug, serie_slug, quelle_id)
  select distinct on (a.id) a.id, t.daten->>'category_path', nullif(t.daten->>'main_category', ''),
         nullif(t.daten->>'category', ''), nullif(t.daten->>'subcategory', ''),
         nullif(t.daten->>'family_slug', ''), nullif(t.daten->>'series_slug', ''), v_quelle
    from raw.tabellen_zeile t
    join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(replace(btrim(t.daten->>'product_number'), ' ', ''))
   where q.pfad like '%GRUNDFOS_Active%' and coalesce(t.daten->>'category_path', '') <> ''
   order by a.id, (q.pfad like '%MASTER%') desc
  on conflict (artikel_id) do update
    set pfad = excluded.pfad, haupt = excluded.haupt, kategorie = excluded.kategorie, unter = excluded.unter,
        familie_slug = excluded.familie_slug, serie_slug = excluded.serie_slug;
  get diagnostics n = row_count;
  schritt := 'Website-Kategorien je Artikel'; anzahl := n; return next;

  insert into pim.artikel_beziehung (von_artikel_id, zu_artikel_id, typ, status, nachweis, quelle_id)
  select distinct p.id, e.id, 'alternative', 'kandidat',
         'Website 2026: Service-Sonderausführung (' || coalesce(t.daten->>'spare_part_series', '') || ', '
           || coalesce(t.daten->>'certainty', '') || ')', v_quelle
    from raw.tabellen_zeile t
    join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel p on p.hersteller_id = 1 and p.artikelnummer_norm = upper(btrim(t.daten->>'pump_article_number'))
    join pim.artikel e on e.hersteller_id = 1 and e.artikelnummer_norm = upper(btrim(t.daten->>'spare_part_article_number'))
   where q.pfad like '%Pump_SparePart_Mapping%' and p.id <> e.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Service-Sonderausführungen (Kandidaten)'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.website_2026_uebernehmen() from public, anon, authenticated;
