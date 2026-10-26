-- Shop-Export (neuer Grundfos-Mastershop, Shopify). Erst Pilot, Status „Entwurf“, ohne Preise und ohne Bilder
-- (Preise: noch keine Entscheidung; Bilder/Dokumente: Nutzungsrechte offen).
--
--  pim.shop_auswahl        welche Artikel in welchen Kanal (Pilot: ~500 Artikel DE)
--  pim.shop_technik()      technische Daten je Artikel und Sprache: ein Wert je Merkmal, Name aus merkmal_uebersetzung
--  pim.text_html()         Text-Engine-/DATANORM-Text → HTML (>> Überschrift, >>> Unterüberschrift, sonst Absatz)
--  pim.v_shop_export_de    eine Zeile je Produkt mit allen Shopify-Feldern + Metafeldern (Ersatzteile, Zubehör,
--                          Nachfolger, Wettbewerbs-Austausch); tools/export/shopify_export.py schreibt daraus die CSV

create table if not exists pim.shop_auswahl (
  kanal      text not null,              -- z. B. 'mastershop_pilot'
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  grund      text,
  rang       integer,
  primary key (kanal, artikel_id)
);
alter table pim.shop_auswahl enable row level security;

-- Merkmale, die nicht als technische Daten ins Produkt gehören (Dateiverweise, interne Steuerung)
create table if not exists pim.shop_merkmal_aus (code text primary key);
alter table pim.shop_merkmal_aus enable row level security;
insert into pim.shop_merkmal_aus values
  ('DRAWDIM'), ('DRAWELC'), ('PRODPIC'), ('QTTXT'), ('SALESREG'), ('MODEL'), ('PRODNAME'), ('COMB_PRODUCT_NAME'),
  ('CURVESET'), ('SERVICE'), ('INSTOPER'), ('PUMPTYPE2'), ('PRODNO'), ('EANNO'), ('PRICE')
on conflict do nothing;

create or replace function pim.shop_technik(p_artikel bigint, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $$
  with w as (
    select distinct on (am.merkmal_code) am.merkmal_code, am.wert, am.wert_num, m.einheit
      from pim.artikel_merkmal am
      join pim.merkmal m on m.code = am.merkmal_code
      left join pim.quelle q on q.id = am.quelle_id
     where am.artikel_id = p_artikel and coalesce(trim(am.wert), '') <> ''
       and not exists (select 1 from pim.shop_merkmal_aus x where x.code = am.merkmal_code)
     order by am.merkmal_code,
              (am.wert ~ '^-?[0-9]+([.,][0-9]+)?$') desc,                  -- reine Zahl vor „0 .. 40 Grad C“
              q.prioritaet desc nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', w.merkmal_code,
           'name', u.bezeichnung,
           'wert', case when w.wert ~ '^-?[0-9]+([.,][0-9]+)?$' and w.einheit is not null
                             then replace(w.wert, '.', ',') || ' ' || w.einheit
                        when upper(w.wert) in ('Y', 'YES') then case p_sprache when 'de' then 'Ja' else 'Yes' end
                        when upper(w.wert) in ('N', 'NO') then case p_sprache when 'de' then 'Nein' else 'No' end
                        else w.wert end)
           order by u.bezeichnung), '[]'::jsonb)
    from w
    join pim.merkmal_uebersetzung u on u.merkmal_code = w.merkmal_code and u.sprache = p_sprache
   where u.status <> 'gesperrt'
$$;

create or replace function pim.text_html(t text)
returns text
language sql immutable
as $$
  select string_agg(case
           when z ~ '^>>>' then '<h4>' || replace(replace(btrim(substr(z, 4)), '&', '&amp;'), '<', '&lt;') || '</h4>'
           when z ~ '^>>'  then '<h3>' || replace(replace(btrim(substr(z, 3)), '&', '&amp;'), '<', '&lt;') || '</h3>'
           else '<p>' || replace(replace(btrim(z), '&', '&amp;'), '<', '&lt;') || '</p>' end, E'\n' order by n)
    from regexp_split_to_table(coalesce(t, ''), E'\n') with ordinality s(z, n)
   where btrim(z) <> ''
$$;

