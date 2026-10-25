-- Mehrsprachige Produkttexte aus der Grundfos-Software 2023 (HybrisQt.zip, Schema gpc2023).
--
-- Aufbau der Quelle:
--   HYBRISQT/<SPRACHE>/<SCHLÜSSEL>.txt   ein Textbaustein je Sprache (27 Sprachen), z. B. _FI_TXTSHO_CM_CONNECTION_S
--   HYBRISQT/<SCHLÜSSEL>.txt             Regeln: {MERKMAL=WERT}…{ZIEL}{!} – welcher Baustein für welche Pumpe gilt
--   HYBRISQT/<SPRACHE>/DMX_<Nummer>.txt  komplette Produkttexte je Artikelnummer
--
--  pim.sprache        GPC-Sprachkürzel (DEU, ENU, FRA …) → ISO-Code (de, en, fr …)
--  pim.textbaustein   + Bausteine je Sprache (Quelle 'gpc2023')
--  pim.text_regel     zerlegte Regeln (Bedingungen als JSON, Ziel, Stop)
--  pim.artikel_text   + DMX-Produkttexte je Sprache (art 'lang')

create table if not exists pim.sprache (
  gpc_code text primary key,
  iso      text not null,
  name     text
);
insert into pim.sprache (gpc_code, iso, name) values
  ('DEU','de','Deutsch'),('ENU','en','Englisch'),('USA','en-US','Englisch (USA)'),('FRA','fr','Französisch'),
  ('FRC','fr-CA','Französisch (Kanada)'),('ITA','it','Italienisch'),('NLD','nl','Niederländisch'),('NLB','nl-BE','Flämisch'),
  ('ESP','es','Spanisch'),('ESM','es-MX','Spanisch (Mexiko)'),('PTG','pt','Portugiesisch'),('PTB','pt-BR','Portugiesisch (Brasilien)'),
  ('DAN','da','Dänisch'),('SVE','sv','Schwedisch'),('NOR','nb','Norwegisch'),('FIN','fi','Finnisch'),('PLK','pl','Polnisch'),
  ('CSY','cs','Tschechisch'),('SKY','sk','Slowakisch'),('HUN','hu','Ungarisch'),('ROM','ro','Rumänisch'),('BGR','bg','Bulgarisch'),
  ('HRV','hr','Kroatisch'),('SLV','sl','Slowenisch'),('SRL','sr','Serbisch'),('BIH','bs','Bosnisch'),('ELL','el','Griechisch'),
  ('TRK','tr','Türkisch'),('RUS','ru','Russisch'),('UKR','uk','Ukrainisch'),('KAZ','kk','Kasachisch'),('LTH','lt','Litauisch'),
  ('LVI','lv','Lettisch'),('ETI','et','Estnisch'),('CHS','zh-CN','Chinesisch (vereinfacht)'),('CHT','zh-TW','Chinesisch (traditionell)'),
  ('JPN','ja','Japanisch'),('KOR','ko','Koreanisch'),('THA','th','Thailändisch'),('VIE','vi','Vietnamesisch'),
  ('IND','id','Indonesisch'),('ARA','ar','Arabisch'),('ENI','en-IN','Englisch (Indien)'),('ESG','es-x-esg','Spanisch (ESG)'),
  ('SAE','en-x-sae','Englisch (SAE)')
on conflict do nothing;
alter table pim.sprache enable row level security;

create table if not exists pim.text_regel (
  quelle_id   bigint not null references pim.quelle(id),
  schluessel  text not null,              -- Regeldatei, z. B. _FI_CONSHO_NB-G_MOTOR
  nr          integer not null,           -- Zeile = Priorität (erste passende Regel gilt bei {!})
  bedingungen jsonb not null default '[]', -- [{"merkmal":"MGEMOTOR","op":"=","wert":"P"}, …]; [] = immer
  ziel        text,                       -- Baustein-Schlüssel oder Literal
  ziel_ist_baustein boolean not null default true,
  stop        boolean not null default false,
  roh         text not null,
  primary key (quelle_id, schluessel, nr)
);
alter table pim.text_regel enable row level security;

