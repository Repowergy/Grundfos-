-- Pumpen mit nur einem „Platzhalter-Langtext“ (z. B. sv/pt/it … „Hydro MPC-E 2 CRE32-2“ = nur die Typbezeichnung) bekamen
-- keinen Baureihentext. Neu: eigener Langtext einer Pumpe unter 60 Zeichen gilt als fehlend → Baureihentext + wichtigste Daten.

create or replace function pim.shop_produkt(p_artikel bigint, p_sprache text default 'de')
returns jsonb
language plpgsql stable
set search_path = pim, public
as $body$
declare
  a record;
  v_grp record;
  v_art text;
  v_name_en text;
  v_name text;
  v_titel text;
  v_lang text;
  v_kurz text;
  v_passt text;
  v_eckdaten text;
begin
  select * into a from pim.v_artikel_de where id = p_artikel;
  if not found then return null; end if;

  select g.id, g.code, g.name, g.beschreibung into v_grp
    from pim.artikel_gruppe ag join pim.produktgruppe g on g.id = ag.gruppe_id
   where ag.artikel_id = p_artikel order by g.baum desc limit 1;

  -- Reihenfolge wichtig: Ersatzteile/Kits haben teils selbst Bestandteile, sind aber keine Pumpe
  v_art := case
             when (select x.produktart from pim.shop_produktart x where x.artikel_id = p_artikel) is not null
                  then (select x.produktart from pim.shop_produktart x where x.artikel_id = p_artikel)
             -- Service-Kits/Sets tragen eine Typbezeichnung („Kit, Shaft Seal“), sind aber Ersatzteile
             when a.typbezeichnung ~* '^\s*(kit|bulk|set)\M'
                  and exists (select 1 from pim.artikel_beziehung b where b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil')
                  then 'ersatzteil'
             when a.typbezeichnung is null
                  and exists (select 1 from pim.artikel_beziehung b where b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil')
                  then 'ersatzteil'
             when exists (select 1 from pim.gruppe_zubehoer z where z.zubehoer_artikel_id = p_artikel) then 'zubehoer'
             when a.typbezeichnung is not null
                  or exists (select 1 from pim.artikel_beziehung b where b.von_artikel_id = p_artikel and b.typ = 'ersatzteil')
                  then 'pumpe'
             when exists (select 1 from pim.artikel_beziehung b where b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil')
                  then 'ersatzteil'
             else 'sonstiges' end;

  -- Kurzbezeichnung in der Sprache: Grundfos-Kurztext (de), Gruppenbeschreibung, übersetzter Teilename
  v_name_en := (select t.text from pim.artikel_text t where t.artikel_id = p_artikel and t.art = 'titel'
                   and t.sprache = 'en' limit 1);
  v_name := coalesce(pim.uebersetze('DB_PARTS', v_name_en, p_sprache),
                     pim.uebersetze('PLG_PARTS', v_name_en, p_sprache),
                     pim.uebersetze('DB_PRODNAMEMECACC', v_name_en, p_sprache),
                     pim.uebersetze('DB_PRODNAMEELACC', v_name_en, p_sprache),
                     pim.uebersetze('DB_PRODNAMEPITACC', v_name_en, p_sprache),
                     pim.uebersetze('DB_PRODNAMEWASACC', v_name_en, p_sprache));
  v_kurz := case
              when p_sprache = 'de' and a.kurz1 is not null then btrim(regexp_replace(a.kurz1, '^GRUNDFOS\s+', '', 'i'))
              when v_art in ('ersatzteil', 'zubehoer', 'sonstiges') then coalesce(v_name, case when p_sprache like 'en%' then v_name_en end)
              else coalesce(pim.uebersetze('DB_PGD', v_grp.code, p_sprache),
                            case when p_sprache like 'en%' then v_grp.beschreibung end)
            end;
  v_titel := btrim('Grundfos ' || coalesce(regexp_replace(a.typbezeichnung, '^GRUNDFOS\s+', '', 'i'),
                                          case when v_art in ('ersatzteil', 'zubehoer') then coalesce(v_kurz, v_name_en) end,
                                          a.artikelnummer)
                   || case when a.typbezeichnung is not null and length(v_kurz) <= 60 then ' – ' || v_kurz else '' end
                   || case when a.typbezeichnung is null and v_art in ('ersatzteil', 'zubehoer') then ' (' || a.artikelnummer || ')'
                           else '' end);

  -- Beschreibung: Langtext der Sprache (Grundfos > Text-Engine), sonst Kurzbeschreibung der Engine
  select t.text into v_lang
    from pim.artikel_text t join pim.quelle q on q.id = t.quelle_id
   where t.artikel_id = p_artikel and t.sprache = p_sprache and t.art in ('lang', 'beschreibung') and q.export_freigabe
   order by (t.art = 'lang') desc, q.prioritaet desc limit 1;
  if v_art = 'pumpe' and length(btrim(v_lang)) < 60 then v_lang := null; end if;   -- nur Typbezeichnung o. Ä.

  -- Ersatzteile/Zubehör ohne eigenen Langtext: kurze Beschreibung mit den passenden Baureihen
  if v_lang is null and v_art in ('ersatzteil', 'zubehoer') then
    select string_agg(name, ', ' order by name) into v_passt
      from (select distinct g.name
              from pim.artikel_beziehung b
              join pim.artikel_gruppe ag on ag.artikel_id = b.von_artikel_id
              join pim.produktgruppe g on g.id = ag.gruppe_id
             where b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil'
            union
            select g.name from pim.gruppe_zubehoer z join pim.produktgruppe g on g.id = z.gruppe_id
             where z.zubehoer_artikel_id = p_artikel
             limit 40) x;
    v_lang := concat_ws(E'\n',
      pim.shop_phrase(case v_art when 'ersatzteil' then 'original_ersatzteil' else 'original_zubehoer' end, p_sprache)
        || coalesce(': ' || coalesce(v_name, v_name_en), '') || ' (' || a.artikelnummer || ').',
      case when v_passt is not null then pim.shop_phrase('passend_fuer', p_sprache) || ' ' || v_passt end);
  end if;

  -- Pumpen ohne eigenen Text in dieser Sprache: Baureihenbeschreibung (Grundfos, übersetzt) + wichtigste Daten
  if v_lang is null and v_art = 'pumpe' then
    v_lang := coalesce(pim.uebersetze('DB_PGD', v_grp.code, p_sprache), case when p_sprache like 'en%' then v_grp.beschreibung end,
                       -- ohne Produktgruppe (z. B. SCALA2, RPI): Baureihe aus dem ersten Teil der Typbezeichnung
                       pim.uebersetze('SHOP_SERIE', upper(substring(a.typbezeichnung from '^\s*([A-Za-z0-9]+)')), p_sprache));
    v_eckdaten := pim.shop_eckdaten(p_artikel, p_sprache);
  end if;

  return jsonb_build_object(
    'sprache', p_sprache,
    'artikelnummer', a.artikelnummer,
    'produktart', v_art,
    'titel', v_titel,
    'kurz', v_kurz,
    'body_html', concat_ws(E'\n', pim.text_html(v_lang), v_eckdaten,
                           case when p_sprache = 'de' and a.technik is not null and v_lang is not null then pim.text_html(a.technik) end),
    'baureihe', v_grp.name,
    'baureihe_text', coalesce(pim.uebersetze('DB_PGD', v_grp.code, p_sprache), v_grp.beschreibung),
    'technische_daten', pim.shop_technik(p_artikel, p_sprache));
end;
$body$;

-- Kennzahl technik_uebersetzt_pct: Anteil der technischen Daten, deren Merkmalsname in der Sprache übersetzt vorliegt
-- (bisher: Name weicht vom englischen ab – zählte gleich geschriebene Namen wie „P1“, „Cos phi“ fälschlich als fehlend)
CREATE OR REPLACE FUNCTION pim.shop_texte_schritt(p_paket integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'pim', 'public'
AS $function$
declare r record; d jsonb; n integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  for r in select artikel_id, sprache from pim.shop_text_auftrag where not erledigt
            order by sprache, artikel_id limit p_paket for update skip locked loop
    d := pim.shop_produkt(r.artikel_id, r.sprache);
    if d is not null then
      insert into pim.shop_text (artikel_id, sprache, produktart, titel, kurz, body_html, technische_daten, technik_anzahl,
                                 technik_uebersetzt_pct, kategorien, dokumente, erzeugt_am)
      values (r.artikel_id, r.sprache, d->>'produktart', d->>'titel', d->>'kurz', d->>'body_html', d->'technische_daten',
              jsonb_array_length(coalesce(d->'technische_daten', '[]')),
              case when r.sprache like 'en%' then 100 else
                (select round(100.0 * count(*) filter (where exists (select 1 from pim.merkmal_uebersetzung mu
                                                                   where mu.merkmal_code = x->>'code' and mu.sprache = r.sprache
                                                                     and mu.status <> 'gesperrt')) / nullif(count(*), 0), 1)
                   from jsonb_array_elements(coalesce(d->'technische_daten', '[]')) x) end,
              case when d->>'produktart' = 'ersatzteil' then pim.shop_ersatzteil_kategorien(r.artikel_id, r.sprache) end,
              pim.shop_dokumente(r.artikel_id, d->>'produktart', r.sprache), now())
      on conflict (artikel_id, sprache) do update set produktart = excluded.produktart, titel = excluded.titel, kurz = excluded.kurz,
             body_html = excluded.body_html, technische_daten = excluded.technische_daten, technik_anzahl = excluded.technik_anzahl,
             technik_uebersetzt_pct = excluded.technik_uebersetzt_pct, kategorien = excluded.kategorien,
             dokumente = excluded.dokumente, erzeugt_am = now();
    end if;
    update pim.shop_text_auftrag set erledigt = true where artikel_id = r.artikel_id and sprache = r.sprache;
    n := n + 1;
  end loop;
  return n;
end;
$function$;
