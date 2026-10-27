-- Produktbeschreibungen je Land/Sprache (27.10.2026)
--
-- 1. Text-Engine für 13 weitere Sprachen mit Grundfos-Textvorlagen: es, pt, sv, da, fi, cs, hu, ro, bg, hr, sl, lv, lt
--    (ohne Vorlagen in den GPC-Sprachpaketen: nb, sk, el, et → bisher nur Titel/Fachbegriffe, keine Fließtexte)
--    Aufträge mit Priorität: Shop-Auswahl (Pilot) zuerst, danach der übrige Katalog
-- 2. pim.shop_phrase: feste Shop-Formulierungen je Sprache (Ersatzteil/Zubehör-Text, „Passend für“, Kategorie „Ersatzteile“)
--    statt fester Texte in shop_produkt / shop_ersatzteil_kategorien – 23 europäische Sprachen
-- 3. interne Felder aus den technischen Daten entfernt (Berechnungsnr., QT-Konfiguration, interne Motorkennung, Produktsortiment)
-- 4. pim.shop_text: fertige Shop-Texte je Artikel und Sprache fest gespeichert (Titel, Kurztext, Beschreibung, technische Daten
--    mit übersetzten Namen und Werten, Kategorien, Dokumente) + Übersetzungsgrad der technischen Daten