create or replace function pim.hybris_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpc2023, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  select id into v_quelle from pim.quelle where typ = 'gpc2023' order by id limit 1;
  if v_quelle is null then
    insert into pim.quelle (typ, bezeichnung, datenstand, prioritaet)
    values ('gpc2023', 'Grundfos-Software GPC, Datenordner 09/2023', date '2023-09-07', 78)
    returning id into v_quelle;
  end if;

  -- Bausteine je Sprache
  insert into pim.textbaustein (quelle_id, schluessel, sprache, zeile, text)
  select v_quelle, regexp_replace(d.name, '\.txt$', '', 'i'), coalesce(s.iso, lower(x.lang)), z.nr, z.text
    from gpc2023.datei d
    cross join lateral (select substring(d.pfad from 'HYBRISQT/([A-Z]{3})/[^/]+$') as lang) x
    join gpc2023.zeile z on z.datei_id = d.id
    left join pim.sprache s on s.gpc_code = x.lang
   where d.pfad like 'datafile/HybrisQt.zip!/HYBRISQT/%' and x.lang is not null and d.art = 'text'
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Textbausteine (alle Sprachen, Zeilen)'; anzahl := n; return next;

  -- Regeln (Dateien direkt unter HYBRISQT/)
  insert into pim.text_regel (quelle_id, schluessel, nr, bedingungen, ziel, ziel_ist_baustein, stop, roh)
  select v_quelle, regexp_replace(d.name, '\.txt$', '', 'i'), z.nr,
         coalesce((select jsonb_agg(jsonb_build_object(
                      'merkmal', substring(t[1] from '^([A-Za-z0-9_]+)'),
                      'op', substring(t[1] from '^[A-Za-z0-9_]+([=?<>!]+)'),
                      'wert', substring(t[1] from '^[A-Za-z0-9_]+[=?<>!]+(.*)$')) order by o)
                     from regexp_matches(z.text, '\{([A-Za-z0-9_]+[=?<>!][^}]*)\}', 'g') with ordinality m(t, o)),
                  '[]'::jsonb),
         coalesce(substring(z.text from '\{(_[A-Za-z0-9_-]+|FAM_[A-Za-z0-9_-]+)\}(?:\{!\})?\s*$'),
                  nullif(trim(regexp_replace(regexp_replace(z.text, '\{[^}]*\}', '', 'g'), '\s+', ' ', 'g')), '')),
         z.text ~ '\{(_[A-Za-z0-9_-]+|FAM_[A-Za-z0-9_-]+)\}',
         z.text ~ '\{!\}\s*$',
         z.text
    from gpc2023.datei d
    join gpc2023.zeile z on z.datei_id = d.id
   where d.pfad ~ '^datafile/HybrisQt\.zip!/HYBRISQT/[^/]+\.txt$' and d.art = 'text' and trim(z.text) <> ''
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Text-Regeln'; anzahl := n; return next;

  -- DMX_<Artikelnummer>: komplette Produkttexte je Sprache
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select a.id, s.iso, 'lang', string_agg(z.text, E'\n' order by z.nr), v_quelle
    from gpc2023.datei d
    cross join lateral (select substring(d.pfad from 'HYBRISQT/([A-Z]{3})/DMX_') as lang,
                               substring(d.name from '^DMX_([0-9A-Za-z]+)\.txt$') as nr) x
    join pim.sprache s on s.gpc_code = x.lang
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(x.nr)
    join gpc2023.zeile z on z.datei_id = d.id
   where d.pfad like 'datafile/HybrisQt.zip!/HYBRISQT/%/DMX\_%' and x.nr is not null
   group by a.id, s.iso
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'DMX-Produkttexte je Sprache'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.hybris_uebernehmen() from public, anon, authenticated;
