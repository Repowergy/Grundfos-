-- Fachwörterbuch: fehlende Übersetzungen der Shop-Auswahl sammeln (27.10.2026)
--
-- pim.glossar_bedarf_sammeln() füllt pim._glossar_bedarf (bereich, schluessel, quelle_en, sprache) mit allem, was in den
-- 22 Shop-Sprachen außer Englisch fehlt:
--   MERKMAL     Merkmalsnamen (pim.merkmal_uebersetzung)
--   DB_DV<code> Merkmalswerte mit Text (z. B. Werkstoffe, Einbauart)
--   DB_PARTS    englische Titel der Ersatzteile/Zubehöre (Grundfos-Bereiche DB_PARTS, PLG_PARTS, DB_PRODNAME*ACC)
--   DB_PGD      Baureihentexte der Pumpen
-- Die Übersetzungen werden außerhalb der Datenbank erzeugt und mit herkunft = 'maschinell' (uebersetzung) bzw.
-- status = 'maschinell' (merkmal_uebersetzung) geladen – Grundfos-Einträge werden nie überschrieben
-- (tools/import/glossar_laden.py). Laufzeit ca. 15 min (Merkmalswerte über den Primärschlüssel je Artikel) → per pg_cron.

create table if not exists pim._glossar_bedarf (bereich text, schluessel text, quelle_en text, sprache text);
create table if not exists pim._glossar_werte (merkmal_code text, wert text);
create table if not exists pim._glossar_teile (text text primary key);
alter table pim._glossar_bedarf enable row level security;
alter table pim._glossar_werte enable row level security;
alter table pim._glossar_teile enable row level security;

drop function if exists pim._glossar_bedarf_fuellen();

create or replace function pim.glossar_bedarf_sammeln()
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare
  n bigint;
  l text[] := array['de','fr','it','nl','pl','es','pt','sv','da','fi','nb','cs','sk','hu','ro','bg','hr','sl','el','et','lv','lt'];
begin
  perform set_config('statement_timeout', '0', true);
  truncate pim._glossar_bedarf, pim._glossar_werte, pim._glossar_teile;

  insert into pim._glossar_bedarf (bereich, schluessel, quelle_en, sprache)
  select 'MERKMAL', m.merkmal_code, e.bezeichnung, s
    from (select distinct x.merkmal_code from pim.shop_auswahl a
           cross join lateral (select am.merkmal_code from pim.artikel_merkmal am where am.artikel_id = a.artikel_id) x) m
    join pim.merkmal_uebersetzung e on e.merkmal_code = m.merkmal_code and e.sprache = 'en'
    cross join unnest(l) s
   where not exists (select 1 from pim.shop_merkmal_aus x where x.code = m.merkmal_code)
     and not exists (select 1 from pim.merkmal_uebersetzung u where u.merkmal_code = m.merkmal_code and u.sprache = s);

  -- lateral: Zugriff je Artikel über den Primärschlüssel statt Scan der ganzen Merkmalstabelle
  insert into pim._glossar_werte
  select distinct x.merkmal_code, btrim(x.wert)
    from pim.shop_auswahl a
    cross join lateral (select am.merkmal_code, am.wert from pim.artikel_merkmal am
                         where am.artikel_id = a.artikel_id and am.wert ~ '[A-Za-zÄÖÜäöüß]{3,}') x
   where upper(btrim(x.wert)) not in ('Y', 'YES', 'N', 'NO')
     and not exists (select 1 from pim.shop_merkmal_aus z where z.code = x.merkmal_code)
     and exists (select 1 from pim.merkmal_uebersetzung e where e.merkmal_code = x.merkmal_code and e.sprache = 'en');

  insert into pim._glossar_bedarf (bereich, schluessel, quelle_en, sprache)
  select 'DB_DV' || w.merkmal_code, w.wert,
         coalesce((select ltrim(u.text, '/|') from pim.uebersetzung u where u.bereich = 'DB_DV' || w.merkmal_code and u.sprache = 'en'
                     and ltrim(upper(u.schluessel), '/|') = ltrim(upper(w.wert), '/|') limit 1), w.wert), s
    from pim._glossar_werte w cross join unnest(l) s
   where not exists (select 1 from pim.uebersetzung u where u.bereich = 'DB_DV' || w.merkmal_code and u.sprache = s
                       and ltrim(upper(u.schluessel), '/|') = ltrim(upper(w.wert), '/|'));

  insert into pim._glossar_teile
  select distinct btrim(t.text) from pim.shop_auswahl a
    join pim.artikel_text t on t.artikel_id = a.artikel_id and t.sprache = 'en' and t.art = 'titel'
   where a.grund in ('Ersatzteil', 'Zubehör') and btrim(t.text) <> ''
  on conflict do nothing;

  insert into pim._glossar_bedarf (bereich, schluessel, quelle_en, sprache)
  select 'DB_PARTS', g.text, g.text, s
    from pim._glossar_teile g cross join unnest(l) s
   where not exists (select 1 from pim.uebersetzung u
                      where u.bereich in ('DB_PARTS', 'PLG_PARTS', 'DB_PRODNAMEMECACC', 'DB_PRODNAMEELACC', 'DB_PRODNAMEPITACC', 'DB_PRODNAMEWASACC')
                        and u.sprache = s and ltrim(upper(u.schluessel), '/|') = ltrim(upper(g.text), '/|'));

  insert into pim._glossar_bedarf (bereich, schluessel, quelle_en, sprache)
  select 'DB_PGD', g.code,
         coalesce((select u.text from pim.uebersetzung u where u.bereich = 'DB_PGD' and u.sprache = 'en'
                     and ltrim(upper(u.schluessel), '/|') = ltrim(upper(g.code), '/|') limit 1), g.beschreibung), s
    from (select distinct g.code, g.beschreibung from pim.shop_auswahl a
            join pim.artikel_gruppe ag on ag.artikel_id = a.artikel_id
            join pim.produktgruppe g on g.id = ag.gruppe_id
           where a.grund not in ('Ersatzteil', 'Zubehör')) g
    cross join unnest(l) s
   where not exists (select 1 from pim.uebersetzung u where u.bereich = 'DB_PGD' and u.sprache = s
                       and ltrim(upper(u.schluessel), '/|') = ltrim(upper(g.code), '/|'))
     and exists (select 1 from pim.uebersetzung u where u.bereich = 'DB_PGD' and ltrim(upper(u.schluessel), '/|') = ltrim(upper(g.code), '/|'));

  select count(*) into n from pim._glossar_bedarf;
  return n;
end;
$body$;
revoke execute on function pim.glossar_bedarf_sammeln() from public, anon, authenticated;
