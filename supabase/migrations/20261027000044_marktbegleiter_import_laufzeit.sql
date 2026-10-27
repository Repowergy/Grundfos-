-- Laufzeit großer Importe (Import 10, z. B. BaumarktEU): import_verarbeiten hing > 1,5 h, weil die Statistik der
-- Zwischenablage veraltet war (frisch per COPY geladene, noch nicht festgeschriebene Zeilen) und der Planer daraufhin
-- verschachtelte Schleifen wählte (quadratisch). Jetzt: ANALYZE der betroffenen Tabellen im Lauf und Hash-Verknüpfungen
-- erzwungen (enable_nestloop nur für diese Transaktion). Inhaltlich unverändert gegenüber 0039.
create or replace function marktbegleiter.import_verarbeiten(p_import bigint)
returns table (schritt text, anzahl bigint)
language plpgsql set search_path = marktbegleiter, public as $$
declare v_firma bigint; v_land text; v_stand date; v_preisart text; n bigint; v_fehler jsonb;
begin
  perform set_config('statement_timeout', '0', true);
  -- große Importe: Statistik der Zwischenablage aktualisieren (die Zeilen sind noch nicht festgeschrieben, die alten Werte
  -- führen sonst zu verschachtelten Schleifen mit quadratischer Laufzeit) und Hash-Verknüpfungen erzwingen
  perform set_config('enable_nestloop', 'off', true);
  analyze marktbegleiter.import_zeilen;
  select i.firma_id, f.land, coalesce(i.stand, current_date), coalesce(i.preisart, 'oeffentlich')
    into v_firma, v_land, v_stand, v_preisart
    from marktbegleiter.importe i join marktbegleiter.firmen f on f.id = i.firma_id where i.id = p_import;
  if v_firma is null then raise exception 'Import % ohne Firma', p_import; end if;
  update marktbegleiter.importe set status = 'verarbeitung' where id = p_import;
  perform marktbegleiter.import_vorpruefen(p_import);

  -- Prüfen
  update marktbegleiter.import_zeilen z set status = 'fehler', fehler = case
           when z.preis is null then 'kein Preis erkannt'
           when z.preis <= 0 then 'Preis ≤ 0'
           when marktbegleiter.nr_norm(z.mpn) is null and marktbegleiter.gtin_norm(z.ean) is null and coalesce(btrim(z.bezeichnung), '') = ''
             then 'weder Artikelnummer, gültige EAN noch Bezeichnung'
           when z.preis_typ not in ('netto', 'brutto') then 'Preisart netto/brutto unklar'
         end
   where z.import_id = p_import and z.status = 'neu'
     and (z.preis is null or z.preis <= 0 or z.preis_typ is null or z.preis_typ not in ('netto', 'brutto')
          or (marktbegleiter.nr_norm(z.mpn) is null and marktbegleiter.gtin_norm(z.ean) is null and coalesce(btrim(z.bezeichnung), '') = ''));
  update marktbegleiter.import_zeilen z set status = 'fehler', fehler = 'Wechselkurs für ' || z.waehrung || ' fehlt'
   where z.import_id = p_import and z.status = 'neu' and coalesce(z.waehrung, 'EUR') <> 'EUR'
     and not exists (select 1 from marktbegleiter.wechselkurse k where k.waehrung = z.waehrung
                      and k.datum <= coalesce(z.erfasst_am, v_stand));

  -- Produkte (eine Zeile je Firma + Schlüssel)
  insert into marktbegleiter.produkte (firma_id, hersteller, hersteller_norm, mpn, mpn_norm, ean, bezeichnung, baureihe, kategorie,
                                       url, schluessel)
  select distinct on (s.schluessel) v_firma, s.hersteller, s.hn, s.mpn, s.mn, s.gt, s.bezeichnung, s.baureihe, s.kategorie, s.url,
         s.schluessel
    from (select z.*, marktbegleiter.hersteller_norm(z.hersteller) hn, marktbegleiter.nr_norm(z.mpn) mn,
                 marktbegleiter.gtin_norm(z.ean) gt,
                 coalesce(coalesce(marktbegleiter.hersteller_norm(z.hersteller), 'GRUNDFOS') || ':' || marktbegleiter.nr_norm(z.mpn),
                          'EAN:' || marktbegleiter.gtin_norm(z.ean), 'TXT:' || md5(lower(btrim(z.bezeichnung)))) as schluessel
            from marktbegleiter.import_zeilen z where z.import_id = p_import and z.status = 'neu') s
   order by s.schluessel, s.zeile
  on conflict (firma_id, schluessel) do update
     set ean = coalesce(marktbegleiter.produkte.ean, excluded.ean),
         bezeichnung = coalesce(marktbegleiter.produkte.bezeichnung, excluded.bezeichnung),
         baureihe = coalesce(marktbegleiter.produkte.baureihe, excluded.baureihe),
         kategorie = coalesce(marktbegleiter.produkte.kategorie, excluded.kategorie),
         url = coalesce(excluded.url, marktbegleiter.produkte.url);
  analyze marktbegleiter.produkte;
  update marktbegleiter.import_zeilen z set produkt_id = p.id
    from marktbegleiter.produkte p
   where z.import_id = p_import and z.status = 'neu' and p.firma_id = v_firma
     and p.schluessel = coalesce(coalesce(marktbegleiter.hersteller_norm(z.hersteller), 'GRUNDFOS') || ':' || marktbegleiter.nr_norm(z.mpn),
                                 'EAN:' || marktbegleiter.gtin_norm(z.ean), 'TXT:' || md5(lower(btrim(z.bezeichnung))));

  -- Preise (Historie; Dubletten werden übersprungen und gezählt)
  with q as (
    select z.*, coalesce(z.ust_satz, u.satz, 0) as ust, coalesce(z.waehrung, 'EUR') as whg,
           k.eur_je_einheit as kurs, k.datum as kdatum, k.quelle as kquelle
      from marktbegleiter.import_zeilen z
      left join marktbegleiter.ust_saetze u on u.land = coalesce(z.land, v_land)
      left join lateral (select * from marktbegleiter.wechselkurse k where k.waehrung = coalesce(z.waehrung, 'EUR')
                          and k.datum <= coalesce(z.erfasst_am, v_stand) order by k.datum desc limit 1) k on true
     where z.import_id = p_import and z.status = 'neu' and z.produkt_id is not null),
  ins as (
    insert into marktbegleiter.preise (firma_id, produkt_id, import_id, originalpreis, original_typ, waehrung, ust_satz,
                preis_netto, preis_brutto, wechselkurs, wechselkurs_datum, wechselkurs_quelle, preis_eur_netto, preis_eur_brutto,
                preiseinheit, mengeneinheit, mindestmenge, staffel_ab, versand, versand_eur, lagerbestand, lieferbar, lieferzeit,
                gueltig_ab, gueltig_bis, erfasst_am, quelle_url, quelldatei, preisart)
    select v_firma, q.produkt_id, p_import, q.preis, q.preis_typ, q.whg, q.ust,
           case when q.preis_typ = 'netto' then q.preis else round(q.preis / (1 + q.ust / 100), 4) end,
           case when q.preis_typ = 'brutto' then q.preis else round(q.preis * (1 + q.ust / 100), 4) end,
           q.kurs, q.kdatum, q.kquelle,
           round((case when q.preis_typ = 'netto' then q.preis else q.preis / (1 + q.ust / 100) end) * q.kurs, 4),
           round((case when q.preis_typ = 'brutto' then q.preis else q.preis * (1 + q.ust / 100) end) * q.kurs, 4),
           coalesce(q.preiseinheit, 1), coalesce(q.mengeneinheit, 'Stück'), q.mindestmenge, coalesce(q.staffel_ab, 1),
           q.versand, round(q.versand * q.kurs, 2), q.lagerbestand,
           case when q.lagerbestand ~* '(nicht|kein|ausverkauft|out of stock|0 st)' then false
                when q.lagerbestand ~* '(lager|verfügbar|available|in stock|sofort|\d+\s*st)' then true end,
           q.lieferzeit, q.gueltig_ab, q.gueltig_bis, coalesce(q.erfasst_am, v_stand), q.quelle_url,
           (select dateiname from marktbegleiter.importe where id = p_import), coalesce(q.preisart, v_preisart)
      from q
    on conflict do nothing
    returning id, produkt_id, staffel_ab, erfasst_am, originalpreis)
  update marktbegleiter.import_zeilen z set status = 'ok', preis_id = ins.id
    from ins
   where z.import_id = p_import and z.status = 'neu' and z.produkt_id = ins.produkt_id
     and coalesce(z.staffel_ab, 1) = ins.staffel_ab and z.preis = ins.originalpreis;
  update marktbegleiter.import_zeilen set status = 'dublette', fehler = 'gleicher Preis bereits erfasst'
   where import_id = p_import and status = 'neu';

  analyze marktbegleiter.preise;
  perform marktbegleiter.produkte_zuordnen(p_import);

  select coalesce(jsonb_agg(jsonb_build_object('zeile', zeile, 'fehler', fehler, 'mpn', mpn, 'ean', ean) order by zeile), '[]')
    into v_fehler from (select * from marktbegleiter.import_zeilen where import_id = p_import and status = 'fehler' limit 500) f;
  update marktbegleiter.importe i set
         positionen = x.alle, fehlerhaft = x.fehler, dubletten = x.dub,
         zugeordnet = x.zu, vorschlaege = x.vor, nicht_zugeordnet = x.ohne,
         fehlerprotokoll = v_fehler,
         status = case when x.alle = 0 then 'fehler' when x.fehler > 0 then 'teilweise' else 'fertig' end
    from (select count(*) alle, count(*) filter (where z.status = 'fehler') fehler, count(*) filter (where z.status = 'dublette') dub,
                 count(distinct z.produkt_id) filter (where p.artikel_id is not null) zu,
                 count(distinct z.produkt_id) filter (where p.matching_status = 'vorschlag') vor,
                 count(distinct z.produkt_id) filter (where z.produkt_id is not null and p.artikel_id is null
                                                       and p.matching_status <> 'vorschlag') ohne
            from marktbegleiter.import_zeilen z left join marktbegleiter.produkte p on p.id = z.produkt_id
           where z.import_id = p_import) x
   where i.id = p_import;
  update marktbegleiter.firmen f set letzte_preisliste = greatest(f.letzte_preisliste, v_stand), geaendert_am = now()
   where f.id = v_firma;

  return query select 'Positionen'::text, positionen::bigint from marktbegleiter.importe where id = p_import
     union all select 'zugeordnet (Produkte)', zugeordnet::bigint from marktbegleiter.importe where id = p_import
     union all select 'Vorschläge zur Kontrolle', vorschlaege::bigint from marktbegleiter.importe where id = p_import
     union all select 'nicht zugeordnet', nicht_zugeordnet::bigint from marktbegleiter.importe where id = p_import
     union all select 'fehlerhaft', fehlerhaft::bigint from marktbegleiter.importe where id = p_import
     union all select 'Dubletten', dubletten::bigint from marktbegleiter.importe where id = p_import;
end $$;
revoke all on function marktbegleiter.import_verarbeiten(bigint) from public, anon, authenticated;
