-- Mehrsprachiger Shop: Übersetzungen nachschlagen, technische Daten je Sprache, Kategoriebaum,
-- Ersatzteile/Zubehör als eigene Produkte, Shop-Felder je Artikel und Sprache.
--
--  pim.uebersetze()          Schlüssel ohne Groß-/Kleinschreibung und ohne führendes '/' bzw. '|'
--                            (CTF-Schlüssel sehen z. B. so aus: „/CAST IRON“, „|Kit, impeller and spacing pipe“)
--  pim.shop_technik()        + Merkmalswerte übersetzt (CTF DB_DV<MERKMAL>), Name fällt auf Englisch zurück
--  pim.shop_kategorie …      Anwendungsbaum der GPC-Datenbank (Heizung › Ein-/Zweifamilienhaus › Baureihe)
--                            mit Namen und Beschreibungen in allen Sprachen (CTF DB_APPLNAME/DB_APPLDESC)
--  pim.shop_produkt()        Titel, Beschreibung (HTML), Produktart, technische Daten je Artikel und Sprache
--  pim.shop_pilot_anlegen()  + Ersatzteile und direkt zugeordnetes Zubehör der Pilot-Pumpen

create index if not exists uebersetzung_norm_idx
  on pim.uebersetzung (bereich, sprache, (ltrim(upper(schluessel), '/|')));

create or replace function pim.uebersetze(p_bereich text, p_schluessel text, p_sprache text)
returns text
language sql stable
set search_path = pim, public
as $f$
  select ltrim(u.text, '/|') from pim.uebersetzung u
   where u.bereich = p_bereich and u.sprache = p_sprache
     and ltrim(upper(u.schluessel), '/|') = ltrim(upper(btrim(p_schluessel)), '/|')
   limit 1
$f$;

create or replace function pim.shop_technik(p_artikel bigint, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $$
  with w as (
    select distinct on (am.merkmal_code) am.merkmal_code, am.wert, m.einheit
      from pim.artikel_merkmal am
      join pim.merkmal m on m.code = am.merkmal_code
      left join pim.quelle q on q.id = am.quelle_id
     where am.artikel_id = p_artikel and coalesce(trim(am.wert), '') <> ''
       and not exists (select 1 from pim.shop_merkmal_aus x where x.code = am.merkmal_code)
     order by am.merkmal_code, (am.wert ~ '^-?[0-9]+([.,][0-9]+)?$') desc, q.prioritaet desc nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', w.merkmal_code,
           'name', coalesce(u.bezeichnung, e.bezeichnung),
           'wert', case when w.wert ~ '^-?[0-9]+([.,][0-9]+)?$' and w.einheit is not null
                             then case when p_sprache in ('en', 'en-US', 'en-IN') then w.wert
                                       else replace(w.wert, '.', ',') end || ' ' || w.einheit
                        when upper(w.wert) in ('Y', 'YES') then coalesce(initcap(pim.uebersetze('DB_DVAC_FAIL_CONTACT', 'YES', p_sprache)),   -- Ja/Nein aus einer Werteliste
                                                                         case p_sprache when 'de' then 'Ja' else 'Yes' end)
                        when upper(w.wert) in ('N', 'NO')  then coalesce(initcap(pim.uebersetze('DB_DVAC_FAIL_CONTACT', 'NO', p_sprache)),
                                                                         case p_sprache when 'de' then 'Nein' else 'No' end)
                        else coalesce(pim.uebersetze('DB_DV' || w.merkmal_code, w.wert, p_sprache), w.wert) end)
           order by coalesce(u.bezeichnung, e.bezeichnung)), '[]'::jsonb)
    from w
    left join pim.merkmal_uebersetzung u on u.merkmal_code = w.merkmal_code and u.sprache = p_sprache
                                         and u.status <> 'gesperrt'
    left join pim.merkmal_uebersetzung e on e.merkmal_code = w.merkmal_code and e.sprache = 'en'
   where coalesce(u.bezeichnung, e.bezeichnung) is not null
$$;

