-- Vorprüfung: fehlende/unklare Preisart (netto/brutto) mit Begründung abweisen
-- (bisher Status „fehler“ ohne Text, weil „null not in (…)“ in import_verarbeiten keinen Fall trifft)
create or replace function marktbegleiter.import_vorpruefen(p_import bigint)
returns void language sql set search_path = marktbegleiter, public as $$
  update marktbegleiter.import_zeilen z set status = 'fehler', fehler = 'preis_typ fehlt oder unklar – „netto“ oder „brutto“ angeben'
   where z.import_id = p_import and z.status = 'neu' and (z.preis_typ is null or z.preis_typ not in ('netto', 'brutto'));
  update marktbegleiter.import_zeilen z set fehler = 'Hinweis: EAN ungültig (' || z.ean || ') – ignoriert'
   where z.import_id = p_import and z.status = 'neu' and nullif(btrim(z.ean), '') is not null and marktbegleiter.gtin_norm(z.ean) is null;
  with d as (select import_id, zeile, row_number() over (
                      partition by coalesce(marktbegleiter.hersteller_norm(hersteller), 'GRUNDFOS'), marktbegleiter.nr_norm(mpn),
                                   marktbegleiter.gtin_norm(ean), case when marktbegleiter.nr_norm(mpn) is null
                                   and marktbegleiter.gtin_norm(ean) is null then lower(btrim(bezeichnung)) end,
                                   coalesce(staffel_ab, 1), preis, preis_typ, coalesce(waehrung, 'EUR'), erfasst_am
                      order by zeile) as nr
               from marktbegleiter.import_zeilen where import_id = p_import and status = 'neu' and preis is not null)
  update marktbegleiter.import_zeilen z set status = 'dublette', fehler = 'gleiche Position mehrfach in der Datei'
    from d where d.import_id = z.import_id and d.zeile = z.zeile and d.nr > 1;
$$;
revoke all on function marktbegleiter.import_vorpruefen(bigint) from public, anon, authenticated;
