-- Qualitäts-Score je Artikel und automatischer Nachlauf nach der Merkmal-Übernahme.
--
--  pim.artikel_qualitaet (materialisiert): was je Artikel vorhanden ist + Punkte 0–100.
--    Arbeitsliste für die Datenpflege und Filter für den Shop-Export (z. B. nur Artikel ab 60 Punkten).
--  pim.nachlauf_schritt(): je Minute ein Schritt nach Ende von gpi_merkmale: merkmale_lernen(), medien_aus_merkmalen(),
--    Qualitäts-Score berechnen – und beendet seinen Zeitplan selbst.

create materialized view if not exists pim.artikel_qualitaet as
with m as (select artikel_id, count(*) as merkmale from pim.artikel_merkmal group by 1),
     t as (select artikel_id,
                  bool_or(art in ('kurz1', 'kurz2', 'titel') and sprache = 'de') as kurztext,   -- Titel der Grundfos-Website zählt
                  bool_or(art = 'lang' and sprache = 'de') as langtext,
                  bool_or(art = 'technik' and sprache = 'de') as techniktext,
                  count(distinct sprache) filter (where sprache not in ('-')) as sprachen
             from pim.artikel_text group by 1),
     p as (select distinct artikel_id from pim.artikel_preis),
     b as (select artikel_id, bool_or(rolle = 'hauptbild') as bild, bool_or(rolle in ('massbild', 'explosionszeichnung')) as zeichnung,
                  bool_or(rolle = 'dokument') as dokument
             from pim.artikel_medium group by 1),
     gd as (select distinct ag.artikel_id from pim.artikel_gruppe ag join pim.gruppe_medium gm on gm.gruppe_id = ag.gruppe_id),
     el as (select distinct von_artikel_id as artikel_id from pim.artikel_beziehung where typ = 'ersatzteil'),
     et as (select distinct zu_artikel_id as artikel_id from pim.artikel_beziehung where typ = 'ersatzteil'),
     ty as (select distinct artikel_id from pim.artikel_alias where typ = 'typbezeichnung'),
     ws as (select distinct artikel_id from pim.querverweis_wettbewerb)
select a.id as artikel_id, a.status,
       a.ean is not null as ean, p.artikel_id is not null as preis,
       coalesce(t.kurztext, false) as kurztext, coalesce(t.langtext, false) as langtext,
       coalesce(t.techniktext, false) as techniktext, coalesce(t.sprachen, 0) as sprachen,
       coalesce(m.merkmale, 0) as merkmale,
       coalesce(b.bild, false) as bild, coalesce(b.zeichnung, false) as zeichnung,
       coalesce(b.dokument, false) or gd.artikel_id is not null as dokument,
       el.artikel_id is not null as hat_ersatzteilliste, et.artikel_id is not null as ist_ersatzteil,
       ty.artikel_id is not null as typbezeichnung, ws.artikel_id is not null as austausch_ziel,
       a.hersteller_url is not null as hersteller_link, a.kategorie_id is not null as kategorie,
       ( 15 * (p.artikel_id is not null)::int
       + 10 * (a.ean is not null)::int
       + 15 * coalesce(t.kurztext, false)::int
       + 10 * coalesce(t.langtext, false)::int
       + 10 * least(coalesce(m.merkmale, 0), 20) / 20
       + 10 * coalesce(b.bild, false)::int
       +  5 * coalesce(b.zeichnung, false)::int
       + 10 * (coalesce(b.dokument, false) or gd.artikel_id is not null)::int
       +  5 * (ty.artikel_id is not null)::int
       +  5 * (el.artikel_id is not null or et.artikel_id is not null)::int
       +  3 * (a.hersteller_url is not null)::int
       +  2 * (a.kategorie_id is not null)::int ) as punkte
  from pim.artikel a
  left join m on m.artikel_id = a.id
  left join t on t.artikel_id = a.id
  left join p on p.artikel_id = a.id
  left join b on b.artikel_id = a.id
  left join gd on gd.artikel_id = a.id
  left join el on el.artikel_id = a.id
  left join et on et.artikel_id = a.id
  left join ty on ty.artikel_id = a.id
  left join ws on ws.artikel_id = a.id
with no data;
create unique index if not exists artikel_qualitaet_pk on pim.artikel_qualitaet (artikel_id);
create index if not exists artikel_qualitaet_punkte_idx on pim.artikel_qualitaet (punkte);
revoke all on pim.artikel_qualitaet from anon, authenticated;

-- Je Aufruf ein Schritt (eigene Transaktion); Aufruf per pg_cron mit „set statement_timeout = 0; select pim.nachlauf_schritt();“
create or replace function pim.nachlauf_schritt()
returns text
language plpgsql
set search_path = pim, public
as $body$
declare
  v_schritt bigint;
begin
  if not coalesce((select fertig from pim.job_fortschritt where job = 'gpi_merkmale'), false) then
    return 'wartet auf gpi_merkmale';
  end if;
  insert into pim.job_fortschritt (job, stand, ziel) values ('nachlauf', 0, 3) on conflict (job) do nothing;
  select stand into v_schritt from pim.job_fortschritt where job = 'nachlauf' for update;
  if v_schritt = 0 then
    insert into pim.job_protokoll (job, schritt, anzahl) select 'nachlauf', schritt, anzahl from pim.merkmale_lernen();
  elsif v_schritt = 1 then
    insert into pim.job_protokoll (job, schritt, anzahl) select 'nachlauf', schritt, anzahl from pim.medien_aus_merkmalen();
  elsif v_schritt = 2 then
    refresh materialized view pim.artikel_qualitaet;
    insert into pim.job_protokoll (job, schritt, anzahl) select 'nachlauf', 'Qualitäts-Score berechnet', count(*) from pim.artikel_qualitaet;
  else
    update pim.job_fortschritt set fertig = true, aktualisiert = now(), meldung = 'fertig' where job = 'nachlauf';
    perform cron.unschedule(jobid) from cron.job where jobname = 'nachlauf';
    return 'fertig';
  end if;
  update pim.job_fortschritt set stand = v_schritt + 1, aktualisiert = now() where job = 'nachlauf';
  return 'Schritt ' || (v_schritt + 1) || ' erledigt';
end;
$body$;
revoke execute on function pim.nachlauf_schritt() from public, anon, authenticated;
