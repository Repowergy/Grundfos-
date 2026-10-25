-- Medien und Produktgruppen aus der GPC-Datenbank (gpi).
--
--  * pim.produktgruppe   GPC-Produktgruppenbaum (z. B. ALPHA → ALPHA2), mit Beschreibung
--  * pim.artikel_gruppe  Artikel ↔ Produktgruppe
--  * pim.gruppe_medium   Dokumente, die für eine ganze Gruppe gelten (Datenblatt, Anleitung je Sprache …)
--  * pim.medium          + Literatur (5.816 Dokumente, 32.379 Sprachdateien; Schlüssel = Datei-Id + Sprache + Dokument)
--                          und Dateien aus gpi.DF
--                          (Maßzeichnungen, Schaltbilder, Produktbilder, Explosionszeichnungen, Anleitungen)
--  * pim.artikel_medium  Produkt-Dokumente (ProdDF), Explosionszeichnungen je Teil (PartDrawingLink),
--                          Bild/Maßbild/Schaltbild über die Merkmale PRODPIC/DRAWDIM/DRAWELC
-- Die Dateien selbst liegen (teilweise) im GPC-Ordner; datei_pfad zeigt auf gpc2023.datei, sobald importiert.

create table if not exists pim.produktgruppe (
  id           bigint generated always as identity primary key,
  gpi_id       text unique,
  code         text,
  name         text,
  beschreibung text,
  baum         text,                  -- GPC-TreePlace, z. B. '0101'
  eltern_id    bigint references pim.produktgruppe(id),
  quelle_id    bigint references pim.quelle(id)
);
create index if not exists produktgruppe_code_idx on pim.produktgruppe (code);

create table if not exists pim.artikel_gruppe (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  gruppe_id  bigint not null references pim.produktgruppe(id) on delete cascade,
  quelle_id  bigint references pim.quelle(id),
  primary key (artikel_id, gruppe_id)
);
create index if not exists artikel_gruppe_gruppe_idx on pim.artikel_gruppe (gruppe_id);

alter table pim.medium
  add column if not exists quell_schluessel text unique,   -- z. B. 'gpi.df:123', 'gpi.literaturefile:17'
  add column if not exists titel            text,
  add column if not exists kategorie        text,          -- GPC-Kategorie (IOI, DBO, DRAWDIM …)
  add column if not exists dateigroesse     bigint,
  add column if not exists veroeffentlicht  date,
  add column if not exists datei_pfad       text;          -- Fundort im importierten GPC-Ordner

create table if not exists pim.gruppe_medium (
  gruppe_id bigint not null references pim.produktgruppe(id) on delete cascade,
  medium_id bigint not null references pim.medium(id) on delete cascade,
  rolle     text not null default 'standard',
  quelle_id bigint references pim.quelle(id),
  primary key (gruppe_id, medium_id, rolle)
);
create index if not exists artikel_medium_medium_idx on pim.artikel_medium (medium_id);

alter table pim.produktgruppe enable row level security;
alter table pim.artikel_gruppe enable row level security;
alter table pim.gruppe_medium enable row level security;

