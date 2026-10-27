-- Pumpen ohne eigene Beschreibung in einer Sprache (Text-Engine-Vorlagen gibt es nur für CM, CR, NK, NKG, TP):
-- Beschreibung = Baureihenbeschreibung von Grundfos in dieser Sprache (DB_PGD) + Liste „Wichtige Daten“ (bis zu 10 Werte,
-- Namen und Werte übersetzt wie in den technischen Daten). Betrifft u. a. MAGNA3, UPS, ALPHA, SQ, Unilift, DDE, Motoren.

insert into pim.shop_phrase (schluessel, sprache, text) values
  ('wichtige_daten', 'de', 'Wichtige Daten'),
  ('wichtige_daten', 'en', 'Key data'),
  ('wichtige_daten', 'fr', 'Données principales'),
  ('wichtige_daten', 'it', 'Dati principali'),
  ('wichtige_daten', 'nl', 'Belangrijkste gegevens'),
  ('wichtige_daten', 'pl', 'Najważniejsze dane'),
  ('wichtige_daten', 'es', 'Datos principales'),
  ('wichtige_daten', 'pt', 'Dados principais'),
  ('wichtige_daten', 'sv', 'Viktiga data'),
  ('wichtige_daten', 'da', 'Vigtige data'),
  ('wichtige_daten', 'fi', 'Tärkeimmät tiedot'),
  ('wichtige_daten', 'nb', 'Viktige data'),
  ('wichtige_daten', 'cs', 'Hlavní údaje'),
  ('wichtige_daten', 'sk', 'Hlavné údaje'),
  ('wichtige_daten', 'hu', 'Fő adatok'),
  ('wichtige_daten', 'ro', 'Date principale'),
  ('wichtige_daten', 'bg', 'Основни данни'),
  ('wichtige_daten', 'hr', 'Glavni podaci'),
  ('wichtige_daten', 'sl', 'Glavni podatki'),
  ('wichtige_daten', 'el', 'Βασικά στοιχεία'),
  ('wichtige_daten', 'et', 'Põhiandmed'),
  ('wichtige_daten', 'lv', 'Galvenie dati'),
  ('wichtige_daten', 'lt', 'Pagrindiniai duomenys')
on conflict (schluessel, sprache) do update set text = excluded.text;

create or replace function pim.shop_eckdaten(p_artikel bigint, p_sprache text default 'de')
returns text
language sql stable
set search_path = pim, public
as $$
  with t as (select e, array_position(array['HEADMAXDM', 'LIQUMXC', 'LIQUMINC', 'PMAXBAR', 'PIPECON', 'PORTPORT', 'PHASE', 'UL1',
                                             'P1WMAX', 'P2KW', 'IPCLASS', 'IEEFFCLAS', 'MATPUMPH', 'WEIGHTNET'], e->>'code') as pos
               from jsonb_array_elements(pim.shop_technik(p_artikel, p_sprache)) e)
  select '<h3>' || pim.shop_phrase('wichtige_daten', p_sprache) || '</h3>' || E'\n<ul>' ||
         string_agg('<li>' || (e->>'name') || ': ' || (e->>'wert') || '</li>', '' order by pos) || '</ul>'
    from (select * from t where pos is not null order by pos limit 10) x
  having count(*) > 0
$$;
revoke execute on function pim.shop_eckdaten(bigint, text) from public, anon, authenticated;

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
    v_lang := coalesce(pim.uebersetze('DB_PGD', v_grp.code, p_sprache), case when p_sprache like 'en%' then v_grp.beschreibung end);
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
