-- Fachbegriffe in der Suche: „Heizungspumpe“, „Brunnenpumpe“, „Hebeanlage“ … → passende Grundfos-Baureihen.
-- Erweiterbar je Sprache (pim.suchbegriff); Treffer werden nach Qualitäts-Score sortiert.
-- Spannungsangaben in der Eingabe („Brunnenpumpe 230V“) filtern auf das Merkmal U, auch bei Bereichen
-- wie „220-230“ oder „380-400-415“.

-- Liegt die Zahl x im Wertebereich „a-b-c“ / „1 x 220-240“ (oder ist gleich a)?
create or replace function pim.im_bereich(wert text, x numeric)
returns boolean
language sql immutable
set search_path = pim, public
as $$
  -- erste und letzte Zahl bilden den Bereich („1 x 220-240“ → Phasen-Präfix wird übersprungen)
  with w as (select regexp_replace(coalesce(wert, ''), '^\s*\d\s*x\s*', '', 'i') as t)
  select coalesce(x between substring(t from '(\d+)')::numeric
                        and substring(t from '(\d+)\D*$')::numeric, false)
    from w
$$;

-- Vorberechnete elektrische Eckdaten je Artikel (für schnelle Filter wie „230V“)
create table if not exists pim.artikel_elektrik (
  artikel_id bigint primary key references pim.artikel(id) on delete cascade,
  u_min numeric, u_max numeric, phase smallint
);
create index if not exists artikel_elektrik_u_idx on pim.artikel_elektrik (u_min, u_max);
alter table pim.artikel_elektrik enable row level security;

create or replace function pim.elektrik_berechnen()
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  insert into pim.artikel_elektrik (artikel_id, u_min, u_max, phase)
  select artikel_id,
         min(substring(regexp_replace(wert, '^\s*\d\s*x\s*', '', 'i') from '(\d+)')::numeric)
           filter (where merkmal_code = 'U'),
         max(substring(regexp_replace(wert, '^\s*\d\s*x\s*', '', 'i') from '(\d+)\D*$')::numeric)
           filter (where merkmal_code = 'U'),
         max(wert_num) filter (where merkmal_code = 'PHASE')::smallint
    from pim.artikel_merkmal
   where merkmal_code in ('U', 'PHASE')   -- Spannungen sind ganzzahlig („230,50“ = 230 V, 50 Hz)
   group by artikel_id
  on conflict (artikel_id) do update set u_min = excluded.u_min, u_max = excluded.u_max, phase = excluded.phase;
  get diagnostics n = row_count;
  return n;
end;
$body$;
revoke execute on function pim.elektrik_berechnen() from public, anon, authenticated;

create table if not exists pim.suchbegriff (
  begriff      text not null,             -- Kleinbuchstaben, z. B. 'heizungspumpe'
  sprache      text not null default 'de',
  gruppen_regex text not null,            -- Regex auf pim.produktgruppe.name
  primary key (begriff, sprache)
);
alter table pim.suchbegriff enable row level security;

