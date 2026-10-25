-- Merkmal-Modul: ein gemeinsamer, sprachneutraler Merkmalskatalog für alle Quellen.
--
--  * pim.merkmal               Katalog (Code, Name, Einheit normiert + Faktor, Erklärung, Herkunft)
--  * pim.merkmal_uebersetzung  Namen je Sprache (en aus GPC; de/fr/… aus Sprachpaketen und DATANORM folgen)
--  * pim.merkmal_alias         Zuordnung fremder Merkmalsnamen (DATANORM-Label, ARGE, ETIM …) → Code
--  * pim.artikel_merkmal       Werte je Artikel: Originaltext + Zahl in normierter Einheit (filterbar)
--  * pim.v_fremdprodukt_merkmal  Wettbewerberpumpen mit denselben Codes → markenübergreifender Vergleich
--
-- Befüllung aus gpi.products2 (COL1…COLn): Spalte n = n-tes Merkmal (nach DL-Id) der nächsthöheren
-- Produktgruppe mit Merkmalsliste (gpi.hlpg_dl). Läuft als Hintergrund-Job (pg_cron) in Paketen,
-- damit kein Zeitlimit greift; Fortschritt in pim.job_fortschritt.

create extension if not exists pg_cron;

alter table pim.merkmal
  add column if not exists erklaerung       text,
  add column if not exists datentyp         text,
  add column if not exists einheit_original text,
  add column if not exists faktor           numeric not null default 1,  -- Originalwert × faktor = Wert in einheit
  add column if not exists gpi_dl_id        integer,
  add column if not exists herkunft         text;

create table if not exists pim.merkmal_uebersetzung (
  merkmal_code text not null references pim.merkmal(code) on delete cascade,
  sprache      text not null,
  bezeichnung  text not null,
  erklaerung   text,
  status       text not null default 'quelle' check (status in ('quelle','maschinell','geprueft','gesperrt')),
  quelle_id    bigint references pim.quelle(id),
  primary key (merkmal_code, sprache)
);

create table if not exists pim.merkmal_alias (
  quelle_typ   text not null,              -- 'datanorm_label', 'arge', 'etim', 'hybris' …
  quell_code   text not null,
  merkmal_code text not null references pim.merkmal(code) on delete cascade,
  sprache      text,
  treffer      integer,                    -- Anzahl bestätigender Werte (bei automatischer Zuordnung)
  status       text not null default 'kandidat' check (status in ('kandidat','geprueft','abgelehnt')),
  primary key (quelle_typ, quell_code, merkmal_code)
);

create table if not exists pim.gpi_spalte (
  pgid         text not null,
  n            integer not null,           -- COLn
  merkmal_code text not null references pim.merkmal(code),
  primary key (pgid, n)
);

create table if not exists pim.gpi_produktwahl (   -- je Produktnummer eine Zeile (50 Hz bevorzugt)
  id         bigint primary key,
  artikel_id bigint not null references pim.artikel(id) on delete cascade
);

create table if not exists pim.job_fortschritt (
  job          text primary key,
  stand        bigint not null default 0,
  ziel         bigint,
  gestartet    timestamptz not null default now(),
  aktualisiert timestamptz,
  fertig       boolean not null default false,
  meldung      text
);

do $$
declare t text;
begin
  foreach t in array array['merkmal_uebersetzung','merkmal_alias','gpi_spalte','gpi_produktwahl','job_fortschritt'] loop
    execute format('alter table pim.%I enable row level security', t);
  end loop;
end $$;

-- Einheiten vereinheitlichen
create or replace function pim.einheit_norm(u text, out einheit text, out faktor numeric)
language sql immutable
as $$
  select case
           when u is null or trim(u) = '' then null
           when u in ('dgr C', 'deg C') then '°C'
           when u = 'dgr F' then '°F'
           when u = 'dgr K' then 'K'
           when u in ('dgr', 'deg') then '°'
           when u in ('dmH', 'mH') then 'm'
           when u in ('m3/h', 'm3/H') then 'm³/h'
           when u = 'Nm3/H' then 'Nm³/h'
           when u = 'm3' then 'm³'
           when u = 'cm3' then 'cm³'
           when u = 'cm2' then 'cm²'
           when u = 'm2' then 'm²'
           when u = 'kg m2' then 'kg·m²'
           when u in ('rpm', '1/min') then '1/min'
           when u in ('ohm', 'Ohm') then 'Ω'
           when u = 'muF' then 'µF'
           when u in ('um', 'micrometre') then 'µm'
           when u in ('inch', 'INCH', '"') then 'in'
           when u in ('LB', 'lb') then 'lb'
           else trim(u)
         end,
         case when u = 'dmH' then 0.1 else 1 end
$$;

-- Text → Zahl (Komma oder Punkt als Dezimaltrenner); sonst NULL
create or replace function pim.zahl(t text)
returns numeric
language sql immutable
as $$
  select case when t ~ '^\s*[-+]?\d+([.,]\d+)?\s*$' then replace(trim(t), ',', '.')::numeric end
$$;