-- Kategoriebaum (Anwendungen) -----------------------------------------------------------------------
create table if not exists pim.shop_kategorie (
  id         bigint primary key,            -- = gpi.application.id
  parent_id  bigint references pim.shop_kategorie(id),
  code       text not null,                 -- z. B. HEATING
  sortierung integer
);
create table if not exists pim.shop_kategorie_text (
  kategorie_id bigint not null references pim.shop_kategorie(id) on delete cascade,
  sprache      text not null,
  name         text not null,
  beschreibung text,
  primary key (kategorie_id, sprache)
);
create table if not exists pim.shop_kategorie_gruppe (
  kategorie_id bigint not null references pim.shop_kategorie(id) on delete cascade,
  gruppe_id    bigint not null references pim.produktgruppe(id) on delete cascade,
  primary key (kategorie_id, gruppe_id)
);
alter table pim.shop_kategorie enable row level security;
alter table pim.shop_kategorie_text enable row level security;
alter table pim.shop_kategorie_gruppe enable row level security;

create or replace function pim.shop_kategorien_aufbauen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare n bigint;
begin
  insert into pim.shop_kategorie (id, parent_id, code, sortierung)
  select a.id::bigint, null, a.code, nullif(h.sortorder, '')::int
    from gpi.application a left join gpi.applhier h on h.id = a.id
  on conflict (id) do update set code = excluded.code, sortierung = excluded.sortierung;
  update pim.shop_kategorie k set parent_id = nullif(h.parentid, '0')::bigint
    from gpi.applhier h
   where h.id::bigint = k.id and exists (select 1 from pim.shop_kategorie p where p.id = nullif(h.parentid, '0')::bigint);
  select count(*) into n from pim.shop_kategorie;
  schritt := 'Kategorien'; anzahl := n; return next;

  insert into pim.shop_kategorie_text (kategorie_id, sprache, name, beschreibung)
  select k.id, u.sprache, u.text, pim.uebersetze('DB_APPLDESC', k.code, u.sprache)
    from pim.shop_kategorie k
    join pim.uebersetzung u on u.bereich = 'DB_APPLNAME' and u.schluessel = k.code
  on conflict (kategorie_id, sprache) do update set name = excluded.name, beschreibung = excluded.beschreibung;
  insert into pim.shop_kategorie_text (kategorie_id, sprache, name, beschreibung)
  select k.id, 'en', a.name, nullif(a.description, '')
    from pim.shop_kategorie k join gpi.application a on a.id::bigint = k.id
  on conflict (kategorie_id, sprache) do nothing;
  get diagnostics n = row_count;
  select count(*) into n from pim.shop_kategorie_text;
  schritt := 'Kategorie-Texte (alle Sprachen)'; anzahl := n; return next;

  insert into pim.shop_kategorie_gruppe (kategorie_id, gruppe_id)
  select distinct x.appl::bigint, g.id
    from (select id as appl, pgid from gpi.applpg union select applid, pgid from gpi.applareapg) x
    join pim.produktgruppe g on g.gpi_id = x.pgid
   where exists (select 1 from pim.shop_kategorie k where k.id = x.appl::bigint)
  on conflict do nothing;
  select count(*) into n from pim.shop_kategorie_gruppe;
  schritt := 'Kategorie ↔ Baureihe'; anzahl := n; return next;
end;
$body$;

-- Shop-Felder je Artikel und Sprache ----------------------------------------------------------------
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
      case p_sprache when 'de' then case v_art when 'ersatzteil' then 'Original-Grundfos-Ersatzteil' else 'Original-Grundfos-Zubehör' end
                     when 'fr' then case v_art when 'ersatzteil' then 'Pièce détachée d''origine Grundfos' else 'Accessoire d''origine Grundfos' end
                     when 'it' then case v_art when 'ersatzteil' then 'Ricambio originale Grundfos' else 'Accessorio originale Grundfos' end
                     when 'nl' then case v_art when 'ersatzteil' then 'Origineel Grundfos-reserveonderdeel' else 'Origineel Grundfos-toebehoren' end
                     when 'pl' then case v_art when 'ersatzteil' then 'Oryginalna część zamienna Grundfos' else 'Oryginalne akcesorium Grundfos' end
                     else case v_art when 'ersatzteil' then 'Genuine Grundfos spare part' else 'Genuine Grundfos accessory' end end
        || coalesce(': ' || coalesce(v_name, v_name_en), '') || ' (' || a.artikelnummer || ').',
      case when v_passt is not null then
        case p_sprache when 'de' then 'Passend für: ' when 'fr' then 'Compatible avec : ' when 'it' then 'Adatto per: '
                       when 'nl' then 'Geschikt voor: ' when 'pl' then 'Pasuje do: ' else 'Suitable for: ' end || v_passt end);
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

