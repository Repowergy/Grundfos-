-- Dokumente je Shop-Produkt und Sprache (26.10.2026)
--
-- Fehler bis 0032: die Export-Ansicht filterte auf medium.sprache in ('de', 'en'); die GPC-Dokumente tragen aber den
-- GPC-Sprachcode (DEU, ENU, FRA …) → Anleitungen und Service-Kataloge fehlten in der Pilot-Datei.
--
-- pim.shop_dokumente(artikel, produktart, sprache) → [{typ, titel, sprache, url}, …]
--   Quellen: Medien des Artikels, seiner Produktgruppen und – bei Ersatzteilen – die Service-Kataloge und
--            Explosionszeichnungen der Baureihen der Pumpen, in die das Teil passt (häufigste Baureihen zuerst)
--   Sprache: Dokument in der Shop-Sprache, sonst Englisch; mehrsprachige Dokumente (GPC „COMMON“) immer;
--            dieselbe Datei nur einmal (Titel aus dem Medium in der passendsten Sprache)
--   Reihenfolge: Datenblatt, Anleitung, Service, Maß-, Schalt-, Explosionszeichnung, Sonstiges; höchstens 40

create or replace function pim.shop_dokumente(p_artikel bigint, p_produktart text default null, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $body$
  with spr as (
    select coalesce((select gpc_code from pim.sprache where iso = p_sprache), 'ENU') as gpc
  ),
  gruppen as (
    select ag.gruppe_id, 0 as rang from pim.artikel_gruppe ag where ag.artikel_id = p_artikel
    union all
    select x.gruppe_id, x.rang from (
      select ag.gruppe_id, row_number() over (order by count(*) desc) as rang
        from pim.artikel_beziehung b
        join pim.artikel_gruppe ag on ag.artikel_id = b.von_artikel_id
       where p_produktart = 'ersatzteil' and b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil'
       group by ag.gruppe_id) x
     where x.rang <= 5
  ),
  kandidat as (
    select m.id, m.typ, m.titel, m.dateiname, m.sprache, m.extern_url, 0 as rang
      from pim.artikel_medium am join pim.medium m on m.id = am.medium_id
     where am.artikel_id = p_artikel
    union all
    select m.id, m.typ, m.titel, m.dateiname, m.sprache, m.extern_url, g.rang
      from gruppen g
      join pim.gruppe_medium gm on gm.gruppe_id = g.gruppe_id
      join pim.medium m on m.id = gm.medium_id
     where g.rang = 0 or m.typ in ('service', 'explosionszeichnung')   -- von Pumpen-Baureihen nur Service-Unterlagen
  ),
  gefiltert as (
    select distinct on (k.extern_url) k.*, (d.container like '%COMMON.zip') as mehrsprachig
      from kandidat k
      left join pim.medium_datei d on d.medium_id = k.id
      cross join spr
     where k.typ <> 'bild' and k.extern_url is not null
       and (k.sprache is null or k.sprache in (spr.gpc, 'ENU') or d.container like '%COMMON.zip')
     order by k.extern_url, (k.sprache = spr.gpc) desc, (k.sprache = 'ENU') desc, k.rang, k.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'typ', f.typ,
           'titel', coalesce(f.titel, regexp_replace(f.dateiname, '^.*/', '')),
           'sprache', case when f.mehrsprachig then 'multi'
                           else coalesce((select s.iso from pim.sprache s where s.gpc_code = f.sprache), lower(f.sprache)) end,
           'url', f.extern_url)
         order by f.prio, f.rang, f.titel), '[]')
    from (select g.*, case g.typ when 'datenblatt' then 1 when 'anleitung' then 2 when 'service' then 3
                                 when 'massbild' then 4 when 'schaltbild' then 5 when 'explosionszeichnung' then 6
                                 else 7 end as prio
            from gefiltert g
           order by prio, rang, titel
           limit 40) f
$body$;
revoke execute on function pim.shop_dokumente(bigint, text, text) from public, anon, authenticated;