create table if not exists pim.shop_phrase (
  schluessel text not null,
  sprache    text not null,
  text       text not null,
  primary key (schluessel, sprache)
);
alter table pim.shop_phrase enable row level security;
insert into pim.shop_phrase (schluessel, sprache, text) values
  ('original_ersatzteil', 'de', 'Original-Grundfos-Ersatzteil'),
  ('original_zubehoer', 'de', 'Original-Grundfos-Zubehör'),
  ('passend_fuer', 'de', 'Passend für:'),
  ('kategorie_ersatzteile', 'de', 'Ersatzteile'),
  ('original_ersatzteil', 'en', 'Genuine Grundfos spare part'),
  ('original_zubehoer', 'en', 'Genuine Grundfos accessory'),
  ('passend_fuer', 'en', 'Suitable for:'),
  ('kategorie_ersatzteile', 'en', 'Spare parts'),
  ('original_ersatzteil', 'fr', 'Pièce détachée d''origine Grundfos'),
  ('original_zubehoer', 'fr', 'Accessoire d''origine Grundfos'),
  ('passend_fuer', 'fr', 'Compatible avec :'),
  ('kategorie_ersatzteile', 'fr', 'Pièces détachées'),
  ('original_ersatzteil', 'it', 'Ricambio originale Grundfos'),
  ('original_zubehoer', 'it', 'Accessorio originale Grundfos'),
  ('passend_fuer', 'it', 'Adatto per:'),
  ('kategorie_ersatzteile', 'it', 'Ricambi'),
  ('original_ersatzteil', 'nl', 'Origineel Grundfos-reserveonderdeel'),
  ('original_zubehoer', 'nl', 'Origineel Grundfos-toebehoren'),
  ('passend_fuer', 'nl', 'Geschikt voor:'),
  ('kategorie_ersatzteile', 'nl', 'Reserveonderdelen'),
  ('original_ersatzteil', 'pl', 'Oryginalna część zamienna Grundfos'),
  ('original_zubehoer', 'pl', 'Oryginalne akcesorium Grundfos'),
  ('passend_fuer', 'pl', 'Pasuje do:'),
  ('kategorie_ersatzteile', 'pl', 'Części zamienne'),
  ('original_ersatzteil', 'es', 'Repuesto original Grundfos'),
  ('original_zubehoer', 'es', 'Accesorio original Grundfos'),
  ('passend_fuer', 'es', 'Compatible con:'),
  ('kategorie_ersatzteile', 'es', 'Repuestos'),
  ('original_ersatzteil', 'pt', 'Peça sobresselente original Grundfos'),
  ('original_zubehoer', 'pt', 'Acessório original Grundfos'),
  ('passend_fuer', 'pt', 'Compatível com:'),
  ('kategorie_ersatzteile', 'pt', 'Peças sobresselentes'),
  ('original_ersatzteil', 'sv', 'Original reservdel från Grundfos'),
  ('original_zubehoer', 'sv', 'Originaltillbehör från Grundfos'),
  ('passend_fuer', 'sv', 'Passar till:'),
  ('kategorie_ersatzteile', 'sv', 'Reservdelar'),
  ('original_ersatzteil', 'da', 'Original Grundfos-reservedel'),
  ('original_zubehoer', 'da', 'Originalt Grundfos-tilbehør'),
  ('passend_fuer', 'da', 'Passer til:'),
  ('kategorie_ersatzteile', 'da', 'Reservedele'),
  ('original_ersatzteil', 'fi', 'Alkuperäinen Grundfos-varaosa'),
  ('original_zubehoer', 'fi', 'Alkuperäinen Grundfos-lisävaruste'),
  ('passend_fuer', 'fi', 'Sopii malleihin:'),
  ('kategorie_ersatzteile', 'fi', 'Varaosat'),
  ('original_ersatzteil', 'nb', 'Original Grundfos-reservedel'),
  ('original_zubehoer', 'nb', 'Originalt Grundfos-tilbehør'),
  ('passend_fuer', 'nb', 'Passer til:'),
  ('kategorie_ersatzteile', 'nb', 'Reservedeler'),
  ('original_ersatzteil', 'cs', 'Originální náhradní díl Grundfos'),
  ('original_zubehoer', 'cs', 'Originální příslušenství Grundfos'),
  ('passend_fuer', 'cs', 'Vhodné pro:'),
  ('kategorie_ersatzteile', 'cs', 'Náhradní díly'),
  ('original_ersatzteil', 'sk', 'Originálny náhradný diel Grundfos'),
  ('original_zubehoer', 'sk', 'Originálne príslušenstvo Grundfos'),
  ('passend_fuer', 'sk', 'Vhodné pre:'),
  ('kategorie_ersatzteile', 'sk', 'Náhradné diely'),
  ('original_ersatzteil', 'hu', 'Eredeti Grundfos pótalkatrész'),
  ('original_zubehoer', 'hu', 'Eredeti Grundfos tartozék'),
  ('passend_fuer', 'hu', 'Kompatibilis:'),
  ('kategorie_ersatzteile', 'hu', 'Pótalkatrészek'),
  ('original_ersatzteil', 'ro', 'Piesă de schimb originală Grundfos'),
  ('original_zubehoer', 'ro', 'Accesoriu original Grundfos'),
  ('passend_fuer', 'ro', 'Compatibil cu:'),
  ('kategorie_ersatzteile', 'ro', 'Piese de schimb'),
  ('original_ersatzteil', 'bg', 'Оригинална резервна част Grundfos'),
  ('original_zubehoer', 'bg', 'Оригинален аксесоар Grundfos'),
  ('passend_fuer', 'bg', 'Подходящо за:'),
  ('kategorie_ersatzteile', 'bg', 'Резервни части'),
  ('original_ersatzteil', 'hr', 'Originalni rezervni dio Grundfos'),
  ('original_zubehoer', 'hr', 'Originalni pribor Grundfos'),
  ('passend_fuer', 'hr', 'Prikladno za:'),
  ('kategorie_ersatzteile', 'hr', 'Rezervni dijelovi'),
  ('original_ersatzteil', 'sl', 'Originalni nadomestni del Grundfos'),
  ('original_zubehoer', 'sl', 'Originalna dodatna oprema Grundfos'),
  ('passend_fuer', 'sl', 'Primerno za:'),
  ('kategorie_ersatzteile', 'sl', 'Nadomestni deli'),
  ('original_ersatzteil', 'el', 'Γνήσιο ανταλλακτικό Grundfos'),
  ('original_zubehoer', 'el', 'Γνήσιο αξεσουάρ Grundfos'),
  ('passend_fuer', 'el', 'Κατάλληλο για:'),
  ('kategorie_ersatzteile', 'el', 'Ανταλλακτικά'),
  ('original_ersatzteil', 'et', 'Originaalne Grundfosi varuosa'),
  ('original_zubehoer', 'et', 'Originaalne Grundfosi tarvik'),
  ('passend_fuer', 'et', 'Sobib:'),
  ('kategorie_ersatzteile', 'et', 'Varuosad'),
  ('original_ersatzteil', 'lv', 'Oriģināla Grundfos rezerves daļa'),
  ('original_zubehoer', 'lv', 'Oriģināls Grundfos piederums'),
  ('passend_fuer', 'lv', 'Piemērots:'),
  ('kategorie_ersatzteile', 'lv', 'Rezerves daļas'),
  ('original_ersatzteil', 'lt', 'Originali Grundfos atsarginė dalis'),
  ('original_zubehoer', 'lt', 'Originalus Grundfos priedas'),
  ('passend_fuer', 'lt', 'Tinka:'),
  ('kategorie_ersatzteile', 'lt', 'Atsarginės dalys')
