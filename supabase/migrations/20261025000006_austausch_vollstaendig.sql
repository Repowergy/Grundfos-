-- Austauschpumpen vollständig im Stamm (Grundsatz „nichts wegwerfen“).
--
--  1. querverweis_wettbewerb: je Vorschlag die Länder-Preislisten (ReplPrcSyst) und die gpi-ReplIds
--  2. Grundfos-Altpumpen mit eigener Nummer (ReplSystem.ProductNo): Alt-Artikel verknüpfen und als
--     Beziehung 'nachfolger' (alt → neu) in artikel_beziehung eintragen
--  3. pim.fremdprodukt: alle Wettbewerberpumpen aus CompetitorProducts mit Hersteller, Baureihe,
--     Typ und allen technischen Daten (CompetitorProductData, Merkmalsnamen aus DL)

alter table pim.querverweis_wettbewerb
  add column if not exists maerkte text[],            -- GPC-Preislisten, z. B. {gws,gdk,gb}
  add column if not exists gpi_replids text[],
  add column if not exists fremd_artikel_id bigint references pim.artikel(id);

create table if not exists pim.fremdprodukt (
  id             bigint generated always as identity primary key,
  hersteller     text not null,                 -- z. B. 'WILO', 'KSB', 'FLYGT'
  baureihe_code  text,                          -- z. B. 'ETAFAM'
  baureihe       text,                          -- z. B. 'Etaline'
  produktnummer  text not null,                 -- GPC-Schlüssel, z. B. 'ETA0000001'
  typ            text,                          -- z. B. 'ETALINE 32-160/024.2'
  frequenz       smallint,
  status         text,
  kurven_id      text,                          -- gpi.curveset (Kennlinie)
  daten          jsonb,                         -- {"P2KW56": {"wert": "5.5", "einheit": "kW", "name": "P2"}, …}
  quelle_id      bigint not null references pim.quelle(id),
  unique (produktnummer, frequenz, quelle_id)
);
create index if not exists fremdprodukt_typ_idx on pim.fremdprodukt using gin (typ extensions.gin_trgm_ops);
create index if not exists fremdprodukt_hersteller_idx on pim.fremdprodukt (hersteller, baureihe);
alter table pim.fremdprodukt enable row level security;

create or replace function pim.austausch_vervollstaendigen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;

  -- 1. Märkte und ReplIds je Vorschlag
  with s as (
    select replid, manufacturer, trim(designation) as designation, 50::smallint as hz from gpi.replsystem50
    union all select replid, manufacturer, trim(designation), 60 from gpi.replsystem60
  ), p as (
    select replid, systemno, productno, comment, 50::smallint as hz from gpi.replpumps50
    union all select replid, systemno, productno, comment, 60 from gpi.replpumps60
  ), m as (
    select replid, prclist, 50::smallint as hz from gpi.replprcsyst50
    union all select replid, prclist, 60 from gpi.replprcsyst60
  ), agg as (
    select s.manufacturer, s.designation, s.hz, upper(replace(trim(p.productno), ' ', '')) as norm,
           nullif(p.systemno, '')::smallint as variante, nullif(trim(p.comment), '') as kommentar,
           array_agg(distinct m.prclist) filter (where m.prclist is not null) as maerkte,
           array_agg(distinct s.replid) as replids
      from s join p on p.replid = s.replid and p.hz = s.hz
      left join m on m.replid = s.replid and m.hz = s.hz
     group by 1, 2, 3, 4, 5, 6
  )
  update pim.querverweis_wettbewerb w
     set maerkte = agg.maerkte, gpi_replids = agg.replids
    from agg join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = agg.norm
   where w.quelle_id = v_quelle and w.fremdhersteller = agg.manufacturer and w.fremdtyp = agg.designation
     and w.frequenz = agg.hz and w.artikel_id = a.id
     and w.variante is not distinct from agg.variante and w.kommentar is not distinct from agg.kommentar;
  get diagnostics n = row_count;
  schritt := '1 Märkte/ReplIds ergänzt'; anzahl := n; return next;

  -- 2. Grundfos-Altpumpen mit eigener Nummer
  with s as (
    select replid, trim(designation) as designation, productno, 50::smallint as hz from gpi.replsystem50
     where coalesce(trim(productno), '') <> ''
    union all
    select replid, trim(designation), productno, 60 from gpi.replsystem60
     where coalesce(trim(productno), '') <> ''
  ), alt as (
    insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, status)
    select distinct on (upper(replace(trim(productno), ' ', '')))
           1, trim(productno), upper(replace(trim(productno), ' ', '')), 'historisch'
      from s
    on conflict (hersteller_id, artikelnummer_norm) do nothing
    returning id
  )
  select count(*) into n from alt;
  schritt := '2a Grundfos-Altpumpen neu angelegt'; anzahl := n; return next;

  update pim.querverweis_wettbewerb w
     set fremd_artikel_id = a.id
    from (select replid, productno, 50::smallint as hz from gpi.replsystem50
          union all select replid, productno, 60 from gpi.replsystem60) s
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(s.productno), ' ', ''))
   where w.quelle_id = v_quelle and coalesce(trim(s.productno), '') <> ''
     and w.frequenz = s.hz and s.replid = any (w.gpi_replids);
  get diagnostics n = row_count;
  schritt := '2b Alt-Artikel verknüpft'; anzahl := n; return next;

  insert into pim.artikel_beziehung (von_artikel_id, zu_artikel_id, typ, menge, position, status, nachweis, quelle_id)
  select distinct on (w.fremd_artikel_id, w.artikel_id)
         w.fremd_artikel_id, w.artikel_id, 'nachfolger', w.menge, null::text,
         'geprueft', 'gpi.mdb Austausch ' || w.fremdtyp || ' (' || w.frequenz || ' Hz, Variante '
           || coalesce(w.variante::text, '-') || coalesce(', ' || w.kommentar, '') || ')', v_quelle
    from pim.querverweis_wettbewerb w
   where w.quelle_id = v_quelle and w.fremd_artikel_id is not null and w.fremd_artikel_id <> w.artikel_id
   order by w.fremd_artikel_id, w.artikel_id, w.frequenz, w.variante
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '2c Nachfolger-Beziehungen'; anzahl := n; return next;

  -- 3. Wettbewerberpumpen mit technischen Daten
  insert into pim.fremdprodukt (hersteller, baureihe_code, baureihe, produktnummer, typ, frequenz, status,
                                kurven_id, daten, quelle_id)
  select coalesce(c.name, 'Unbekannt'), r.code, r.name, trim(cp.productno), trim(pn.prodname),
         nullif(cp.freq, '')::smallint, cp.status, cp.curvesetid,
         (select jsonb_object_agg(coalesce(dl.name, 'DL' || d.dlid),
                                  jsonb_strip_nulls(jsonb_build_object('wert', d.dlvalue, 'einheit', nullif(trim(dl.unit), ''),
                                                                       'name', dl.description)))
            from gpi.competitorproductdata d left join gpi.dl dl on dl.id = d.dlid
           where d.productid = cp.id),
         v_quelle
    from gpi.competitorproducts cp
    left join gpi.replacementpg r on r.id = cp.pgid
    left join gpi.competitor c on c.id = r.manufacturerid
    left join gpi.competitorprodnames pn on pn.id = cp.prodnameid
   where coalesce(trim(cp.productno), '') <> ''
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '3 Wettbewerberpumpen mit Daten'; anzahl := n; return next;
end;
$body$;

revoke execute on function pim.austausch_vervollstaendigen() from public, anon, authenticated;
