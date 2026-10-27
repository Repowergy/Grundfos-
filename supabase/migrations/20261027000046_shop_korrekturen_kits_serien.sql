-- Korrekturen Pilot (27.10.2026)
--  1. Service-Kits mit Typbezeichnung („Kit, Shaft Seal“, „Bulk, Filter“) als Ersatzteil statt Pumpe
--  2. pim.shop_produktart: manuelle Festlegung der Produktart je Artikel (z. B. Drucksensor RPI → Zubehör)
--  3. Pumpen ohne Produktgruppe (SCALA2, RPI): Baureihentext aus Bereich SHOP_SERIE (Schlüssel = erster Teil der Typbezeichnung)
--  4. pim.uebersetzung.herkunft: 'grundfos' (Sprachpakete) oder 'maschinell' (Fachwörterbuch 27.10.2026)

alter table pim.uebersetzung add column if not exists herkunft text not null default 'grundfos';

create table if not exists pim.shop_produktart (
  artikel_id bigint primary key references pim.artikel(id) on delete cascade,
  produktart text not null check (produktart in ('pumpe', 'ersatzteil', 'zubehoer', 'sonstiges')),
  notiz      text
);
alter table pim.shop_produktart enable row level security;
insert into pim.shop_produktart (artikel_id, produktart, notiz)
select id, 'zubehoer', 'Drucksensor RPI (Zubehör, keine Pumpe)' from pim.artikel where hersteller_id = 1 and artikelnummer_norm = '98355521'
on conflict (artikel_id) do update set produktart = excluded.produktart;

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