create or replace function pim.merkmal_katalog_gpi()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;

  insert into pim.merkmal (code, bezeichnung, einheit, erklaerung, datentyp, einheit_original, faktor, gpi_dl_id, herkunft)
  select trim(d.name), coalesce(nullif(trim(d.description), ''), trim(d.name)), e.einheit, nullif(trim(d.explanation), ''),
         d.valtype, nullif(trim(d.unit), ''), e.faktor, d.id::int, 'gpi.DL'
    from gpi.dl d, lateral pim.einheit_norm(d.unit) e
   where coalesce(trim(d.name), '') <> ''
  on conflict (code) do nothing;
  get diagnostics n = row_count;
  schritt := 'Merkmale im Katalog'; anzahl := n; return next;

  insert into pim.merkmal_uebersetzung (merkmal_code, sprache, bezeichnung, erklaerung, status, quelle_id)
  select trim(d.name), 'en', coalesce(nullif(trim(d.description), ''), trim(d.name)), nullif(trim(d.explanation), ''),
         'quelle', v_quelle
    from gpi.dl d where coalesce(trim(d.name), '') <> ''
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Übersetzungen en'; anzahl := n; return next;

  -- Spaltenplan je Produktgruppe: nächsthöhere Gruppe mit Merkmalsliste
  insert into pim.gpi_spalte (pgid, n, merkmal_code)
  with hl as (select distinct hlpgid from gpi.hlpg_dl),
  zuordnung as (
    select p.id as pgid,
           (select h.id from gpi.pg h join hl on hl.hlpgid = h.id
             where p.treeplace like h.treeplace || '%' order by length(h.treeplace) desc limit 1) as hl_id
      from gpi.pg p
  )
  select z.pgid, s.n, trim(d.name)
    from zuordnung z
    join lateral (select dlid, row_number() over (order by dlid::int)::int as n
                    from gpi.hlpg_dl where hlpgid = z.hl_id) s on true
    join gpi.dl d on d.id = s.dlid
   where z.hl_id is not null
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Spaltenplan (Gruppe × Spalte)'; anzahl := n; return next;

  insert into pim.gpi_produktwahl (id, artikel_id)
  select distinct on (a.id) p.id::bigint, a.id
    from gpi.products2 p
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
   order by a.id, (p.freq = '50') desc, (p.freq = '0') desc, p.id::bigint
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Produkte zur Übernahme'; anzahl := n; return next;

  insert into pim.job_fortschritt (job, stand, ziel)
  select 'gpi_merkmale', 0, max(id) from pim.gpi_produktwahl
  on conflict (job) do nothing;
end;
$body$;

-- Hintergrund-Job: Werte in Paketen übernehmen (max. ~50 s je Aufruf, danach Commit und nächste Minute weiter)
create or replace procedure pim.gpi_merkmale_job(paket integer default 4000)
language plpgsql
as $body$
declare
  v_quelle bigint;
  v_stand bigint;
  v_ziel bigint;
  v_fertig boolean;
  t0 timestamptz := clock_timestamp();
  n bigint;
begin
  if not pg_try_advisory_lock(4242001) then
    return;
  end if;
  perform set_config('statement_timeout', '0', false);
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;
  select stand, ziel, fertig into v_stand, v_ziel, v_fertig from pim.job_fortschritt where job = 'gpi_merkmale';
  while not v_fertig and v_stand <= v_ziel and clock_timestamp() - t0 < interval '50 seconds' loop
    insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
    select w.artikel_id, s.merkmal_code, trim(c.txt), pim.zahl(c.txt) * m.faktor, '-', v_quelle
      from pim.gpi_produktwahl w
      join gpi.products2 p on p.id = w.id::text
      cross join lateral jsonb_each_text(to_jsonb(p)) kv(k, v)       -- Zeile einmal je Produkt auflösen
      join pim.gpi_spalte s on s.pgid = p.pgid and kv.k = 'col' || s.n
      join pim.merkmal m on m.code = s.merkmal_code
      join gpi.coltext c on c.id = kv.v
     where w.id between v_stand and v_stand + paket - 1
       and kv.k like 'col%' and kv.v <> '0'
       and coalesce(trim(c.txt), '') <> ''
    on conflict do nothing;
    get diagnostics n = row_count;
    v_stand := v_stand + paket;
    update pim.job_fortschritt set stand = v_stand, aktualisiert = now() where job = 'gpi_merkmale';
    commit;
  end loop;
  if v_stand > v_ziel and not v_fertig then
    update pim.job_fortschritt set fertig = true, aktualisiert = now(), meldung = 'fertig' where job = 'gpi_merkmale';
    commit;
    -- Filter-Index separat bauen (globales statement_timeout 120 s gilt für den ganzen CALL):
    --   set statement_timeout = 0; create index artikel_merkmal_code_num_idx on pim.artikel_merkmal (merkmal_code, wert_num) where wert_num is not null;
    perform cron.unschedule(jobid) from cron.job where jobname = 'gpi_merkmale';
    commit;
  end if;
  perform pg_advisory_unlock(4242001);
end;
$body$;

-- Wettbewerberpumpen mit denselben Merkmalscodes (Vergleich Wilo/KSB/… ↔ Grundfos)
create or replace view pim.v_fremdprodukt_merkmal with (security_invoker = true) as
select f.id as fremdprodukt_id, f.hersteller, f.baureihe, f.typ, f.frequenz,
       k.key as merkmal_code, k.value ->> 'wert' as wert,
       pim.zahl(k.value ->> 'wert') * coalesce(m.faktor, 1) as wert_num,
       coalesce(m.einheit, k.value ->> 'einheit') as einheit
  from pim.fremdprodukt f
  cross join lateral jsonb_each(f.daten) k
  left join pim.merkmal m on m.code = k.key;

revoke execute on function pim.merkmal_katalog_gpi() from public, anon, authenticated;
revoke execute on procedure pim.gpi_merkmale_job(integer) from public, anon, authenticated;
revoke all on pim.v_fremdprodukt_merkmal from anon, authenticated;
