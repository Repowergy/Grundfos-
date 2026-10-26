-- Bildquellen 2026 (Projektablage „Bildzuordnungen und Bildquellen (Shopify 2026)“, hochgeladen 26.10.2026, Import 7)
--
--  Bilder:     jede Bilddatei aus diesem Ordner (raw.quelldatei format 'bild', auch in ZIP/RAR) → pim.medium typ 'bild'
--              (quell_schluessel 'bild2026:<dateiname>'; gleicher Name in mehreren Unterordnern → eine Datei)
--  Zuordnung:  1. artikelbildzuordnungen_web_b.csv (Werksartikelnummer → Dokument, Sortierung, Stellvertreter)
--              2. Dateiname enthält die Artikelnummer: gfb_w-96553046.jpg → 96553046
--  Upload:     pim.medium_datei (basis '' = MyDrive, Ziel bild2026/<name>) → tools/import/medien_upload.py
-- Wiederholbar: neue Dateien/Zuordnungen kommen dazu, Bestehendes bleibt.

insert into pim.quelle (typ, bezeichnung, datenstand, prioritaet)
select 'bildquellen2026', 'Projektablage: Bildzuordnungen und Bildquellen (Shopify 2026)', date '2026-10-26', 45
 where not exists (select 1 from pim.quelle where typ = 'bildquellen2026');

create or replace function pim.bildquellen_2026_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'bildquellen2026' order by id limit 1);
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  create temp table _b on commit drop as
  select distinct on (lower(regexp_replace(q.pfad, '^.*/', '')))
         lower(regexp_replace(q.pfad, '^.*/', '')) as name, q.pfad, q.groesse
    from raw.quelldatei q
   where q.format = 'bild' and q.pfad like '%Bildzuordnungen und Bildquellen (Shopify 2026)/%'
   order by lower(regexp_replace(q.pfad, '^.*/', '')), q.groesse desc;

  insert into pim.medium (typ, dateiname, titel, kategorie, quell_schluessel, quelle_id)
  select 'bild', b.name, null, 'Bildquellen 2026', 'bild2026:' || b.name, v_quelle
    from _b b
  on conflict (quell_schluessel) do nothing;
  get diagnostics n = row_count;
  schritt := 'Bilder'; anzahl := n; return next;

  insert into pim.medium_datei (medium_id, basis, container, pfad, ext, groesse, ziel_pfad)
  select m.id, '',
         case when b.pfad like '%!/%' then split_part(b.pfad, '!/', 1) end,
         case when b.pfad like '%!/%' then substring(b.pfad from position('!/' in b.pfad) + 2) else b.pfad end,
         lower(substring(b.name from '(\.[^.]+)$')), b.groesse,
         'bild2026/' || regexp_replace(b.name, '[^a-z0-9._-]+', '_', 'g')
    from _b b join pim.medium m on m.quell_schluessel = 'bild2026:' || b.name
  on conflict (medium_id) do nothing;
  get diagnostics n = row_count;
  schritt := 'Upload-Liste'; anzahl := n; return next;

  -- 1. Zuordnungsliste
  insert into pim.artikel_medium (artikel_id, medium_id, rolle, sortierung, quelle_id)
  select distinct on (a.id, m.id) a.id, m.id,
         case when t.daten ->> 'Stellvertreterkennzeichen' = 'true' then 'stellvertreterbild' else 'galerie' end,
         coalesce(nullif(t.daten ->> 'Dokument_Sortierreihenfolge', '')::smallint, 0), v_quelle
    from raw.tabellen_zeile t
    join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(replace(btrim(t.daten ->> 'Werksartikelnummer'), ' ', ''))
    join pim.medium m on m.quell_schluessel = 'bild2026:' || lower(btrim(t.daten ->> 'Dokument'))
   where q.pfad like '%Bildzuordnungen und Bildquellen (Shopify 2026)/%' and t.daten ? 'Werksartikelnummer'
     and t.daten ? 'Dokument'
   order by a.id, m.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Zuordnung aus Liste'; anzahl := n; return next;

  -- 2. Artikelnummer im Dateinamen (gfb_w-96553046.jpg, gfb_d96076196.jpg; mind. 7 Zeichen, damit laufende
  --    Bildnummern wie gfb_d00110 nicht als Artikelnummer gelten)
  insert into pim.artikel_medium (artikel_id, medium_id, rolle, sortierung, quelle_id)
  select a.id, m.id, 'galerie', 5, v_quelle
    from pim.medium m
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(substring(m.dateiname from '^gf[a-z]_[a-z]-?([0-9a-z]{7,})\.'))
   where m.quelle_id = v_quelle
     and not exists (select 1 from pim.artikel_medium x where x.medium_id = m.id and x.artikel_id = a.id)
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Zuordnung über Dateinamen'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.bildquellen_2026_uebernehmen() from public, anon, authenticated;
