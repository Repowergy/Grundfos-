-- Preislisten-Kürzel 2023 → Land. Quelle: misc/CustomerProfile.xml der GPC-Software 2023
-- (custid → Grundfos-Gesellschaft, z. B. BGA = „Grundfos Argentina“).
-- Gibt es das Land schon (2015 unter anderem Kürzel, z. B. Bosnien 'gfbosnia'), wandert das 2023-Sortiment dorthin
-- und das Kürzel steht in markt.gpc_code_2023. Ohne Eintrag im Profil bleiben gsa, gpp, gpe, fepc vorerst 'GPC:<kürzel>';
-- gcb (Grundfos CBS Inc.), ppu (Peerless Pump), ycc (Grundfos USA – YCC) sind Firmenlisten, keine Länder.

alter table pim.markt add column if not exists gpc_code_2023 text unique;

create or replace function pim.maerkte_2023_zuordnen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, public
as $body$
declare
  r record;
  n bigint;
begin
  for r in select * from (values
      ('bga', 'AR', 'Argentina', 'ARS'), ('bgc', 'CL', 'Chile', 'CLP'), ('gas', 'ID', 'Indonesia', 'IDR'),
      ('gbh', 'BA', 'Bosnia', null),     ('gbl', 'BE', 'Belgium', 'EUR'), ('gbu', 'BG', 'Bulgaria', null),
      ('gcr', 'HR', 'Croatia', null),    ('gse', 'RS', 'Serbia', null),   ('gka', 'KZ', 'Kazakhstan', null),
      ('gjk', 'JP', 'Japan', 'JPY'),     ('gph', 'GR', 'Greece', 'EUR'),  ('gpi', 'IE', 'Ireland', 'EUR'),
      ('gsi', 'SG', 'Singapore', 'SGD'), ('gth', 'TH', 'Thailand', 'THB')) v(kuerzel, iso, name, waehrung)
  loop
    insert into pim.markt (code, name, waehrung, ist_land) values (r.iso, r.name, r.waehrung, true)
    on conflict (code) do nothing;
    update pim.markt set gpc_code_2023 = r.kuerzel where code = r.iso;
    update pim.artikel_markt set markt = r.iso where markt = 'GPC:' || r.kuerzel;
    get diagnostics n = row_count;
    delete from pim.markt where code = 'GPC:' || r.kuerzel;
    schritt := r.kuerzel || ' → ' || r.iso || ' ' || r.name; anzahl := n; return next;
  end loop;
end;
$body$;
revoke execute on function pim.maerkte_2023_zuordnen() from public, anon, authenticated;

-- „Popular now“ je Land (misc/PopularNow/<KÜRZEL>_PRODUCTS.csv): Reihenfolge = Rang, z. B. für die Shop-Startseite
create table if not exists pim.artikel_beliebt (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  markt      text not null,
  rang       smallint not null,
  quelle_id  bigint not null references pim.quelle(id),
  primary key (artikel_id, markt, quelle_id)
);
alter table pim.artikel_beliebt enable row level security;

insert into pim.artikel_beliebt (artikel_id, markt, rang, quelle_id)
select distinct on (a.id, m.code) a.id, m.code, z.nr, (select id from pim.quelle where typ = 'gpc2023' limit 1)
  from gpc2023.datei d
  join gpc2023.zeile z on z.datei_id = d.id
  join pim.markt m on lower(substring(d.name from '^([A-Za-z]+)_PRODUCTS')) in (m.gpc_code, m.gpc_code_2023)
  join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(trim(z.text))
 where d.pfad ~* '^misc/PopularNow/[A-Z]+_PRODUCTS\.csv$'
 order by a.id, m.code, z.nr
on conflict do nothing;