create or replace function pim.shop_pilot_anlegen(p_kanal text default 'mastershop_pilot')
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare n bigint;
begin
  delete from pim.shop_auswahl where kanal = p_kanal;
  insert into pim.shop_auswahl (kanal, artikel_id, grund, rang)
  select p_kanal, artikel_id, grund, row_number() over (order by prio, rang, artikel_id)
    from (
      -- 1. Bestseller Deutschland (Grundfos „Popular now“)
      select b.artikel_id, 'Bestseller DE #' || b.rang as grund, 1 as prio, b.rang
        from pim.artikel_beliebt b where b.markt = 'DE'
      union all
      -- 2. Heizungs-/Zirkulationspumpen im DE-Sortiment 2023, Score ≥ 80
      select ag.artikel_id, 'Heizung: ' || g.name, 2, 0
        from pim.artikel_gruppe ag
        join pim.produktgruppe g on g.id = ag.gruppe_id and g.name ~* '^(ALPHA|MAGNA|UPS|UPM|COMFORT)'
        join pim.artikel_qualitaet q on q.artikel_id = ag.artikel_id and q.punkte >= 80
       where exists (select 1 from pim.artikel_markt m
                      where m.artikel_id = ag.artikel_id and m.markt = 'DE' and m.quelle_id =
                            (select id from pim.quelle where typ = 'gpc2023' limit 1))
      union all
      -- 3. je Baureihe die 15 besten Artikel im DE-Sortiment 2023 (alle Text-Engine-Familien + Abwasser/Haus)
      select artikel_id, 'Baureihe: ' || name, 3, r
        from (select ag.artikel_id, g.name,
                     row_number() over (partition by f.fam order by q.punkte desc, ag.artikel_id) as r
                from (values ('CR', '^CR( |$)'), ('CRE', '^CRE( |$)'), ('CM', '^CM( |$)'), ('CME', '^CME( |$)'),
                             ('SP', '^SP( |$)'), ('SQ', '^SQ( |E|$)'), ('SCALA', '^SCALA'), ('Sololift', '^Sololift'),
                             ('Unilift', '^Unilift'), ('Conlift', '^Conlift'), ('Multilift', '^Multilift'),
                             ('MTR', '^MTR( |$)'), ('NB', '^NB( |$)'), ('NK', '^NK( |$)'), ('NKG', '^NKG( |$)'),
                             ('TP', '^TP( |$)'), ('TPE', '^TPE'), ('SEG', '^SEG'), ('DDE', '^DD[AEC]'),
                             ('Hydro MPC', '^Hydro MPC'), ('Hydro Multi-E', '^Hydro Multi-E'), ('JP', '^JP( |$)')
                     ) f(fam, rx)
                join pim.produktgruppe g on g.name ~ f.rx
                join pim.artikel_gruppe ag on ag.gruppe_id = g.id
                join pim.artikel_qualitaet q on q.artikel_id = ag.artikel_id and q.punkte >= 80
               where exists (select 1 from pim.artikel_markt m
                              where m.artikel_id = ag.artikel_id and m.markt = 'DE' and m.quelle_id =
                                    (select id from pim.quelle where typ = 'gpc2023' limit 1))) x
       where r <= 15
    ) a
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$body$;

create or replace view pim.v_shop_export_de with (security_invoker = true) as
select s.kanal, s.rang, s.grund,
       g.id as artikel_id, g.artikelnummer, g.ean, g.typbezeichnung, g.produktgruppe,
       lower(regexp_replace(regexp_replace('grundfos-' || coalesce(g.typbezeichnung, '') || '-' || g.artikelnummer,
                                           '[^A-Za-z0-9]+', '-', 'g'), '(^-|-$)', '', 'g')) as handle,
       btrim('Grundfos ' || coalesce(regexp_replace(g.typbezeichnung, '^GRUNDFOS\s+', '', 'i'), g.artikelnummer)
             || coalesce(' – ' || nullif(btrim(regexp_replace(g.kurz1, '^GRUNDFOS\s+', '', 'i')), ''), '')) as titel,
       concat_ws(E'\n',
                 pim.text_html(coalesce(g.lang, g.beschreibung)),
                 case when g.technik is not null and g.lang is not null then pim.text_html(g.technik) end) as body_html,
       g.kurz1, g.kurz2,
       (select round(am.wert_num * 1000) from pim.artikel_merkmal am
         where am.artikel_id = g.id and am.merkmal_code = 'WEIGHTGRS' and am.wert_num > 0 limit 1) as gramm,
       pim.shop_technik(g.id, 'de') as technische_daten,
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
          union all select 'Bestseller' where s.grund like 'Bestseller%'
          union all select 'Text: maschinell' where g.lang is null and g.beschreibung is not null) t
         where x is not null) as tags,
       q.punkte as score
  from pim.shop_auswahl s
  join pim.v_artikel_de g on g.id = s.artikel_id
  left join pim.artikel_qualitaet q on q.artikel_id = s.artikel_id;

revoke execute on function pim.shop_technik(bigint, text) from public, anon, authenticated;
revoke execute on function pim.shop_pilot_anlegen(text) from public, anon, authenticated;