on conflict (schluessel, sprache) do update set text = excluded.text;

create or replace function pim.shop_phrase(p_schluessel text, p_sprache text)
returns text language sql stable set search_path = pim, public as $$
  select coalesce((select text from pim.shop_phrase where schluessel = p_schluessel and sprache = p_sprache),
                  (select text from pim.shop_phrase where schluessel = p_schluessel and sprache = split_part(p_sprache, '-', 1)),
                  (select text from pim.shop_phrase where schluessel = p_schluessel and sprache = 'en'))
$$;

insert into pim.shop_merkmal_aus (code) values ('BEREGNINR'), ('QTTXTC'), ('MGMLMOTOR'), ('PRODRANG')
on conflict do nothing;

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

  return jsonb_build_object(
    'sprache', p_sprache,
    'artikelnummer', a.artikelnummer,
    'produktart', v_art,
    'titel', v_titel,
    'kurz', v_kurz,
    'body_html', concat_ws(E'\n', pim.text_html(v_lang),
                           case when p_sprache = 'de' and a.technik is not null and v_lang is not null then pim.text_html(a.technik) end),
    'baureihe', v_grp.name,
    'baureihe_text', coalesce(pim.uebersetze('DB_PGD', v_grp.code, p_sprache), v_grp.beschreibung),
    'technische_daten', pim.shop_technik(p_artikel, p_sprache));
end;
$body$;

create or replace function pim.shop_ersatzteil_kategorien(p_artikel bigint, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $$
  select coalesce(jsonb_agg(pfad order by rang), '[]')
    from (select eb.rang,
                 pim.shop_phrase('kategorie_ersatzteile', p_sprache)
                 || coalesce(' > ' || pim.shop_bereich(eb.gruppe_id, p_sprache), '')
                 || ' > ' || g.name as pfad
            from pim.ersatzteil_baureihe eb
            join pim.produktgruppe g on g.id = eb.gruppe_id
           where eb.teil_id = p_artikel and eb.rang <= 3) x
$$;

-- Text-Engine-Aufträge mit Priorität
alter table pim.text_auftrag add column if not exists prioritaet smallint not null default 9;
create index if not exists text_auftrag_offen_idx on pim.text_auftrag (prioritaet, sprache, artikel_id) where not erledigt;

create or replace function pim.texte_schritt(p_paket integer default 400)
returns integer
language plpgsql
set search_path = pim, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'textengine' order by id limit 1);
  r record;
  t text;
  n integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  for r in select artikel_id, sprache from pim.text_auftrag where not erledigt
            order by prioritaet, sprache, artikel_id limit p_paket for update skip locked loop
    t := pim.text_erzeugen(r.artikel_id, r.sprache, 'SHORT');
    if t is not null then
      insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
      values (r.artikel_id, r.sprache, 'beschreibung', t, v_quelle)
      on conflict (artikel_id, sprache, art, quelle_id) do update set text = excluded.text;
    end if;
    t := pim.text_erzeugen(r.artikel_id, r.sprache, 'LONG');
    if t is not null then
      insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
      values (r.artikel_id, r.sprache, 'lang', t, v_quelle)
      on conflict (artikel_id, sprache, art, quelle_id) do update set text = excluded.text;
    end if;
    update pim.text_auftrag set erledigt = true where artikel_id = r.artikel_id and sprache = r.sprache;
    n := n + 1;
  end loop;
  return n;
end;
$body$;

