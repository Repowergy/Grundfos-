-- Ersatzteile in Shop-Kategorien einordnen (27.10.2026)
--
-- Ersatzteile hängen in eigenen Produktgruppen ohne Anwendungsbaum → im Pilot ohne Kategorie. Neu: Kategorie aus der Baureihe
-- der Pumpen, in die das Teil passt:  „Ersatzteile > <Bereich der Baureihe> > <Baureihe>“, z. B. „Ersatzteile > Heizung > MAGNA3“
--
--  pim.ersatzteil_baureihe   je Ersatzteil die Baureihen (Produktgruppen) der passenden Pumpen mit Anzahl Pumpen und Rang
--  pim.ersatzteil_baureihe_aufbauen()   füllt die Tabelle aus pim.artikel_beziehung (typ 'ersatzteil') + pim.artikel_gruppe
--  pim.shop_bereich(gruppe, sprache)    Hauptbereich einer Baureihe im Anwendungsbaum (Heizung, Druckerhöhung …)
--  pim.shop_ersatzteil_kategorien(artikel, sprache)   bis zu 3 Pfade (häufigste Baureihen zuerst), je Sprache
-- Die Export-Ansicht nimmt für Ersatzteile diese Pfade (übrige Produkte unverändert).

create table if not exists pim.ersatzteil_baureihe (
  teil_id   bigint not null references pim.artikel(id) on delete cascade,
  gruppe_id bigint not null references pim.produktgruppe(id) on delete cascade,
  pumpen    integer not null,
  rang      integer not null,
  primary key (teil_id, gruppe_id)
);
create index if not exists ersatzteil_baureihe_rang_idx on pim.ersatzteil_baureihe (teil_id, rang);
alter table pim.ersatzteil_baureihe enable row level security;

create or replace function pim.ersatzteil_baureihe_aufbauen()
returns bigint
language plpgsql
set search_path = pim, public
as $body$
declare n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  truncate pim.ersatzteil_baureihe;
  insert into pim.ersatzteil_baureihe (teil_id, gruppe_id, pumpen, rang)
  select teil_id, gruppe_id, pumpen, row_number() over (partition by teil_id order by pumpen desc, gruppe_id)
    from (select b.zu_artikel_id as teil_id, ag.gruppe_id, count(distinct b.von_artikel_id)::int as pumpen
            from pim.artikel_beziehung b
            join pim.artikel_gruppe ag on ag.artikel_id = b.von_artikel_id
           where b.typ = 'ersatzteil'
           group by 1, 2) x;
  get diagnostics n = row_count;
  return n;
end;
$body$;
revoke execute on function pim.ersatzteil_baureihe_aufbauen() from public, anon, authenticated;

-- Hauptbereich einer Baureihe: oberste Ebene des Anwendungsbaums (ohne „Alle Produkte“ und Gebäudearten), kleinste Sortierung
create or replace function pim.shop_bereich(p_gruppe bigint, p_sprache text default 'de')
returns text
language sql stable
set search_path = pim, public
as $$
  select coalesce(tl.name, td.name)
    from pim.produktgruppe ga
    join pim.produktgruppe gk on ga.baum like gk.baum || '%'
    join pim.shop_kategorie_gruppe kg on kg.gruppe_id = gk.id
    join pim.shop_kategorie k on k.id = kg.kategorie_id
    join pim.shop_kategorie r on r.id = coalesce(k.parent_id, k.id) and r.parent_id is null
    left join pim.shop_kategorie_text tl on tl.kategorie_id = r.id and tl.sprache = p_sprache
    left join pim.shop_kategorie_text td on td.kategorie_id = r.id and td.sprache = 'de'
   where ga.id = p_gruppe and r.code not in ('GENERAL') and r.code !~ '^AA'
   order by r.sortierung nulls last, r.id
   limit 1
$$;

create or replace function pim.shop_ersatzteil_kategorien(p_artikel bigint, p_sprache text default 'de')
returns jsonb
language sql stable
set search_path = pim, public
as $$
  select coalesce(jsonb_agg(pfad order by rang), '[]')
    from (select eb.rang,
                 (case p_sprache when 'en' then 'Spare parts' when 'fr' then 'Pièces détachées' when 'it' then 'Ricambi'
                                 when 'nl' then 'Reserveonderdelen' when 'pl' then 'Części zamienne' else 'Ersatzteile' end)
                 || coalesce(' > ' || pim.shop_bereich(eb.gruppe_id, p_sprache), '')
                 || ' > ' || g.name as pfad
            from pim.ersatzteil_baureihe eb
            join pim.produktgruppe g on g.id = eb.gruppe_id
           where eb.teil_id = p_artikel and eb.rang <= 3) x
$$;
revoke execute on function pim.shop_ersatzteil_kategorien(bigint, text) from public, anon, authenticated;
revoke execute on function pim.shop_bereich(bigint, text) from public, anon, authenticated;
