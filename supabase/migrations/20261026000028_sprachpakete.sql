-- Sprachpakete der GPC-Software 2023 (datafile/ctf/<SPR>.zip, 33 Sprachen) vollständig erschließen.
--
-- Jede CTF-Datei: Kopf bis '#', dann Blöcke „Schlüssel / Text … / #“. Viele Pakete sind doppelt kodiert
-- (UTF-8-Bytes als cp850 gelesen: „ð▓ð©ðÂ“ statt „виж“) → pim.cp850_reparieren() macht das rückgängig.
--
--  pim.uebersetzung (bereich, schluessel, sprache, text)   alles in einer Tabelle, bereich = Dateiname ohne Sprache,
--       z. B. DB_PG (Produktgruppen-Name je Gruppen-Code), DB_PGD (-Beschreibung), DB_PARTS (Ersatzteil-Bezeichnungen),
--       DB_PRODNAMEELACC/MECACC/… (Zubehör-Namen), DB_APPLNAME, DB_CATEGORY_TITLE, DB_DV<MERKMAL> (Merkmalswerte),
--       QTPRODUCTS (Baureihentexte), LITERATURE (Dokumentarten) …
--  pim.uebersetze(bereich, schluessel, sprache)            Nachschlagen (Schlüssel ohne Groß-/Kleinschreibung)

create or replace function pim.cp850_reparieren(t text)
returns text
language plpgsql immutable
as $$
declare
  cp850 constant text := 'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜø£Ø×ƒáíóúñÑªº¿®¬½¼¡«»░▒▓│┤ÁÂÀ©╣║╗╝¢¥┐└┴┬├─┼ãÃ╚╔╩╦╠═╬¤ðÐÊËÈıÍÎÏ┘┌█▄¦Ì▀ÓßÔÒõÕµþÞÚÛÙýÝ¯´' || chr(173) || '±‗¾¶§÷¸°¨·¹³²■' || chr(160);
  latin text;
begin
  if t is null or t !~ '[^\x01-\x7e]' then return t; end if;
  select string_agg(chr(i), '' order by i) into latin from generate_series(128, 255) i;
  return convert_from(convert_to(translate(t, cp850, latin), 'LATIN1'), 'UTF8');
exception when others then
  return t;   -- war nicht doppelt kodiert (z. B. korrektes Deutsch oder Kyrillisch)
end;
$$;

create table if not exists pim.uebersetzung (
  bereich    text not null,
  schluessel text not null,
  sprache    text not null,          -- ISO, z. B. 'de'
  text       text not null,
  primary key (bereich, sprache, schluessel)
);
create index if not exists uebersetzung_suche_idx on pim.uebersetzung (bereich, upper(schluessel), sprache);
alter table pim.uebersetzung enable row level security;

create or replace function pim.uebersetze(p_bereich text, p_schluessel text, p_sprache text)
returns text
language sql stable
set search_path = pim, public
as $f$
  select u.text from pim.uebersetzung u
   where u.bereich = p_bereich and upper(u.schluessel) = upper(btrim(p_schluessel)) and u.sprache = p_sprache
   limit 1
$f$;

-- Eine Sprache (GPC-Kürzel, z. B. 'DEU') aus gpc2023.zeile in pim.uebersetzung schreiben
create or replace function pim.sprachpaket_uebernehmen(p_gpc text)
returns bigint
language plpgsql
set search_path = pim, gpc2023, public
as $body$
declare
  v_iso text := (select iso from pim.sprache where gpc_code = p_gpc);
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  with z as (
    -- Präfix = Sprache, meist 3 Zeichen (DEU_…), bei Englisch-Indien 4 (ENIN_…)
    select upper(substring(d.name from '(?i)^[a-z]{3,4}_(.*)\.ctf$')) as bereich, d.id as datei_id, l.nr, l.text,
           (btrim(l.text) = '#') as trenner
      from gpc2023.datei d join gpc2023.zeile l on l.datei_id = d.id
     where d.pfad like 'datafile/ctf/' || p_gpc || '.zip!/%' and d.name ~* '\.CTF$'
  ), b0 as (
    select bereich, datei_id, nr, text, trenner,
           sum(trenner::int) over (partition by datei_id order by nr) as block
      from z
  ), b as (
    select b0.*, row_number() over (partition by datei_id, block order by nr) as pos from b0
  ), bl as (
    select bereich, datei_id, block,
           max(text) filter (where pos = 2) as schluessel,            -- pos 1 = das '#' selbst
           string_agg(text, E'\n' order by nr) filter (where pos > 2 and not trenner) as inhalt
      from b where block >= 1
     group by bereich, datei_id, block
  )
  insert into pim.uebersetzung (bereich, schluessel, sprache, text)
  select distinct on (bereich, btrim(schluessel)) bereich, btrim(schluessel), v_iso, pim.cp850_reparieren(btrim(inhalt))
    from bl
   where btrim(coalesce(schluessel, '')) not in ('', 'commands') and btrim(coalesce(inhalt, '')) <> ''
     and bereich is not null
   order by bereich, btrim(schluessel), block
  on conflict (bereich, sprache, schluessel) do update set text = excluded.text;
  get diagnostics n = row_count;
  return n;
end;
$body$;

revoke execute on function pim.sprachpaket_uebernehmen(text) from public, anon, authenticated;
