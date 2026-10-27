-- Rückbau von 0036 (Vorgabe 27.10.2026: bestehende Tabellen pim.wettbewerber / pim.marktpreis nicht verändern).
-- 0036 hatte beide Tabellen nach Schema „markt“ verschoben, umbenannt und ergänzt. Hier wird der Zustand von 0035
-- exakt wiederhergestellt (Namen, Spalten, Index, Ansicht, Daten); das Schema „markt“ entfällt.
-- Die neue Marktbegleiter-Datenbank entsteht in 0038 als Schema „marktbegleiter“ (Kopie der Daten).

drop view if exists markt.v_preisvergleich;
drop function if exists markt.preise_zuordnen(bigint);

alter table markt.preis drop column if exists preisliste_id;
alter table markt.preis drop column if exists artikelnummer_roh;
alter table markt.preis drop column if exists ean_roh;
alter table markt.preis drop column if exists preisart;
alter table markt.preis drop column if exists staffel_ab;
alter table markt.preis drop column if exists daten;
alter table markt.preis rename column marktbegleiter_id to wettbewerber_id;
alter table markt.preis alter column land set not null;
drop index if exists markt.preis_artikel_idx;
drop index if exists markt.preis_liste_idx;
alter table markt.preis rename to marktpreis;
alter table markt.marktpreis set schema pim;
create index if not exists marktpreis_artikel_idx on pim.marktpreis (artikel_id, land, datum);

drop table if exists markt.preisliste;   -- nur in 0036 abgeleitete Zeilen (je Shop eine „Recherche“-Liste)

alter table markt.marktbegleiter drop column if exists kontakt;
alter table markt.marktbegleiter drop column if exists aktiv;
alter table markt.marktbegleiter rename to wettbewerber;
alter table markt.wettbewerber set schema pim;

drop schema if exists markt;

create or replace view pim.v_marktpreis_aktuell with (security_invoker = true) as
select m.artikel_id, a.artikelnummer, m.land,
       count(*) as angebote,
       min(m.preis_eur) as min_eur,
       percentile_cont(0.5) within group (order by m.preis_eur) as median_eur,
       max(m.preis_eur) as max_eur,
       (array_agg(m.shop order by m.preis_eur))[1] as guenstigster_shop,
       max(m.datum) as stand
  from pim.marktpreis m
  join pim.artikel a on a.id = m.artikel_id
 where m.datum >= current_date - 90 and m.preis_eur is not null
 group by m.artikel_id, a.artikelnummer, m.land;
