-- GPC-Datenbank (Schema gpi, Stand 10/2015) in den Stamm pim übernehmen.
--
--  1. Artikel:      fehlende Produkt- und Teilenummern als 'historisch' anlegen (nichts wegwerfen)
--  2. EAN:          aus Products2 ergänzen, wo noch keine vorhanden ist (nur Grundfos-GTIN 57…)
--  3. Typbezeichnung als Alias (Suche „Unilift KP 150 M 1“), englische Teilebezeichnung als Titel
--  4. Ersatzteillisten: Pumpe/Baugruppe → Teil mit Position, Menge und Gültigkeit (Produktionszeitraum)
--  5. Wettbewerber-Austausch: Fremdpumpe (Hersteller, Typ, Daten) → Grundfos-Ersatz
--
-- Rohdaten in gpi.* bleiben unverändert. Mehrfaches Ausführen ist unschädlich (on conflict do nothing).

create table if not exists pim.querverweis_wettbewerb (
  id               bigint generated always as identity primary key,
  fremdhersteller  text not null,              -- wie in der Quelle, z. B. 'wilo'
  hersteller_name  text,                       -- Anzeigename, z. B. 'WILO'
  fremdtyp         text not null,              -- z. B. '(Star) E 25 / 1-3'
  frequenz         smallint,                   -- 50 / 60 Hz
  daten            jsonb,                      -- Phase, Anschluss, Baulänge, Q, H, P1 …
  artikel_id       bigint not null references pim.artikel(id) on delete cascade,
  menge            numeric,
  variante         smallint,                   -- Reihenfolge der Vorschläge (SystemNo)
  kommentar        text,
  status           text not null default 'kandidat' check (status in ('kandidat','geprueft','abgelehnt')),
  nachweis         text,
  quelle_id        bigint not null references pim.quelle(id),
  unique nulls not distinct (fremdhersteller, fremdtyp, frequenz, artikel_id, variante, kommentar, quelle_id)
);
create index if not exists querverweis_wettbewerb_typ_idx
  on pim.querverweis_wettbewerb using gin (fremdtyp extensions.gin_trgm_ops);
create index if not exists querverweis_wettbewerb_artikel_idx on pim.querverweis_wettbewerb (artikel_id);
alter table pim.querverweis_wettbewerb enable row level security;

-- Datum aus gpi ('MM/DD/YY hh:mm:ss'); '01/00/00' u. ä. = offen → NULL
create or replace function pim.gpi_datum(t text)
returns date
language plpgsql immutable
as $$
declare m int; d int; y int;
begin
  if t is null or t !~ '^\d{2}/\d{2}/\d{2}' then return null; end if;
  m := substr(t, 1, 2)::int; d := substr(t, 4, 2)::int; y := substr(t, 7, 2)::int;
  if m not between 1 and 12 or d not between 1 and 31 then return null; end if;
  y := case when y >= 30 then 1900 + y else 2000 + y end;
  begin
    return make_date(y, m, d);
  exception when others then
    return null;
  end;
end;
$$;

