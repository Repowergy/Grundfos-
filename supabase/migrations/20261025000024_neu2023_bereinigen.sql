-- Korrektur zu 0020: falsch angelegte „neue Artikel“ aus GPC 2023 bereinigen.
--
--  a) 6–7-stellige Nummern (z. B. 7201925 = SP 14A-25N) sind Grundfos-Nummern ohne führende Null. Alle 210 gibt es
--     8-stellig schon (07201925) → Merkmale, Aliase, Märkte dorthin übertragen, Dublette löschen.
--  b) 3-stellige „Nummern“ im Schnellaustausch (z. B. 417 = UMA 50-80, 532 = UPS 50-40 (/4) F) sind interne Kennungen
--     alter Grundfos-Pumpen (USA/Kanada/Mexiko) → als Altpumpe in pim.fremdprodukt ('GRUNDFOS (alt)'), Artikel löschen.
--  c) Buchungs-/Dienstleistungscodes aus Sortimentslisten (ANTICIPO, CASHDISC, COMMISSIONING, DUMMYCBS …) sind keine
--     Produkte → löschen. Die Rohdaten bleiben in gpc2023.sortiment / gpc2023.schnellaustausch.
-- 0020 filtert diese Fälle inzwischen selbst (gpc2023_uebernehmen).

create or replace function pim.neu2023_bereinigen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpc2023, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'gpc2023' order by id limit 1);
  -- Zeitfenster des Laufs von pim.gpc2023_uebernehmen() (cron, 25.10.2026 11:19–11:23 UTC): nur diese Artikel
  v_von timestamptz := timestamptz '2026-10-25 11:19:00+00';
  v_bis timestamptz := timestamptz '2026-10-25 11:24:00+00';
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  -- a) Dubletten ohne führende Null
  create temp table _dub on commit drop as
  select a.id as alt_id, z.id as ziel_id
    from pim.artikel a
    join pim.artikel z on z.hersteller_id = 1 and z.artikelnummer_norm = lpad(a.artikelnummer_norm, 8, '0')
   where a.hersteller_id = 1 and a.artikelnummer_norm ~ '^[0-9]{6,7}$'
     and a.angelegt_am between v_von and v_bis and z.id <> a.id;

  insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
  select d.ziel_id, m.merkmal_code, m.wert, m.wert_num, m.sprache, m.quelle_id
    from _dub d join pim.artikel_merkmal m on m.artikel_id = d.alt_id
   where not exists (select 1 from pim.artikel_merkmal x where x.artikel_id = d.ziel_id and x.merkmal_code = m.merkmal_code)
  on conflict do nothing;
  insert into pim.artikel_alias (artikel_id, typ, wert, quelle_id)
  select d.ziel_id, l.typ, l.wert, l.quelle_id from _dub d join pim.artikel_alias l on l.artikel_id = d.alt_id
  on conflict do nothing;
  insert into pim.artikel_markt (artikel_id, markt, status, gpc_status, fasttrack, quelle_id)
  select d.ziel_id, m.markt, m.status, m.gpc_status, m.fasttrack, m.quelle_id
    from _dub d join pim.artikel_markt m on m.artikel_id = d.alt_id
  on conflict do nothing;
  delete from pim.artikel a using _dub d where a.id = d.alt_id;
  get diagnostics n = row_count;
  schritt := 'a Dubletten ohne führende Null zusammengeführt'; anzahl := n; return next;

  -- b) interne Kennungen → Altpumpen
  insert into pim.fremdprodukt (hersteller, produktnummer, typ, frequenz, status, daten, quelle_id)
  select 'GRUNDFOS (alt)', 'QR' || q.cache_id,
         coalesce(max(d->>'BaseValue') filter (where d->>'Label' = 'PRODNAME'),
                  max(d->>'BaseValue') filter (where d->>'Label' = 'COMB_PRODUCT_NAME')),
         (q.daten->>'Freq')::smallint, nullif(q.daten->>'PrcList', ''),
         jsonb_object_agg(d->>'Label', jsonb_strip_nulls(jsonb_build_object(
             'wert', d->>'BaseValue', 'einheit', nullif(regexp_replace(d->>'BaseUnit', '^t_', ''), ''))))
           filter (where d->>'Label' <> 'Manufacturer')
           || jsonb_build_object('_schnellaustausch_id', q.cache_id, '_gpc_kennung', q.daten->>'DbIdentifier'),
         v_quelle
    from gpc2023.schnellaustausch q
    cross join lateral jsonb_array_elements(q.daten->'DataValues') d
   where q.daten->'DataValues'->0->>'BaseValue' = 'GRUNDFOS' and (q.daten->>'TemplateNo') <> '0'
     and q.daten->>'DbIdentifier' ~ '^[0-9]{1,5}$'
   group by q.cache_id, q.daten
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'b Grundfos-Altpumpen (interne Kennung) als Fremdprodukt'; anzahl := n; return next;

  delete from pim.artikel a
   where a.hersteller_id = 1 and a.angelegt_am between v_von and v_bis
     and a.artikelnummer_norm ~ '^[0-9]{1,5}$';
  get diagnostics n = row_count;
  schritt := 'b falsche Artikel (interne Kennung) gelöscht'; anzahl := n; return next;

  -- c) Buchungscodes
  delete from pim.artikel a
   where a.hersteller_id = 1 and a.angelegt_am between v_von and v_bis and a.artikelnummer_norm ~ '^[A-Z]+$'
     and not exists (select 1 from pim.artikel_text t where t.artikel_id = a.id);
  get diagnostics n = row_count;
  schritt := 'c Buchungscodes gelöscht'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.neu2023_bereinigen() from public, anon, authenticated;