-- Pilot um Ersatzteile und direktes Zubehör der Pilot-Pumpen erweitern
create or replace function pim.shop_pilot_teile_anlegen(p_kanal text default 'mastershop_pilot')
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare
  n bigint;
  v_max integer := (select coalesce(max(rang), 0) from pim.shop_auswahl where kanal = p_kanal);
begin
  insert into pim.shop_auswahl (kanal, artikel_id, grund, rang)
  select p_kanal, x.id, x.grund, v_max + row_number() over (order by x.grund, x.id)
    from (
      select distinct on (b.zu_artikel_id) b.zu_artikel_id as id, 'Ersatzteil' as grund
        from pim.shop_auswahl s join pim.artikel_beziehung b on b.von_artikel_id = s.artikel_id and b.typ = 'ersatzteil'
       where s.kanal = p_kanal and s.grund not in ('Ersatzteil', 'Zubehör')
      union
      select distinct z.zubehoer_artikel_id, 'Zubehör'
        from pim.shop_auswahl s, pim.zubehoer(s.artikel_id, 1000) z
       where s.kanal = p_kanal and s.grund not in ('Ersatzteil', 'Zubehör') and z.art = 'Artikel'
    ) x
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$body$;

revoke execute on function pim.shop_kategorien_aufbauen() from public, anon, authenticated;
revoke execute on function pim.shop_produkt(bigint, text) from public, anon, authenticated;
revoke execute on function pim.shop_pilot_teile_anlegen(text) from public, anon, authenticated;

-- Export-Ansicht: Titel/Beschreibung/technische Daten jetzt aus pim.shop_produkt() (Pumpe, Ersatzteil, Zubehör),
-- neu am Ende: Produktart, passende Pumpen, Bilder und Dokumente (sobald hochgeladen), Shop-Kategorien
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
       (select coalesce(jsonb_agg(m.extern_url order by am.sortierung nulls last, m.id), '[]')
          from pim.artikel_medium am join pim.medium m on m.id = am.medium_id
         where am.artikel_id = g.id and m.typ = 'bild' and m.extern_url is not null) as bilder,
       (select coalesce(jsonb_agg(jsonb_build_object('typ', m.typ, 'titel', coalesce(m.titel, m.dateiname),
                                                      'sprache', m.sprache, 'url', m.extern_url)), '[]')
          from (select distinct m.id, m.typ, m.titel, m.dateiname, m.sprache, m.extern_url
                  from pim.medium m
                  left join pim.artikel_medium am on am.medium_id = m.id and am.artikel_id = g.id
                  left join pim.gruppe_medium gm on gm.medium_id = m.id
                       and gm.gruppe_id in (select ag.gruppe_id from pim.artikel_gruppe ag where ag.artikel_id = g.id)
                 where (am.artikel_id is not null or gm.gruppe_id is not null)
                   and m.typ <> 'bild' and m.extern_url is not null
                   and (m.sprache is null or m.sprache in ('de', 'en'))
                 limit 60) m) as dokumente,
       (select coalesce(jsonb_agg(distinct coalesce(tp.name || ' > ', '') || t.name), '[]')
          from pim.artikel_gruppe ag
          join pim.produktgruppe ga on ga.id = ag.gruppe_id
          join pim.produktgruppe gk on ga.baum like gk.baum || '%'          -- Anwendung hängt oft an der Familie
          join pim.shop_kategorie_gruppe kg on kg.gruppe_id = gk.id
          join pim.shop_kategorie k on k.id = kg.kategorie_id
          join pim.shop_kategorie_text t on t.kategorie_id = k.id and t.sprache = 'de'
          left join pim.shop_kategorie_text tp on tp.kategorie_id = k.parent_id and tp.sprache = 'de'
         where ag.artikel_id = g.id and k.code not in ('GENERAL')) as kategorien
  from pim.shop_auswahl s
  join pim.v_artikel_de g on g.id = s.artikel_id
  cross join lateral (select pim.shop_produkt(g.id, 'de') as d) p
  left join pim.artikel_qualitaet q on q.artikel_id = s.artikel_id;
