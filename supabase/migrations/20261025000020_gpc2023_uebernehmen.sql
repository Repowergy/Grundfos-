-- GPC-Software 09/2023 in den Stamm übernehmen (Quelle 'gpc2023', Priorität 78 – neuer als gpi.mdb 2015).
--
--  1. Märkte: Preislisten-Kürzel, die es 2015 noch nicht gab, als 'GPC:<kürzel>' (Land noch nicht zugeordnet)
--  2. Artikel: Nummern aus Sortimenten 2023, VVS-Liste und Schnellaustausch, die bisher fehlen
--     (nur plausible Nummern; Auffälliges wie '"EMPALME10-12"' bleibt nur in gpc2023.sortiment)
--  3. Sortiment 2023 je Markt (pim.artikel_markt mit GPC-Status und Fasttrack)
--  4. VVS-Liste: EAN (wo noch keine), VVS-Nummer und Typbezeichnung als Alias
--  5. Schnellaustausch, Grundfos-Seite: Eckdaten (Baulänge, Anschluss, Phase, P2 …) als Merkmale,
--     nur wo der Artikel das Merkmal noch nicht hat → der technische Austauschfinder kennt mehr Ziele
--  6. Schnellaustausch, Wettbewerb (+ „OLD GRUNDFOS“): neue Fremdpumpen in pim.fremdprodukt,
--     vorhandene (gleiche GPC-Nummer und Frequenz) um fehlende Eckdaten ergänzt

insert into pim.merkmal (code, bezeichnung, erklaerung, herkunft)
values ('SHAFT_SEAL_CODE', 'Shaft seal code', 'Gleitringdichtung (Code)', 'gpc2023.QuickReplacement')
on conflict (code) do nothing;

