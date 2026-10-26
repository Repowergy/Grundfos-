-- Zubehör je Baureihe (Grundsatz: alle Verknüpfungen vollständig).
--
--  gpi.acclink (GPC 2015)        Zubehörartikel (AccProdId) passt zu allen Pumpen unter Produktgruppe PumpPgTp
--  misc/ACCLINK2.csv (GPC 2023)  Produktgruppe → Zubehörgruppe (z. B. CRE64 → FLANGE), mit Regel/Verwendung
--
-- Die Zuordnung gilt für die Gruppe und alle Untergruppen (Baum-Präfix). Statt Millionen Artikel×Artikel-Zeilen
-- steht sie einmal an der Gruppe; pim.zubehoer(artikel_id) löst sie je Pumpe auf.

create table if not exists pim.gruppe_zubehoer (
  id                 bigint generated always as identity primary key,
  gruppe_id          bigint not null references pim.produktgruppe(id) on delete cascade,  -- Pumpen-Gruppe
  zubehoer_artikel_id bigint references pim.artikel(id) on delete cascade,               -- konkreter Artikel …
  zubehoer_gruppe_id  bigint references pim.produktgruppe(id) on delete cascade,         -- … oder ganze Zubehörgruppe
  frequenz           smallint,
  regel              text,
  verwendung         text,
  quelle_id          bigint not null references pim.quelle(id),
  check (zubehoer_artikel_id is not null or zubehoer_gruppe_id is not null),
  unique nulls not distinct (gruppe_id, zubehoer_artikel_id, zubehoer_gruppe_id, frequenz, quelle_id)
);
create index if not exists gruppe_zubehoer_gruppe_idx on pim.gruppe_zubehoer (gruppe_id);
create index if not exists produktgruppe_baum_idx on pim.produktgruppe (baum text_pattern_ops);
alter table pim.gruppe_zubehoer enable row level security;

create or replace function pim.zubehoer_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, gpc2023, public
as $body$
declare
  v_gpi bigint := (select id from pim.quelle where typ = 'gpc' order by id limit 1);
  v_2023 bigint := (select id from pim.quelle where typ = 'gpc2023' order by id limit 1);
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  insert into pim.gruppe_zubehoer (gruppe_id, zubehoer_artikel_id, frequenz, quelle_id)
  select distinct g.id, a.id, nullif(l.freq, '0')::smallint, v_gpi
    from gpi.acclink l
    join pim.produktgruppe g on g.baum = l.pumppgtp
    join gpi.products2 p on p.id = l.accprodid
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Zubehörartikel je Gruppe (GPC 2015)'; anzahl := n; return next;

  insert into pim.gruppe_zubehoer (gruppe_id, zubehoer_gruppe_id, regel, verwendung, quelle_id)
  select distinct on (g.id, z.id) g.id, z.id, nullif(split_part(c.text, ';', 4), ''), nullif(split_part(c.text, ';', 5), ''),
         v_2023
    from gpc2023.datei d
    join gpc2023.zeile c on c.datei_id = d.id and c.nr > 1
    join pim.produktgruppe g on g.code = split_part(c.text, ';', 1)
    join pim.produktgruppe z on z.code = split_part(c.text, ';', 2)
   where d.pfad = 'misc/ACCLINK2.csv'
   order by g.id, z.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Zubehörgruppen je Gruppe (GPC 2023)'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.zubehoer_uebernehmen() from public, anon, authenticated;

-- Zubehör zu einer Pumpe: alle Gruppen des Artikels samt übergeordneten Gruppen
create or replace function pim.zubehoer(p_artikel bigint, anzahl integer default 200)
returns table (zubehoer_artikel_id bigint, artikelnummer text, titel text, ueber_gruppe text, art text)
language sql stable
set search_path = pim, public
as $$
  with meine as (
    select distinct oben.id, oben.name
      from pim.artikel_gruppe ag
      join pim.produktgruppe g on g.id = ag.gruppe_id
      join pim.produktgruppe oben on g.baum like oben.baum || '%'
     where ag.artikel_id = p_artikel
  ), treffer as (
    select z.zubehoer_artikel_id as id, m.name, 'Artikel' as art
      from meine m join pim.gruppe_zubehoer z on z.gruppe_id = m.id
     where z.zubehoer_artikel_id is not null
    union
    select ag.artikel_id, m.name || ' → ' || zg.name, 'Zubehörgruppe'
      from meine m
      join pim.gruppe_zubehoer z on z.gruppe_id = m.id and z.zubehoer_gruppe_id is not null
      join pim.produktgruppe zg on zg.id = z.zubehoer_gruppe_id
      join pim.artikel_gruppe ag on ag.gruppe_id = zg.id
  )
  select distinct on (t.id) t.id, a.artikelnummer,
         (select x.text from pim.artikel_text x where x.artikel_id = t.id and x.art = 'titel'
           order by (x.sprache = 'de') desc limit 1),
         t.name, t.art
    from treffer t join pim.artikel a on a.id = t.id
   order by t.id
   limit anzahl
$$;
revoke execute on function pim.zubehoer(bigint, integer) from public, anon, authenticated;