insert into pim.suchbegriff (begriff, sprache, gruppen_regex) values
  ('heizungspumpe', 'de', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML)'),
  ('umwälzpumpe', 'de', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML|COMFORT)'),
  ('umwaelzpumpe', 'de', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML|COMFORT)'),
  ('nassläufer', 'de', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML|COMFORT)'),
  ('zirkulationspumpe', 'de', '^(COMFORT|UP .*N|ALPHA.*N)'),
  ('warmwasserpumpe', 'de', '^(COMFORT|UP .*N|ALPHA.*N)'),
  ('brunnenpumpe', 'de', '^(SP|SQ|SQE|SQFlex|MS ?\d|MP ?1)'),
  ('unterwasserpumpe', 'de', '^(SP|SQ|SQE|SQFlex|MS ?\d|MP ?1)'),
  ('tiefbrunnenpumpe', 'de', '^(SP|SQ|SQE|SQFlex)'),
  ('tauchpumpe', 'de', '^(Unilift|KP|AP|DP|EF|SEG|SL|SE|SPO)'),
  ('schmutzwasserpumpe', 'de', '^(Unilift|AP|DP|EF|SEG|SL|SE)'),
  ('kellerentwässerung', 'de', '^(Unilift|KP|CC)'),
  ('drainagepumpe', 'de', '^(Unilift|KP|AP|DP)'),
  ('hebeanlage', 'de', '^(Sololift|Multilift|Conlift|PUST|Liftaway)'),
  ('abwasserhebeanlage', 'de', '^(Sololift|Multilift|PUST|Liftaway)'),
  ('fäkalienhebeanlage', 'de', '^(Sololift|Multilift)'),
  ('kondensatpumpe', 'de', '^Conlift'),
  ('druckerhöhung', 'de', '^(Hydro|CMB|MQ|SCALA|JP|CME for|CR/E/IE for)'),
  ('druckerhöhungsanlage', 'de', '^(Hydro|CMB|CME for|CR/E/IE for)'),
  ('hauswasserwerk', 'de', '^(MQ|SCALA|JP|Hydrojet|CMB)'),
  ('mehrstufige kreiselpumpe', 'de', '^(CR|CM|CMV|MTH|MTR|MTA)'),
  ('hochdruckpumpe', 'de', '^(CR|CM|CMV|MTH|MTR|BM)'),
  ('normpumpe', 'de', '^(NB|NK|NBE|NKE|NM|NP)'),
  ('blockpumpe', 'de', '^(NB|NBE|TP|TPE)'),
  ('inlinepumpe', 'de', '^(TP|TPE|LM|LP)'),
  ('dosierpumpe', 'de', '^(DD|DM|DMX|DMH|DME|Smart Digital)'),
  ('solarpumpe', 'de', '^(SQFlex|Solar)'),
  ('feuerlöschpumpe', 'de', '^(AEF|PVF|HS|Fire)'),
  ('heating circulator', 'en', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML)'),
  ('circulator', 'en', '^(ALPHA|UPS|UPE|MAGNA|UPM|UPML|COMFORT)'),
  ('borehole pump', 'en', '^(SP|SQ|SQE|SQFlex)'),
  ('submersible pump', 'en', '^(SP|SQ|SQE|Unilift|AP|DP|EF|SEG|SL|SE)'),
  ('booster', 'en', '^(Hydro|CMB|MQ|SCALA|CME for|CR/E/IE for)'),
  ('lifting station', 'en', '^(Sololift|Multilift|Conlift|PUST|Liftaway)'),
  ('dosing pump', 'en', '^(DD|DM|DMX|DMH|DME|Smart Digital)')
on conflict do nothing;

create or replace function pim.suche_begriff(eingabe text, anzahl integer default 20)
returns table (artikel_id bigint, artikelnummer text, typbezeichnung text, produktgruppe text, punkte numeric, begriff text)
language sql stable
set search_path = pim, public
as $$
  with v as (
    select substring(lower(eingabe) from '(\d{3})\s*v(olt)?\M')::numeric as volt
  ), b as (
    select s.begriff, s.gruppen_regex from pim.suchbegriff s
     where lower(trim(eingabe)) like '%' || s.begriff || '%'
     order by length(s.begriff) desc limit 1
  ), g as (
    select pg.id, pg.name, b.begriff from pim.produktgruppe pg, b where pg.name ~* b.gruppen_regex
  )
  select a.id, a.artikelnummer,
         (select al.wert from pim.artikel_alias al where al.artikel_id = a.id and al.typ = 'typbezeichnung' limit 1),
         g.name, q.punkte::numeric, g.begriff
    from g
    join pim.artikel_gruppe ag on ag.gruppe_id = g.id
    join pim.artikel a on a.id = ag.artikel_id
    join pim.artikel_qualitaet q on q.artikel_id = a.id
    cross join v
   where v.volt is null
      or exists (select 1 from pim.artikel_elektrik e
                  where e.artikel_id = a.id and v.volt between e.u_min and e.u_max)
   order by q.punkte desc, (a.hersteller_url is not null) desc, a.artikelnummer
   limit anzahl
$$;
revoke execute on function pim.suche_begriff(text, integer) from public, anon, authenticated;