create or replace function pim.gpc2023_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpc2023, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  select id into v_quelle from pim.quelle where typ = 'gpc2023' order by id limit 1;

  -- 1. Märkte
  insert into pim.markt (code, name, gpc_code, ist_land)
  select distinct 'GPC:' || s.kuerzel, 'GPC-Preisliste ' || s.kuerzel || ' (2023)', s.kuerzel, false
    from gpc2023.sortiment s
   where not exists (select 1 from pim.markt m where s.kuerzel in (m.gpc_code, m.gpc_code_2023))
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '1 neue Märkte/Preislisten'; anzahl := n; return next;

  -- 2. Artikel
  with nr as (
    select distinct on (norm) norm, nr from (
      select norm, productno as nr, 1 as prio from gpc2023.sortiment
      union all
      select upper(replace(trim(daten->>'ProdNumber'), ' ', '')), trim(daten->>'ProdNumber'), 2 from gpc2023.vvs
      union all
      select upper(replace(trim(daten->>'DbIdentifier'), ' ', '')), trim(daten->>'DbIdentifier'), 3
        from gpc2023.schnellaustausch
       where daten->'DataValues'->0->>'BaseValue' = 'GRUNDFOS' and (daten->>'TemplateNo') <> '0'
    ) x
     where norm ~ '^[0-9A-Z][0-9A-Z.\-/]{2,19}$' and norm !~ '^0+$'
     order by norm, prio
  ), neu as (
    insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm)
    select 1, nr, norm from nr
    on conflict (hersteller_id, artikelnummer_norm) do nothing
    returning id
  )
  select count(*) into n from neu;
  schritt := '2 neue Artikel (bisher unbekannt)'; anzahl := n; return next;

  -- 3. Sortiment 2023
  insert into pim.artikel_markt (artikel_id, markt, status, gpc_status, fasttrack, quelle_id)
  select distinct on (a.id, m.code) a.id, m.code, 'sortiment', s.status, s.fasttrack = '1', v_quelle
    from gpc2023.sortiment s
    join pim.markt m on s.kuerzel in (m.gpc_code, m.gpc_code_2023)   -- 2023-Kürzel: siehe 0022
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = s.norm
   order by a.id, m.code, s.status
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '3 Sortiment 2023 (Artikel × Markt)'; anzahl := n; return next;

  -- 4. VVS-Liste
  update pim.artikel a set ean = v.ean, aktualisiert_am = now()
    from (select distinct on (upper(replace(trim(daten->>'ProdNumber'), ' ', '')))
                 upper(replace(trim(daten->>'ProdNumber'), ' ', '')) as norm, daten->>'EanNo' as ean
            from gpc2023.vvs where daten->>'EanNo' ~ '^\d{13}$'
           order by 1, 2) v
   where a.hersteller_id = 1 and a.artikelnummer_norm = v.norm and a.ean is null;
  get diagnostics n = row_count;
  schritt := '4a EAN ergänzt'; anzahl := n; return next;

  insert into pim.artikel_alias (artikel_id, typ, wert, quelle_id)
  select distinct a.id, x.typ, x.wert, v_quelle
    from gpc2023.vvs v
    cross join lateral (values ('vvs', nullif(trim(v.daten->>'VvsNo'), '')),
                               ('typbezeichnung', nullif(trim(v.daten->>'Prodname'), ''))) x(typ, wert)
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(replace(trim(v.daten->>'ProdNumber'), ' ', ''))
   where x.wert is not null
     and (x.typ = 'vvs' or not exists (select 1 from pim.artikel_alias t
                                        where t.artikel_id = a.id and t.typ = 'typbezeichnung'))
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '4b VVS-Nummern und Typbezeichnungen'; anzahl := n; return next;

  -- 5. Schnellaustausch, Grundfos-Seite
  create temp table _qr on commit drop as
  select q.cache_id, (q.daten->>'Freq')::smallint as freq, trim(q.daten->>'DbIdentifier') as dbid,
         nullif(q.daten->>'PrcList', '') as prclist, nullif((q.daten->>'P1Avg')::numeric, 0) as p1avg,
         q.daten->'DataValues'->0->>'BaseValue' as hersteller,
         d->>'Label' as label, trim(d->>'BaseValue') as wert, nullif(regexp_replace(d->>'BaseUnit', '^t_', ''), '') as einheit
    from gpc2023.schnellaustausch q
    cross join lateral jsonb_array_elements(q.daten->'DataValues') d
   where (q.daten->>'TemplateNo') <> '0' and d->>'Label' <> 'Manufacturer' and trim(d->>'BaseValue') <> '';

  insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
  select distinct on (a.id, q.label) a.id, q.label, q.wert, pim.zahl(q.wert), '-', v_quelle
    from _qr q
    join pim.merkmal m on m.code = q.label
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(q.dbid, ' ', ''))
   where q.hersteller = 'GRUNDFOS'
     and not exists (select 1 from pim.artikel_merkmal x where x.artikel_id = a.id and x.merkmal_code = q.label)
   order by a.id, q.label, q.freq
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '5a Grundfos-Eckdaten als Merkmale'; anzahl := n; return next;

  insert into pim.artikel_alias (artikel_id, typ, wert, quelle_id)
  select distinct on (a.id) a.id, 'typbezeichnung', q.wert, v_quelle
    from _qr q
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(q.dbid, ' ', ''))
   where q.hersteller = 'GRUNDFOS' and q.label in ('PRODNAME', 'COMB_PRODUCT_NAME')
     and not exists (select 1 from pim.artikel_alias t where t.artikel_id = a.id and t.typ = 'typbezeichnung')
   order by a.id, q.label desc
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '5b Typbezeichnungen (Grundfos)'; anzahl := n; return next;

  -- 6. Schnellaustausch, Wettbewerb
  create temp table _fp on commit drop as
  select q.cache_id, q.freq, q.dbid, q.prclist, q.p1avg, q.hersteller,
         max(q.wert) filter (where q.label = 'PRODNAME') as prodname,
         max(q.wert) filter (where q.label = 'COMB_PRODUCT_NAME') as comb,
         jsonb_object_agg(q.label, jsonb_strip_nulls(jsonb_build_object('wert', q.wert, 'einheit', q.einheit,
                                                                        'name', m.bezeichnung))) as daten
    from _qr q left join pim.merkmal m on m.code = q.label
   where q.hersteller <> 'GRUNDFOS'
   group by 1, 2, 3, 4, 5, 6;

  update pim.fremdprodukt p
     set daten = f.daten || coalesce(p.daten, '{}'::jsonb)          -- vorhandene Werte haben Vorrang
    from _fp f
   where p.produktnummer = f.dbid and p.frequenz = f.freq and f.dbid ~ '[A-Z]'
     and exists (select 1 from jsonb_object_keys(f.daten) k where not coalesce(p.daten, '{}'::jsonb) ? k);
  get diagnostics n = row_count;
  schritt := '6a vorhandene Fremdpumpen ergänzt'; anzahl := n; return next;

  insert into pim.fremdprodukt (hersteller, produktnummer, typ, frequenz, status, daten, quelle_id)
  select case f.hersteller when 'OLD GRUNDFOS' then 'GRUNDFOS (alt)' else f.hersteller end,
         case when f.dbid ~ '[A-Z]' then f.dbid else 'QR' || f.cache_id end,
         coalesce(f.prodname, f.comb), f.freq, f.prclist,
         f.daten || jsonb_strip_nulls(jsonb_build_object('_p1_mittel_w', f.p1avg, '_schnellaustausch_id', f.cache_id)),
         v_quelle
    from _fp f
   where coalesce(f.prodname, f.comb) is not null
     and not exists (select 1 from pim.fremdprodukt p where p.produktnummer = f.dbid and p.frequenz = f.freq)
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '6b neue Fremdpumpen'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.gpc2023_uebernehmen() from public, anon, authenticated;
