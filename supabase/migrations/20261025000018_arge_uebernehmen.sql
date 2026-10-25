-- Grundfos-Stammdaten 2015 (ARGE-Format, Import 4 → raw.tabellen_zeile) in den Stamm pim übernehmen.
--
--  artikel.csv                    → EAN/Link ergänzen, Kurztexte, Nachfolger 1–3, Alternativartikel, Auslauf (Markt DE)
--  langtexte.csv                  → Langtext je Artikel (über Langtextnummer)
--  artikelmasse.csv               → Merkmale ARGE_<Maßangabe> (Gewicht, Länge, Breite, Höhe, Volumen) mit Einheit
--  artikelattribute.csv           → Merkmale ARGE_<Attributname>
--  artikeldokumentenzuordnungen   → Medien (Bilder Web/Druck/Vektor) mit Reihenfolge und Stellvertreter-Kennzeichen
-- Quelle 'arge' (Priorität 72). Mehrfaches Ausführen ist unschädlich.

create or replace function pim.arge_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $body$
declare
  v_quelle bigint;
  v_datei bigint;
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  select q.id into v_datei from raw.quelldatei q
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%artikel.csv' order by q.id desc limit 1;
  if v_datei is null then
    raise exception 'artikel.csv aus GF_CSV_GESAMT_MP.zip fehlt – zuerst Import 4 (Stammdaten 2015) ausführen';
  end if;
  select id into v_quelle from pim.quelle where typ = 'arge' and datei_id = v_datei;
  if v_quelle is null then
    insert into pim.quelle (datei_id, typ, bezeichnung, datenstand, prioritaet)
    values (v_datei, 'arge', 'Grundfos Stammdaten 2015 (ARGE, Preisliste 2015 Update 2)', date '2015-10-01', 72)
    returning id into v_quelle;
  end if;

  create temp table _art on commit drop as
  select t.daten, upper(replace(trim(t.daten ->> 'Werksartikelnummer'), ' ', '')) as norm
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikel.csv'
     and coalesce(t.daten ->> 'Werksartikelnummer', '') <> '';

  insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, ean, status, hersteller_url)
  select distinct on (norm) 1, trim(daten ->> 'Werksartikelnummer'), norm,
         case when daten ->> 'GTIN' ~ '^57\d{11}$' then daten ->> 'GTIN' end, 'unbekannt', nullif(daten ->> 'URL', '')
    from _art order by norm
  on conflict (hersteller_id, artikelnummer_norm) do nothing;
  get diagnostics n = row_count;
  schritt := 'Artikel neu'; anzahl := n; return next;

  update pim.artikel a
     set ean = coalesce(a.ean, case when x.daten ->> 'GTIN' ~ '^57\d{11}$' then x.daten ->> 'GTIN' end),
         hersteller_url = coalesce(a.hersteller_url, nullif(x.daten ->> 'URL', '')),
         aktualisiert_am = now()
    from _art x
   where a.hersteller_id = 1 and a.artikelnummer_norm = x.norm
     and ((a.ean is null and x.daten ->> 'GTIN' ~ '^57\d{11}$') or (a.hersteller_url is null and coalesce(x.daten ->> 'URL', '') <> ''));
  get diagnostics n = row_count;
  schritt := 'EAN/Link ergänzt'; anzahl := n; return next;

  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select a.id, 'de', k.art, k.txt, v_quelle
    from _art x
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = x.norm
    cross join lateral (values ('kurz1', nullif(trim(x.daten ->> 'Kurztext_1'), '')),
                               ('kurz2', nullif(trim(x.daten ->> 'Kurztext_2'), ''))) k(art, txt)
   where k.txt is not null
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Kurztexte'; anzahl := n; return next;

  -- Langtexte: Zeilen je Langtextnummer zusammenfügen
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select a.id, 'de', 'lang', pim.silben_zusammenfuegen(lt.text), v_quelle
    from _art x
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = x.norm
    join (select t.daten ->> 'Langtextnummer' as nr,
                 string_agg(t.daten ->> 'Langtextzeile', ' ' order by (t.daten ->> 'Langtextzeilennummer')::int) as text
            from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
           where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'langtexte.csv'
           group by 1) lt on lt.nr = x.daten ->> 'Langtextnummer'
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Langtexte'; anzahl := n; return next;

  -- Nachfolger 1–3 und Alternativartikel (fehlende Zielnummern zuerst als Artikel anlegen)
  insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, status)
  select distinct on (upper(replace(trim(x.daten ->> f), ' ', '')))
         1, trim(x.daten ->> f), upper(replace(trim(x.daten ->> f), ' ', '')), 'unbekannt'
    from _art x
    cross join unnest(array['Nachfolgeartikelnummer_1', 'Nachfolgeartikelnummer_2', 'Nachfolgeartikelnummer_3',
                            'Alternativ_Artikel']) f
   where coalesce(trim(x.daten ->> f), '') <> ''
  on conflict (hersteller_id, artikelnummer_norm) do nothing;

  insert into pim.artikel_beziehung (von_artikel_id, zu_artikel_id, typ, position, status, nachweis, quelle_id)
  select distinct v.id, z.id, k.typ, k.pos, 'geprueft', 'Grundfos Stammdaten 2015 (' || k.feld || ')', v_quelle
    from _art x
    join pim.artikel v on v.hersteller_id = 1 and v.artikelnummer_norm = x.norm
    cross join lateral (values ('nachfolger', '1', 'Nachfolgeartikelnummer_1'), ('nachfolger', '2', 'Nachfolgeartikelnummer_2'),
                               ('nachfolger', '3', 'Nachfolgeartikelnummer_3'), ('alternative', null, 'Alternativ_Artikel')) k(typ, pos, feld)
    join pim.artikel z on z.hersteller_id = 1 and z.artikelnummer_norm = upper(replace(trim(x.daten ->> k.feld), ' ', ''))
   where coalesce(trim(x.daten ->> k.feld), '') <> '' and z.id <> v.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Nachfolger/Alternativen'; anzahl := n; return next;

  -- Auslauf 2015 als Marktstatus DE
  insert into pim.artikel_markt (artikel_id, markt, status, gpc_status, quelle_id)
  select distinct a.id, 'DE', case when lower(x.daten ->> 'Auslaufartikel') in ('yes', 'ja', 'true', '1') then 'auslauf' else 'sortiment' end,
         nullif(x.daten ->> 'Auslaufdatum', ''), v_quelle
    from _art x join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = x.norm
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Marktstatus DE 2015'; anzahl := n; return next;

  -- Maße und Attribute als Merkmale
  insert into pim.merkmal (code, bezeichnung, einheit, herkunft)
  select distinct 'ARGE_' || upper(t.daten ->> 'Massangabe'),
         case upper(t.daten ->> 'Massangabe') when 'BW' then 'Bruttogewicht' when 'NW' then 'Nettogewicht'
              when 'LA' then 'Länge' when 'BR' then 'Breite' when 'HO' then 'Höhe' when 'VO' then 'Volumen'
              else 'Maß ' || (t.daten ->> 'Massangabe') end,
         case upper(t.daten ->> 'Masseinheit') when 'KGM' then 'kg' when 'MMT' then 'mm' when 'CMT' then 'cm'
              when 'MTR' then 'm' when 'LTR' then 'l' when 'MTQ' then 'm³' when 'DMQ' then 'dm³' else t.daten ->> 'Masseinheit' end,
         'arge.artikelmasse'
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikelmasse.csv' and coalesce(t.daten ->> 'Massangabe', '') <> ''
  on conflict (code) do nothing;
  insert into pim.merkmal (code, bezeichnung, herkunft)
  select distinct 'ARGE_' || upper(t.daten ->> 'Attributname'), t.daten ->> 'Attributname', 'arge.artikelattribute'
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikelattribute.csv' and coalesce(t.daten ->> 'Attributname', '') <> ''
  on conflict (code) do nothing;

  insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
  select distinct on (a.id, m.code) a.id, m.code, t.daten ->> 'Masswert', pim.zahl(t.daten ->> 'Masswert'), '-', v_quelle
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(t.daten ->> 'Werksartikelnummer'), ' ', ''))
    join pim.merkmal m on m.code = 'ARGE_' || upper(t.daten ->> 'Massangabe')
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikelmasse.csv'
   order by a.id, m.code
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Maße als Merkmale'; anzahl := n; return next;

  insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
  select distinct on (a.id, m.code) a.id, m.code, coalesce(nullif(t.daten ->> 'Attributwert', ''), 'ja'),
         pim.zahl(t.daten ->> 'Attributwert'), '-', v_quelle
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(t.daten ->> 'Werksartikelnummer'), ' ', ''))
    join pim.merkmal m on m.code = 'ARGE_' || upper(t.daten ->> 'Attributname')
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikelattribute.csv'
   order by a.id, m.code
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Attribute als Merkmale'; anzahl := n; return next;

  -- Bilder/Dokumente
  insert into pim.medium (typ, dateiname, titel, kategorie, quell_schluessel, quelle_id)
  select distinct on (t.daten ->> 'Dokument') 'bild', t.daten ->> 'Dokument', nullif(t.daten ->> 'Dokument_Bezeichnung', ''),
         'ARGE ' || coalesce(t.daten ->> 'Dokumententyp', '') || ' ' || coalesce(t.daten ->> 'Bild_Verwendung', ''),
         'arge:' || (t.daten ->> 'Dokument'), v_quelle
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikeldokumentenzuordnungen.csv'
     and coalesce(t.daten ->> 'Dokument', '') <> ''
   order by t.daten ->> 'Dokument'
  on conflict (quell_schluessel) do nothing;
  get diagnostics n = row_count;
  schritt := 'Bilder (ARGE)'; anzahl := n; return next;

  insert into pim.artikel_medium (artikel_id, medium_id, rolle, sortierung, quelle_id)
  select distinct on (a.id, m.id) a.id, m.id,
         case when t.daten ->> 'Stellvertreterkennzeichen' = 'true' then 'stellvertreterbild' else 'galerie' end,
         coalesce(nullif(t.daten ->> 'Dokument_Sortierreihenfolge', '')::smallint, 0), v_quelle
    from raw.tabellen_zeile t join raw.quelldatei q on q.id = t.datei_id
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(t.daten ->> 'Werksartikelnummer'), ' ', ''))
    join pim.medium m on m.quell_schluessel = 'arge:' || (t.daten ->> 'Dokument')
   where q.pfad like '%GF_CSV_GESAMT_MP.zip!/%' and t.tabelle = 'artikeldokumentenzuordnungen.csv'
   order by a.id, m.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Bild-Zuordnungen (ARGE)'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.arge_uebernehmen() from public, anon, authenticated;