create or replace function pim.medien_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;

  -- Produktgruppen
  insert into pim.produktgruppe (gpi_id, code, name, beschreibung, baum, quelle_id)
  select id, nullif(trim(code), ''), nullif(trim(name), ''), nullif(trim(description), ''), treeplace, v_quelle
    from gpi.pg
  on conflict (gpi_id) do nothing;
  get diagnostics n = row_count;
  schritt := 'Produktgruppen'; anzahl := n; return next;

  update pim.produktgruppe k set eltern_id = (
    select e.id from pim.produktgruppe e
     where k.baum like e.baum || '%' and length(e.baum) < length(k.baum)
     order by length(e.baum) desc limit 1)
   where k.eltern_id is null and k.baum is not null;

  insert into pim.artikel_gruppe (artikel_id, gruppe_id, quelle_id)
  select distinct a.id, g.id, v_quelle
    from gpi.products2 p
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
    join pim.produktgruppe g on g.gpi_id = p.pgid
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Artikel ↔ Gruppe'; anzahl := n; return next;

  -- Literatur (je Sprachdatei ein Medium)
  insert into pim.medium (typ, dateiname, titel, dokumentnummer, sprache, kategorie, dateigroesse, veroeffentlicht,
                          quell_schluessel, quelle_id)
  select case l.documentcategory
           when 'IOI' then 'anleitung' when 'QGU' then 'anleitung'
           when 'DBO' then 'datenblatt' when 'DSH' then 'datenblatt'
           when 'SER' then 'service' else 'sonstiges' end,
         'literature/' || lf.id, nullif(trim(lf.title), ''), nullif(trim(l.publicationnumber), ''),
         lf.languagecode, l.documentcategory, nullif(lf.filesize, '')::bigint, pim.gpi_datum(l.publisheddate),
         'gpi.literaturefile:' || lf.id || ':' || lf.languagecode || ':' || lf.litid, v_quelle
    from gpi.literaturefile lf
    join gpi.literature l on l.id = lf.litid
  on conflict (quell_schluessel) do nothing;
  get diagnostics n = row_count;
  schritt := 'Literatur-Dateien'; anzahl := n; return next;

  insert into pim.gruppe_medium (gruppe_id, medium_id, rolle, quelle_id)
  select distinct g.id, m.id, lower(coalesce(m.kategorie, 'dokument')), v_quelle
    from gpi.literaturepglink x
    join pim.produktgruppe g on g.code = x.pgcode
    join gpi.literaturefile lf on lf.litid = x.litid
    join pim.medium m on m.quell_schluessel = 'gpi.literaturefile:' || lf.id || ':' || lf.languagecode || ':' || lf.litid
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Literatur ↔ Gruppe'; anzahl := n; return next;

  -- Dateien aus DF
  insert into pim.medium (typ, dateiname, titel, sprache, kategorie, dateigroesse, quell_schluessel, quelle_id)
  select case
           when upper(d.dir) = 'DRAWDIM' then 'massbild'
           when upper(d.dir) = 'DRAWELC' then 'schaltbild'
           when upper(d.dir) in ('PRODPIC', 'QTP') then 'bild'
           when upper(d.dir) = 'INSTOPER' then 'anleitung'
           when upper(d.dir) like 'SERVICE/%' then 'service'
           when upper(d.dir) = 'SERVICE' and lower(d.extension) in ('np2', 'tif') then 'explosionszeichnung'
           else 'sonstiges' end,
         d.filename || coalesce('.' || nullif(d.extension, ''), ''), nullif(trim(d.description), ''),
         coalesce(lg.code, nullif(d.lang, '0')), d.dir, nullif(d.size, '')::bigint, 'gpi.df:' || d.id, v_quelle
    from gpi.df d
    left join gpi.lang lg on lg.id = d.lang and d.lang <> '0'
   where coalesce(trim(d.filename), '') <> ''
  on conflict (quell_schluessel) do nothing;
  get diagnostics n = row_count;
  schritt := 'Dateien (DF)'; anzahl := n; return next;

  -- Produkt-Dokumente
  insert into pim.artikel_medium (artikel_id, medium_id, rolle, quelle_id)
  select distinct a.id, m.id, 'dokument', v_quelle
    from gpi.proddf x
    join gpi.products2 p on p.id = x.prodid
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
    join pim.medium m on m.quell_schluessel = 'gpi.df:' || x.dfid
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Produkt-Dokumente'; anzahl := n; return next;

  -- Explosionszeichnungen je Teil/Baugruppe
  insert into pim.artikel_medium (artikel_id, medium_id, rolle, quelle_id)
  select distinct a.id, m.id, 'explosionszeichnung', v_quelle
    from gpi.partdrawinglink x
    join gpi.master t on t.partid = x.partid
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(t.partnum), ' ', ''))
    join pim.medium m on m.quell_schluessel = 'gpi.df:' || x.dfid
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Explosionszeichnungen'; anzahl := n; return next;

  -- Infobaum: Dokumente je Produktgruppe
  insert into pim.gruppe_medium (gruppe_id, medium_id, rolle, quelle_id)
  select distinct g.id, m.id, lower(coalesce(m.kategorie, 'info')), v_quelle
    from gpi.pgit pi
    join gpi.itdf idf on idf.itid = pi.itid
    join pim.produktgruppe g on g.gpi_id = pi.pgid
    join pim.medium m on m.quell_schluessel = 'gpi.df:' || idf.dfid
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Info-Dokumente ↔ Gruppe'; anzahl := n; return next;
end;
$body$;

-- Bild / Maßbild / Schaltbild über die Merkmalswerte (nach der Merkmal-Übernahme ausführen)
create or replace function pim.medien_aus_merkmalen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, public
as $body$
declare
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  insert into pim.artikel_medium (artikel_id, medium_id, rolle, quelle_id)
  select distinct on (am.artikel_id, m.id, r.rolle) am.artikel_id, m.id, r.rolle, am.quelle_id
    from pim.artikel_merkmal am
    join (values ('PRODPIC', 'PRODPIC', 'hauptbild'), ('DRAWDIM', 'DRAWDIM', 'massbild'),
                 ('DRAWELC', 'DRAWELC', 'schaltbild')) r(code, dir, rolle) on r.code = am.merkmal_code
    join pim.medium m on upper(m.kategorie) = r.dir
                     and lower(split_part(m.dateiname, '.', 1)) = lower(am.wert)
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Bild/Maßbild/Schaltbild je Artikel'; anzahl := n; return next;
end;
$body$;

-- Fundort der Dateien im importierten GPC-Ordner (nach Import 3 ausführen)
create or replace function pim.medien_dateien_finden()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpc2023, public
as $body$
declare
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  update pim.medium m set datei_pfad = f.pfad
    from (select distinct on (lower(name)) lower(name) as name, pfad from gpc2023.datei
           where art in ('binaer', 'text') order by lower(name), length(pfad)) f
   where m.datei_pfad is null and f.name = lower(m.dateiname);
  get diagnostics n = row_count;
  schritt := 'Dateien im GPC-Ordner gefunden'; anzahl := n; return next;
end;
$body$;

revoke execute on function pim.medien_uebernehmen() from public, anon, authenticated;
revoke execute on function pim.medien_aus_merkmalen() from public, anon, authenticated;
revoke execute on function pim.medien_dateien_finden() from public, anon, authenticated;