-- Aufträge: Shop-Auswahl mit Priorität 1, übriger Katalog 9
drop function if exists pim.texte_auftrag_anlegen(text[]);
create or replace function pim.texte_auftrag_anlegen(p_sprachen text[], p_nur_kanal text default null, p_prioritaet smallint default 9)
returns bigint
language sql
set search_path = pim, public
as $$
  with ins as (
    insert into pim.text_auftrag (artikel_id, sprache, prioritaet)
    select distinct ag.artikel_id, s, p_prioritaet
      from pim.text_familie f
      join pim.produktgruppe pg on pg.name ~ f.gruppen_regex
      join pim.artikel_gruppe ag on ag.gruppe_id = pg.id
      cross join unnest(p_sprachen) s
     where p_nur_kanal is null or ag.artikel_id in (select artikel_id from pim.shop_auswahl where kanal = p_nur_kanal)
    on conflict (artikel_id, sprache) do update set prioritaet = least(pim.text_auftrag.prioritaet, excluded.prioritaet)
    returning 1)
  select count(*) from ins
$$;

-- Fertige Shop-Texte je Artikel und Sprache
create table if not exists pim.shop_text (
  artikel_id       bigint not null references pim.artikel(id) on delete cascade,
  sprache          text not null,
  produktart       text,
  titel            text,
  kurz             text,
  body_html        text,
  technische_daten jsonb,
  technik_anzahl   integer,
  technik_uebersetzt_pct numeric(5,1),   -- Anteil Namen, die sich vom Englischen unterscheiden (Fachbegriffe wie „Motor“ zählen als gleich)
  kategorien       jsonb,
  dokumente        jsonb,
  erzeugt_am       timestamptz not null default now(),
  primary key (artikel_id, sprache)
);
alter table pim.shop_text enable row level security;

create table if not exists pim.shop_text_auftrag (
  artikel_id bigint not null,
  sprache    text not null,
  erledigt   boolean not null default false,
  primary key (artikel_id, sprache)
);
create index if not exists shop_text_auftrag_offen_idx on pim.shop_text_auftrag (sprache, artikel_id) where not erledigt;
alter table pim.shop_text_auftrag enable row level security;

create or replace function pim.shop_texte_schritt(p_paket integer default 100)
returns integer
language plpgsql
set search_path = pim, public
as $body$
declare r record; d jsonb; en jsonb; n integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  for r in select artikel_id, sprache from pim.shop_text_auftrag where not erledigt
            order by sprache, artikel_id limit p_paket for update skip locked loop
    d := pim.shop_produkt(r.artikel_id, r.sprache);
    if d is not null then
      en := case when r.sprache = 'en' then d->'technische_daten' else pim.shop_technik(r.artikel_id, 'en') end;
      insert into pim.shop_text (artikel_id, sprache, produktart, titel, kurz, body_html, technische_daten, technik_anzahl,
                                 technik_uebersetzt_pct, kategorien, dokumente, erzeugt_am)
      values (r.artikel_id, r.sprache, d->>'produktart', d->>'titel', d->>'kurz', d->>'body_html', d->'technische_daten',
              jsonb_array_length(coalesce(d->'technische_daten', '[]')),
              case when r.sprache like 'en%' then 100 else
                (select round(100.0 * count(*) filter (where x->>'name' is distinct from y->>'name') / nullif(count(*), 0), 1)
                   from jsonb_array_elements(coalesce(d->'technische_daten', '[]')) x
                   left join jsonb_array_elements(coalesce(en, '[]')) y on y->>'code' = x->>'code') end,
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
$body$;

-- ein Lauf je Minute: erst Text-Engine (Pilot zuerst), Shop-Texte, sobald die Pilot-Texte stehen
create or replace function pim.texte_takt()
returns text
language plpgsql
set search_path = pim, public
as $body$
declare a integer := 0; b integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  if exists (select 1 from pim.text_auftrag where not erledigt and prioritaet = 1) then
    a := pim.texte_schritt(250);
  else
    b := pim.shop_texte_schritt(120);
    if b = 0 then a := pim.texte_schritt(400); end if;
  end if;
  return 'textengine ' || a || ' · shoptexte ' || b;
end;
$body$;

revoke execute on function pim.shop_phrase(text, text) from public, anon, authenticated;
revoke execute on function pim.texte_auftrag_anlegen(text[], text, smallint) from public, anon, authenticated;
revoke execute on function pim.shop_texte_schritt(integer) from public, anon, authenticated;
revoke execute on function pim.texte_takt() from public, anon, authenticated;
revoke execute on function pim.texte_schritt(integer) from public, anon, authenticated;
