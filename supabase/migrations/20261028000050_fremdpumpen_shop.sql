-- Pumpen weiterer Hersteller als eigene Shop-Produkte (28.10.2026)
--
-- Wunsch: Fremdpumpen (u. a. EOL-Lagerware) mit eigenem Produkttext listen – ohne Verweis auf einen Grundfos-Ersatz.
-- Quelle: pim.fremdprodukt (Grundfos Product Center 2023, Schnellaustausch: Typ, Baureihe, technische Daten je Variante).
--
--  pim.fremd_hersteller   Hersteller im Shop + Anzeigename (z. B. „BIRAL (BIERI, HOVAL)“ → „Biral“)
--  pim.fremd_serie        Baureihe je Hersteller → Pumpenart (Kategorie-Code), Anzeigename der Baureihe
--  pim.fremd_serie_schluessel(...)   Baureihenschlüssel einer Variante (Flygt/e-SV/CDL: Baureihe, sonst Präfix des Typs)
--  pim.fremd_shop         Shop-Varianten (exakte Dubletten entfernt, Name, Titelzusatz) – pim.fremd_shop_aufbauen()
--  pim.shop_fremd_technik(id, sprache)   technische Daten mit übersetzten Namen/Werten (Merkmalsstamm + Fachwörterbuch)
--  pim.shop_fremd_produkt(id, sprache)   Titel, Kurztext, Beschreibung (HTML), Kategorien, technische Daten
--  pim.shop_fremd_text / pim.shop_fremd_auftrag / pim.shop_fremd_schritt(n)   fertige Texte je Sprache (per pg_cron)
-- Texte aus Bausteinen (pim.shop_phrase, Schlüssel fremd_*); Angaben ausschließlich aus den Produktdaten.