-- Export-Ansicht: Dokumente aus pim.shop_dokumente() (sonst unverändert gegenüber 0029)
create or replace view pim.v_shop_export_de with (security_invoker = true) as
select s.kanal, s.rang, s.grund,
       g.id as artikel_id, g.artikelnummer, g.ean, g.typbezeichnung, g.produktgruppe,
       lower(regexp_replace(regexp_replace('grundfos-' || coalesce(g.typbezeichnung, '') || '-' || g.artikelnummer,
                                           '[^A-Za-z0-9]+', '-', 'g'), '(^-|-$)', '', 'g')) as handle,
       p.d->>'titel' as titel,
       p.d->>'body_html' as body_html,
       g.kurz1, g.kurz2,
       (select round(am.wert_num * 1000) from pim.artikel_merkmal am
         where am.artikel_id = g.id and am.merkmal_code = 'WEIGHTGRS' and am.wert_num > 0 limit 1) as gramm,
       p.d->'technische_daten' as technische_daten,
       (select coalesce(jsonb_agg(distinct z.artikelnummer), '[]') from pim.artikel_beziehung b
          join pim.artikel z on z.id = b.zu_artikel_id
         where b.von_artikel_id = g.id and b.typ = 'ersatzteil') as ersatzteile,
       (select coalesce(jsonb_agg(x.artikelnummer), '[]') from pim.zubehoer(g.id, 300) x) as zubehoer,
       (select coalesce(jsonb_agg(distinct z.artikelnummer), '[]') from pim.artikel_beziehung b
          join pim.artikel z on z.id = b.zu_artikel_id
         where b.von_artikel_id = g.id and b.typ = 'nachfolger') as nachfolger,
       (select coalesce(jsonb_agg(distinct v.artikelnummer), '[]') from pim.artikel_beziehung b
          join pim.artikel v on v.id = b.von_artikel_id
         where b.zu_artikel_id = g.id and b.typ = 'nachfolger') as ersetzt_grundfos,
       (select coalesce(jsonb_agg(distinct w.fremdhersteller || ' ' || w.fremdtyp), '[]')
          from pim.querverweis_wettbewerb w where w.artikel_id = g.id) as ersetzt_wettbewerb,
       (select string_agg(distinct x, ', ') from (
          select 'Grundfos' as x union all select g.produktgruppe
          union all select case p.d->>'produktart' when 'ersatzteil' then 'Ersatzteil' when 'zubehoer' then 'Zubehör'
                                                  when 'pumpe' then 'Pumpe' end
          union all select 'Bestseller' where s.grund like 'Bestseller%'
          union all select 'Text: maschinell' where g.lang is null and g.beschreibung is not null) t
         where x is not null) as tags,
       q.punkte as score,
       p.d->>'produktart' as produktart,
       (select coalesce(jsonb_agg(x.artikelnummer), '[]') from (
          select distinct v.artikelnummer from pim.artikel_beziehung b join pim.artikel v on v.id = b.von_artikel_id
           where b.zu_artikel_id = g.id and b.typ = 'ersatzteil' order by 1 limit 500) x) as passt_zu,
       bi.b->'urls' as bilder,   -- mit Ersatzlösungen, s. 0032
       pim.shop_dokumente(g.id, p.d->>'produktart', 'de') as dokumente,   -- s. 0033
       (select coalesce(jsonb_agg(distinct coalesce(tp.name || ' > ', '') || t.name), '[]')
          from pim.artikel_gruppe ag
          join pim.produktgruppe ga on ga.id = ag.gruppe_id
          join pim.produktgruppe gk on ga.baum like gk.baum || '%'          -- Anwendung hängt oft an der Familie
          join pim.shop_kategorie_gruppe kg on kg.gruppe_id = gk.id
          join pim.shop_kategorie k on k.id = kg.kategorie_id
          join pim.shop_kategorie_text t on t.kategorie_id = k.id and t.sprache = 'de'
          left join pim.shop_kategorie_text tp on tp.kategorie_id = k.parent_id and tp.sprache = 'de'
         where ag.artikel_id = g.id and k.code not in ('GENERAL')) as kategorien,
       bi.b->>'alt' as bild_alt,
       bi.b->>'art' as bild_art
  from pim.shop_auswahl s
  join pim.v_artikel_de g on g.id = s.artikel_id
  cross join lateral (select pim.shop_produkt(g.id, 'de') as d) p
  cross join lateral (select pim.shop_bilder(g.id, p.d->>'produktart') as b) bi
  left join pim.artikel_qualitaet q on q.artikel_id = s.artikel_id;