create or replace function pim.gpi_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;
  if v_quelle is null then
    raise exception 'pim.quelle für gpi.mdb fehlt (Import 2 zuerst ausführen)';
  end if;

  -- Nummern aus gpi: Produkte und Teile ------------------------------------------------
  create temp table _nr on commit drop as
  select distinct on (norm) norm, nr, ean
    from (
      select upper(replace(trim(productno), ' ', '')) as norm, trim(productno) as nr,
             case when eanno ~ '^57\d{11}$' then eanno end as ean, 1 as prio
        from gpi.products2 where coalesce(trim(productno), '') <> ''
      union all
      select upper(replace(trim(partnum), ' ', '')), trim(partnum), null, 2
        from gpi.master where coalesce(trim(partnum), '') <> ''
    ) x
   order by norm, prio, ean nulls last;

  -- 1. fehlende Artikel anlegen
  insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, ean, status)
  select 1, nr, norm, ean, 'historisch' from _nr
  on conflict (hersteller_id, artikelnummer_norm) do nothing;
  get diagnostics n = row_count;
  schritt := '1 Artikel neu (historisch)'; anzahl := n; return next;

  -- 2. EAN ergänzen
  update pim.artikel a set ean = x.ean, aktualisiert_am = now()
    from _nr x
   where a.hersteller_id = 1 and a.artikelnummer_norm = x.norm and a.ean is null and x.ean is not null;
  get diagnostics n = row_count;
  schritt := '2 EAN ergänzt'; anzahl := n; return next;

  -- Zuordnung gpi-Nummer → pim.artikel.id
  create temp table _art on commit drop as
  select x.norm, a.id from _nr x
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = x.norm;
  create index on _art (norm);
  analyze _art;

  -- 3a. Typbezeichnung als Alias
  insert into pim.artikel_alias (artikel_id, typ, wert, quelle_id)
  select distinct a.id, 'typbezeichnung', trim(pn.prodname), v_quelle
    from gpi.products2 p
    join gpi.prodnames pn on pn.id = p.prodnameid
    join _art a on a.norm = upper(replace(trim(p.productno), ' ', ''))
   where coalesce(trim(pn.prodname), '') <> ''
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '3a Typbezeichnungen'; anzahl := n; return next;

  -- 3b. Teilebezeichnung (englisch) als Titel
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select distinct on (a.id) a.id, 'en', 'titel', trim(t.pltext), v_quelle
    from gpi.master m
    join gpi.pltext t on t.textnum = m.textnum
    join _art a on a.norm = upper(replace(trim(m.partnum), ' ', ''))
   where coalesce(trim(t.pltext), '') <> ''
   order by a.id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '3b Teilebezeichnungen (en)'; anzahl := n; return next;

  -- 4. Ersatzteillisten -------------------------------------------------------------------
  create temp table _gueltig on commit drop as
  select id, pim.gpi_datum(validfrom) as von, pim.gpi_datum(validto) as bis, changenoteid
    from gpi.partvalidity;
  create index on _gueltig (id);

  create temp table _teil on commit drop as
  select m.partid, a.id as artikel_id
    from gpi.master m
    join _art a on a.norm = upper(replace(trim(m.partnum), ' ', ''));
  create index on _teil (partid);
  analyze _teil;

  insert into pim.artikel_beziehung
         (von_artikel_id, zu_artikel_id, typ, menge, position, produktion_von, produktion_bis,
          status, nachweis, quelle_id)
  select v.artikel_id, z.artikel_id, 'ersatzteil',
         round(nullif(np.nopp, '')::numeric, 4),
         nullif(nullif(trim(pn.posnum), ''), '.'),
         g.von, g.bis, 'geprueft',
         'gpi.mdb PartList ' || l.plid || coalesce(' · ChangeNote ' || g.changenoteid, ''),
         v_quelle
    from gpi.partlist l
    join _teil v on v.partid = l.plid
    join gpi.partdetails d on d.id = l.partdetailid
    join _teil z on z.partid = d.partid
    left join gpi.nopp np on np.id = d.noppid
    left join gpi.posnum pn on pn.id = d.posnumid
    left join _gueltig g on g.id = d.partvalidityid
   where v.artikel_id <> z.artikel_id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '4 Ersatzteil-Beziehungen'; anzahl := n; return next;

  -- 5. Wettbewerber-Austausch (50 und 60 Hz) ---------------------------------------------
  insert into pim.querverweis_wettbewerb
         (fremdhersteller, hersteller_name, fremdtyp, frequenz, daten, artikel_id, menge, variante,
          kommentar, status, nachweis, quelle_id)
  select s.manufacturer,
         (select min(mn.displayname) from gpi.replmanufactname mn where mn.manufacturer = s.manufacturer),
         trim(s.designation), s.hz,
         jsonb_strip_nulls(jsonb_build_object(
           'phase', s.phase, 'druckstufe', s.pressstage, 'anschluss', s.pipecon, 'baulaenge_mm', s.l,
           'q', s.q, 'h', s.h, 'p1_min', s.p1min, 'p1_max', s.p1max, 'p1_mittel', s.p1avg,
           'zwillingspumpe', s.twinpump, 'trinkwasser', s.drinkingwater)),
         a.id, nullif(p.noof, '')::numeric, nullif(p.systemno, '')::smallint, nullif(trim(p.comment), ''),
         'geprueft', 'gpi.mdb ReplSystem' || s.hz || ' ' || s.replid, v_quelle
    from (select *, 50::smallint as hz from gpi.replsystem50
          union all select *, 60::smallint from gpi.replsystem60) s
    join (select *, 50::smallint as hz from gpi.replpumps50
          union all select *, 60::smallint from gpi.replpumps60) p on p.replid = s.replid and p.hz = s.hz
    join _art a on a.norm = upper(replace(trim(p.productno), ' ', ''))
   where coalesce(trim(s.designation), '') <> ''
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '5 Wettbewerber-Austausch'; anzahl := n; return next;
end;
$body$;

revoke execute on function pim.gpi_uebernehmen() from public, anon, authenticated;