create or replace function pim.html(t text)
returns text
language sql immutable
as $$ select replace(replace(replace(t, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') $$;

create table if not exists pim.fremd_hersteller (
  hersteller text primary key,
  anzeige    text not null,
  im_shop    boolean not null default true
);
alter table pim.fremd_hersteller enable row level security;
insert into pim.fremd_hersteller (hersteller, anzeige) values
  ('KSB', 'KSB'), ('WILO', 'Wilo'), ('BIRAL (BIERI, HOVAL)', 'Biral'), ('LOWARA', 'Lowara'), ('SALMSON', 'Salmson'),
  ('EMB', 'EMB'), ('NANFANG', 'Nanfang'), ('FLYGT', 'Flygt')
on conflict (hersteller) do nothing;

create table if not exists pim.fremd_serie (
  hersteller    text not null,
  serie         text not null,
  kategorie     text not null default 'pumpe',
  sicher        text,
  serie_anzeige text,
  primary key (hersteller, serie)
);
alter table pim.fremd_serie enable row level security;

create or replace function pim.fremd_serie_schluessel(p_hersteller text, p_typ text, p_baureihe text, p_baureihe_code text)
returns text
language sql immutable
as $$
  select case when p_hersteller = 'FLYGT' then p_baureihe
              when p_baureihe_code in ('ESVFAM', 'CDLFAM') then p_baureihe
              -- KSB „22-2 E (Riovar)“: Baureihe steht in Klammern am Ende
              when p_hersteller = 'KSB' and p_typ ~ '\(\s*(Rio|Rovi|Eta|Calio)[A-Za-z-]*[^)]*\)\s*$'
                then substring(p_typ from '\(\s*((Rio|Rovi|Eta|Calio)[A-Za-z-]*)[^)]*\)\s*$')
              else coalesce(substring(regexp_replace(p_typ, '^\(Star\)\s*', 'Star ') from '[A-Za-z][A-Za-z-]*'), p_typ) end
$$;

-- Shop-Varianten: exakte Dubletten entfernt; name = Typbezeichnung aus „typ“ (PRODNAME in den Daten ist bei KSB/Lowara gegenüber
-- den technischen Daten verrutscht, z. B. Lowara-Anschluss passt zum Typ-Suffix T/C/V/F, nicht zu PRODNAME → nicht verwenden);
-- zusatz = Merkmale, die gleich benannte Varianten unterscheiden (für den Titel, je Sprache formatiert)
create table if not exists pim.fremd_shop (
  id                 bigint primary key references pim.fremdprodukt(id) on delete cascade,
  hersteller         text not null,
  hersteller_anzeige text not null,
  serie              text,
  name               text not null,
  frequenz           smallint,
  zusatz             jsonb not null default '[]',
  unterscheidung     text not null default ''     -- Werte der Zusatz-Merkmale (Hilfsspalte für den Aufbau)
);
alter table pim.fremd_shop add column if not exists unterscheidung text not null default '';
alter table pim.fremd_shop enable row level security;

create or replace function pim.fremd_name(p_hersteller text, p_typ text)
returns text
language sql immutable
as $$
  select btrim(regexp_replace(case when p_hersteller = 'KSB' and p_typ ~ '\(\s*(Rio|Rovi|Eta|Calio)[A-Za-z-]*[^)]*\)\s*$'   -- „22-2 E (Riovar)“ → „Riovar 22-2 E“
                                   then substring(p_typ from '\(([^)]*)\)\s*$') || ' ' || regexp_replace(p_typ, '\s*\([^)]*\)\s*$', '')
                                   else p_typ end, '\s+', ' ', 'g'))
$$;

create or replace function pim.fremd_wert(p_daten jsonb, p_code text)
returns text
language sql immutable
as $$
  select case when p_code = 'ELEKTRIK'
              then nullif(coalesce(nullif(btrim(p_daten->'PHASE'->>'wert'), '') || '~', '')
                          || coalesce(nullif(btrim(p_daten->'U'->>'wert'), '') || ' V', ''), '')
              else nullif(btrim(p_daten->p_code->>'wert'), '') end
$$;

-- Vergleichsform eines Werts: „18,5“ = „18.5“, „DN125“ = „DN 125“
create or replace function pim.fremd_norm(t text)
returns text
language sql immutable
as $$ select lower(regexp_replace(replace(t, ',', '.'), '\s', '', 'g')) $$;

create or replace function pim.fremd_shop_aufbauen()
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare k text; n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  truncate pim.fremd_shop;
  insert into pim.fremd_shop (id, hersteller, hersteller_anzeige, serie, name, frequenz)
  select id, hersteller, anzeige, pim.fremd_serie_schluessel(hersteller, typ, baureihe, baureihe_code), name, frequenz
    from (select f.*, h.anzeige,
                 pim.fremd_name(f.hersteller, f.typ) as name,
                 row_number() over (partition by f.hersteller, f.typ, f.frequenz,   -- „18,5“ und „18.5“ gelten als gleich
                                    regexp_replace((f.daten - '_schnellaustausch_id')::text, '(\d),(\d)', '\1.\2', 'g') order by f.id) nr
            from pim.fremdprodukt f join pim.fremd_hersteller h on h.hersteller = f.hersteller and h.im_shop) x
   where nr = 1;
  -- gleich benannte Varianten nacheinander über die aussagekräftigsten abweichenden Merkmale unterscheiden
  foreach k in array array['ELEKTRIK', 'P2KW56', 'P1WMAX', 'IMPELNOM', 'STAGE', 'PIPECON', 'PIPEPRES', 'PORTPORT', 'N56', 'IMPELCOD',
                           'SHAFTSEAL', 'MATPUMPH', 'MATIM', 'PIPESTD', 'INSDRYWET', 'COOLINGJ', 'EXPUMPS1', 'IMPELTYPE'] loop
    update pim.fremd_shop t set zusatz = t.zusatz || to_jsonb(k),
                                unterscheidung = t.unterscheidung || '|' || coalesce(pim.fremd_norm(pim.fremd_wert(f.daten, k)), '')
      from pim.fremdprodukt f,
           (select s.hersteller, s.name, s.frequenz, s.unterscheidung
              from pim.fremd_shop s join pim.fremdprodukt f on f.id = s.id
             group by 1, 2, 3, 4
            having count(*) > 1 and count(distinct coalesce(pim.fremd_norm(pim.fremd_wert(f.daten, k)), '')) > 1) g
     where f.id = t.id and g.hersteller = t.hersteller and g.name = t.name and g.frequenz is not distinct from t.frequenz
       and g.unterscheidung = t.unterscheidung;
  end loop;
  update pim.fremd_shop t set zusatz = t.zusatz || '"NR"'::jsonb
    from (select hersteller, name, frequenz, unterscheidung from pim.fremd_shop group by 1, 2, 3, 4 having count(*) > 1) g
   where g.hersteller = t.hersteller and g.name = t.name and g.frequenz is not distinct from t.frequenz
     and g.unterscheidung = t.unterscheidung;
  select count(*) into n from pim.fremd_shop;
  return n;
end;
$body$;
revoke execute on function pim.fremd_shop_aufbauen() from public, anon, authenticated;

drop view if exists pim.v_fremd_shop;
select pim.fremd_shop_aufbauen();
-- Texte von Varianten, die keine Shop-Variante (mehr) sind, entfernen
delete from pim.shop_fremd_text t where not exists (select 1 from pim.fremd_shop s where s.id = t.fremd_id);
delete from pim.shop_fremd_auftrag a where not exists (select 1 from pim.fremd_shop s where s.id = a.fremd_id);

-- Technische Daten: Name aus dem Merkmalsstamm (Sprache → en → Name im Datensatz), Wert übersetzt bzw. mit Einheit
create or replace function pim.shop_fremd_technik(p_id bigint, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $$
  with w as (
    select d.key code, btrim(d.value->>'wert') wert, d.value->>'name' name_quelle,
           coalesce(m.einheit, case d.value->>'einheit' when 'dgr C' then '°C' when 'm3/h' then 'm³/h' when 'rpm' then '1/min'
                                                       else nullif(d.value->>'einheit', '') end) einheit
      from pim.fremdprodukt f
      cross join jsonb_each(f.daten) d
      left join pim.merkmal m on m.code = d.key
     where f.id = p_id and d.key !~ '^_' and d.key not in ('PRODNAME', 'COMB_PRODUCT_NAME', 'PUMPTYPE2')
       and jsonb_typeof(d.value) = 'object' and coalesce(btrim(d.value->>'wert'), '') <> ''
       and not exists (select 1 from pim.shop_merkmal_aus x where x.code = d.key)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', w.code,
           'name', coalesce(u.bezeichnung, e.bezeichnung, w.name_quelle),
           'wert', case when w.einheit in ('AISI', 'ASTM', 'DIN W.-Nr.') then w.einheit || ' ' || w.wert
                        when w.wert ~ '^-?[0-9]+([.,][0-9]+)?(\s*[/-]\s*-?[0-9]+([.,][0-9]+)?)*$' and w.einheit is not null   -- auch 400/230
                             then case when p_sprache like 'en%' then w.wert else replace(w.wert, '.', ',') end || ' ' || w.einheit
                        when upper(w.wert) in ('Y', 'YES') then coalesce(initcap(pim.uebersetze('DB_DVAC_FAIL_CONTACT', 'YES', p_sprache)),
                                                                         case p_sprache when 'de' then 'Ja' else 'Yes' end)
                        when upper(w.wert) in ('N', 'NO')  then coalesce(initcap(pim.uebersetze('DB_DVAC_FAIL_CONTACT', 'NO', p_sprache)),
                                                                         case p_sprache when 'de' then 'Nein' else 'No' end)
                        else coalesce(pim.uebersetze('DB_DV' || w.code, w.wert, p_sprache), w.wert) end)
           order by coalesce(u.bezeichnung, e.bezeichnung, w.name_quelle)), '[]'::jsonb)
    from w
    left join pim.merkmal_uebersetzung u on u.merkmal_code = w.code and u.sprache = p_sprache and u.status <> 'gesperrt'
    left join pim.merkmal_uebersetzung e on e.merkmal_code = w.code and e.sprache = 'en'
$$;

create or replace function pim.shop_fremd_produkt(p_id bigint, p_sprache text default 'de')
returns jsonb
language plpgsql stable
set search_path = pim, public
as $body$
declare
  f record;
  s record;
  v_kat text;
  v_technik jsonb;
  v_eck text;
  v_zusatz text;
begin
  select s0.*, p.daten, p.produktnummer into f from pim.fremd_shop s0 join pim.fremdprodukt p on p.id = s0.id where s0.id = p_id;
  if not found then return null; end if;
  select * into s from pim.fremd_serie where hersteller = f.hersteller and serie = f.serie;
  v_kat := pim.shop_phrase('fremd_kat_' || coalesce(s.kategorie, 'pumpe'), p_sprache);
  v_technik := pim.shop_fremd_technik(p_id, p_sprache);

  -- Titelzusatz: unterscheidende Merkmale (Werte wie in den technischen Daten der Sprache), sonst Variantennummer
  select string_agg(' – ' || case when z = 'ELEKTRIK' then pim.fremd_wert(f.daten, 'ELEKTRIK')
                                  when z = 'NR' then f.produktnummer
                                  when z = 'IMPELNOM' then 'Ø ' || (e->>'wert')
                                  when (f.daten->z->>'einheit') is not null or z in ('P2KW56', 'P1WMAX', 'PORTPORT', 'N56') then e->>'wert'
                                  else (e->>'name') || ' ' || (e->>'wert') end, '' order by o)
    into v_zusatz
    from jsonb_array_elements_text(f.zusatz) with ordinality zz(z, o)
    left join lateral (select x from jsonb_array_elements(v_technik) x where x->>'code' = zz.z limit 1) t(e) on true
   where z in ('ELEKTRIK', 'NR') or e is not null;

  with t as (select e, array_position(array['PIPECON', 'PORTPORT', 'PIPESTD', 'PIPEPRES', 'PHASE', 'U', 'P1WMAX', 'P2KW56', 'N56',
                                             'FLOWNOM56', 'HEADNOM56', 'HEADMAXM', 'FLOWMAX', 'PMAXBAR', 'STAGE', 'MATPUMPH', 'MATIM',
                                             'WEIGHTNET'], e->>'code') pos
               from jsonb_array_elements(v_technik) e)
  select '<h3>' || pim.shop_phrase('wichtige_daten', p_sprache) || '</h3>' || E'\n<ul>' ||
         string_agg('<li>' || pim.html(e->>'name') || ': ' || pim.html(e->>'wert') || '</li>', '' order by pos) || '</ul>'
    into v_eck
    from (select * from t where pos is not null order by pos limit 10) x
  having count(*) > 0;

  return jsonb_build_object(
    'sprache', p_sprache,
    'sku', f.produktnummer || case when f.frequenz = 60 then '-60HZ' else '' end,   -- gleiche Nummer für 50/60 Hz
    'hersteller', f.hersteller_anzeige,
    'typ', f.name,
    'frequenz', f.frequenz,
    'produktart', 'fremdpumpe',
    'serie', coalesce(s.serie_anzeige, f.serie),
    'titel', f.hersteller_anzeige || ' ' || f.name || coalesce(v_zusatz, '') || case when f.frequenz = 60 then ' (60 Hz)' else '' end,
    'kurz', v_kat,
    'body_html', concat_ws(E'\n',
       '<p>' || pim.html(concat_ws(' ',
                  replace(replace(replace(pim.shop_phrase('fremd_einleitung', p_sprache), '{hersteller}', f.hersteller_anzeige),
                                  '{typ}', f.name), '{kategorie}', v_kat),
                  case when coalesce(s.serie_anzeige, f.serie) is not null and coalesce(s.serie_anzeige, f.serie) <> f.name
                       then replace(pim.shop_phrase('fremd_baureihe', p_sprache), '{serie}', coalesce(s.serie_anzeige, f.serie)) end,
                  replace(pim.shop_phrase('fremd_original', p_sprache), '{hersteller}', f.hersteller_anzeige))) || '</p>',
       v_eck,
       '<p>' || pim.html(pim.shop_phrase('fremd_typenschild', p_sprache)) || '</p>'),
    'kategorien', jsonb_build_array(concat_ws(' > ', pim.shop_phrase('kategorie_fremd', p_sprache), f.hersteller_anzeige,
                                              coalesce(s.serie_anzeige, f.serie))),
    'technische_daten', v_technik);
end;
$body$;

create table if not exists pim.shop_fremd_text (
  fremd_id         bigint not null references pim.fremdprodukt(id) on delete cascade,
  sprache          text not null,
  sku              text,
  hersteller       text,
  titel            text,
  kurz             text,
  body_html        text,
  kategorien       jsonb,
  technische_daten jsonb,
  erzeugt_am       timestamptz not null default now(),
  primary key (fremd_id, sprache)
);
alter table pim.shop_fremd_text enable row level security;

create table if not exists pim.shop_fremd_auftrag (
  fremd_id bigint not null,
  sprache  text not null,
  erledigt boolean not null default false,
  primary key (fremd_id, sprache)
);
alter table pim.shop_fremd_auftrag enable row level security;
create index if not exists shop_fremd_auftrag_offen_idx on pim.shop_fremd_auftrag (sprache, fremd_id) where not erledigt;

create or replace function pim.shop_fremd_schritt(p_paket integer default 500)
returns integer
language plpgsql
set search_path = pim, public
as $body$
declare r record; d jsonb; n integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  for r in select fremd_id, sprache from pim.shop_fremd_auftrag where not erledigt
            order by sprache, fremd_id limit p_paket for update skip locked loop
    d := pim.shop_fremd_produkt(r.fremd_id, r.sprache);
    if d is not null then
      insert into pim.shop_fremd_text (fremd_id, sprache, sku, hersteller, titel, kurz, body_html, kategorien, technische_daten, erzeugt_am)
      values (r.fremd_id, r.sprache, d->>'sku', d->>'hersteller', d->>'titel', d->>'kurz', d->>'body_html', d->'kategorien',
              d->'technische_daten', now())
      on conflict (fremd_id, sprache) do update set sku = excluded.sku, hersteller = excluded.hersteller, titel = excluded.titel,
             kurz = excluded.kurz, body_html = excluded.body_html, kategorien = excluded.kategorien,
             technische_daten = excluded.technische_daten, erzeugt_am = now();
    end if;
    update pim.shop_fremd_auftrag set erledigt = true where fremd_id = r.fremd_id and sprache = r.sprache;
    n := n + 1;
  end loop;
  return n;
end;
$body$;

revoke execute on function pim.shop_fremd_technik(bigint, text) from public, anon, authenticated;
revoke execute on function pim.shop_fremd_produkt(bigint, text) from public, anon, authenticated;
revoke execute on function pim.shop_fremd_schritt(integer) from public, anon, authenticated;
