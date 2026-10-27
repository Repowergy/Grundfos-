-- Export-Ansicht: Ersatzteile erhalten ihre Kategorie aus der Baureihe der passenden Pumpen (pim.shop_ersatzteil_kategorien, 0041);
-- übrige Spalten unverändert gegenüber 0033
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
       case when p.d->>'produktart' = 'ersatzteil' then pim.shop_ersatzteil_kategorien(g.id, 'de')   -- s. 0041
       else (select coalesce(jsonb_agg(distinct coalesce(tp.name || ' > ', '') || t.name), '[]')
          from pim.artikel_gruppe ag
          join pim.produktgruppe ga on ga.id = ag.gruppe_id
          join pim.produktgruppe gk on ga.baum like gk.baum || '%'          -- Anwendung hängt oft an der Familie
          join pim.shop_kategorie_gruppe kg on kg.gruppe_id = gk.id
          join pim.shop_kategorie k on k.id = kg.kategorie_id
          join pim.shop_kategorie_text t on t.kategorie_id = k.id and t.sprache = 'de'
          left join pim.shop_kategorie_text tp on tp.kategorie_id = k.parent_id and tp.sprache = 'de'
         where ag.artikel_id = g.id and k.code not in ('GENERAL')) end as kategorien,
       bi.b->>'alt' as bild_alt,
       bi.b->>'art' as bild_art
  from pim.shop_auswahl s
  join pim.v_artikel_de g on g.id = s.artikel_id
  cross join lateral (select pim.shop_produkt(g.id, 'de') as d) p
  cross join lateral (select pim.shop_bilder(g.id, p.d->>'produktart') as b) bi
  left join pim.artikel_qualitaet q on q.artikel_id = s.artikel_id;
