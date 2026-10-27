-- Eigener Bereich (Schema) „markt“: Marktbegleiter und ihre Preise (27.10.2026)
--
-- Getrennt vom Grundfos-Stamm (pim), aber in derselben Datenbank, damit Preise direkt über Artikelnummer/EAN mit
-- unserem Stamm verglichen werden können. Vertraulich: kein Zugriff über die öffentliche API (anon/authenticated).
--
--  markt.marktbegleiter  wer (Name, Land, Art, Kontakt …) – übernommen aus pim.wettbewerber (Recherche)
--  markt.preisliste      eine gelieferte Datei bzw. eine Recherche: von wem, Stand, Währung, netto/brutto
--  markt.preis           eine Preiszeile: Artikelnummer/EAN/Bezeichnung wie geliefert, zugeordneter Grundfos-Artikel,
--                        Preis, Währung, Preis in EUR, Staffel, Verfügbarkeit
--  markt.preise_zuordnen()  ordnet Zeilen ohne Artikel über Artikelnummer, EAN, Alias zu
--  markt.v_preisvergleich   je Grundfos-Artikel und Land: neuester Preis je Marktbegleiter, Minimum, Median, Maximum

create schema if not exists markt;
revoke all on schema markt from anon, authenticated;
comment on schema markt is 'Marktbegleiter und ihre Preise – vertraulich, nur intern';

-- bisherige Recherche-Tabellen (0035) hierher verschieben
alter table if exists pim.wettbewerber set schema markt;
alter table if exists markt.wettbewerber rename to marktbegleiter;
alter table markt.marktbegleiter add column if not exists kontakt text;
alter table markt.marktbegleiter add column if not exists aktiv boolean not null default true;

create table if not exists markt.preisliste (
  id               bigserial primary key,
  marktbegleiter_id bigint not null references markt.marktbegleiter(id) on delete cascade,
  bezeichnung      text,                       -- z. B. Dateiname oder „Recherche Suchmaschinen“
  datei_id         bigint references raw.quelldatei(id) on delete set null,   -- Originaldatei (unverändert in raw)
  stand            date not null default current_date,
  waehrung         text not null default 'EUR',
  preisart         text not null default 'brutto' check (preisart in ('brutto', 'netto')),
  zeilen           integer,
  zugeordnet       integer,
  eingegangen_am   timestamptz not null default now(),
  notiz            text
);
alter table markt.preisliste enable row level security;

alter table if exists pim.marktpreis set schema markt;
alter table if exists markt.marktpreis rename to preis;
alter table markt.preis rename column wettbewerber_id to marktbegleiter_id;
alter table markt.preis add column if not exists preisliste_id bigint references markt.preisliste(id) on delete cascade;
alter table markt.preis add column if not exists artikelnummer_roh text;
alter table markt.preis add column if not exists ean_roh text;
alter table markt.preis add column if not exists preisart text not null default 'brutto';
alter table markt.preis add column if not exists staffel_ab numeric;
alter table markt.preis add column if not exists daten jsonb;          -- komplette Originalzeile
alter table markt.preis alter column land drop not null;
drop index if exists pim.marktpreis_artikel_idx;
create index if not exists preis_artikel_idx on markt.preis (artikel_id, land, datum);
create index if not exists preis_liste_idx on markt.preis (preisliste_id);

drop view if exists pim.v_marktpreis_aktuell;

-- Recherche vom 27.10. als eigene Preisliste je Marktbegleiter ablegen
insert into markt.preisliste (marktbegleiter_id, bezeichnung, stand, waehrung, preisart, notiz)
select distinct p.marktbegleiter_id, 'Recherche Suchmaschinen/Preisportale', p.datum, p.waehrung, 'brutto',
       'unverifiziert (Suchergebnis-Ausschnitte)'
  from markt.preis p where p.marktbegleiter_id is not null and p.preisliste_id is null;
update markt.preis p set preisliste_id = l.id
  from markt.preisliste l
 where p.preisliste_id is null and l.marktbegleiter_id = p.marktbegleiter_id and l.stand = p.datum
   and l.bezeichnung = 'Recherche Suchmaschinen/Preisportale';

create or replace function markt.preise_zuordnen(p_preisliste bigint default null)
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = markt, pim, public
as $body$
declare n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  update markt.preis p set artikel_id = a.id
    from pim.artikel a
   where p.artikel_id is null and (p_preisliste is null or p.preisliste_id = p_preisliste)
     and a.hersteller_id = 1
     and a.artikelnummer_norm = upper(regexp_replace(coalesce(p.artikelnummer_roh, p.artikelnummer_im_shop), '[^0-9A-Za-z]', '', 'g'));
  get diagnostics n = row_count; schritt := 'über Artikelnummer'; anzahl := n; return next;

  update markt.preis p set artikel_id = a.id
    from pim.artikel a
   where p.artikel_id is null and (p_preisliste is null or p.preisliste_id = p_preisliste)
     and a.hersteller_id = 1 and a.ean = regexp_replace(p.ean_roh, '\D', '', 'g');
  get diagnostics n = row_count; schritt := 'über EAN'; anzahl := n; return next;

  update markt.preis p set artikel_id = al.artikel_id   -- Großhandelsnummern (VVS)
    from pim.artikel_alias al
   where p.artikel_id is null and (p_preisliste is null or p.preisliste_id = p_preisliste)
     and al.typ = 'vvs' and al.wert = btrim(coalesce(p.artikelnummer_roh, p.artikelnummer_im_shop));
  get diagnostics n = row_count; schritt := 'über Großhandelsnummer'; anzahl := n; return next;

  update markt.preisliste l set zeilen = x.n, zugeordnet = x.z
    from (select preisliste_id, count(*) n, count(artikel_id) z from markt.preis group by 1) x
   where x.preisliste_id = l.id and (p_preisliste is null or l.id = p_preisliste);
end;
$body$;

create or replace view markt.v_preisvergleich with (security_invoker = true) as
with neu as (   -- je Artikel und Marktbegleiter der neueste Preis (Staffel: kleinste Menge)
  select distinct on (p.artikel_id, coalesce(p.marktbegleiter_id, -1), p.shop)
         p.artikel_id, p.marktbegleiter_id, p.shop, coalesce(p.land, b.land) as land, p.preis_brutto, p.waehrung,
         p.preis_eur, p.preisart, p.datum, p.url
    from markt.preis p left join markt.marktbegleiter b on b.id = p.marktbegleiter_id
   where p.artikel_id is not null and p.preis_eur is not null
   order by p.artikel_id, coalesce(p.marktbegleiter_id, -1), p.shop, p.datum desc, p.staffel_ab nulls first
)
select n.artikel_id, a.artikelnummer, n.land, n.preisart,
       count(*) as anbieter,
       min(n.preis_eur) as min_eur,
       percentile_cont(0.5) within group (order by n.preis_eur) as median_eur,
       max(n.preis_eur) as max_eur,
       (array_agg(n.shop order by n.preis_eur))[1] as guenstigster,
       max(n.datum) as stand
  from neu n join pim.artikel a on a.id = n.artikel_id
 group by n.artikel_id, a.artikelnummer, n.land, n.preisart;

revoke all on all tables in schema markt from anon, authenticated;
revoke execute on function markt.preise_zuordnen(bigint) from public, anon, authenticated;
