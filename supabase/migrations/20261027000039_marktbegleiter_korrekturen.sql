-- Korrekturen nach dem Testimport (27.10.2026)
--  1. Dubletten innerhalb einer Datei vor dem Speichern markieren (Status „dublette“, nicht „ok“)
--  2. Vorschlag über Bezeichnung: Kandidaten per Trigramm-Ähnlichkeit, bewertet nach Wort-Ähnlichkeit
--     („SCALA2 3-45“ steckt in „Grundfos SCALA2 3-45 Druckerhöhung“); weiterhin nur Vorschlag
--  3. ungültige EAN (Prüfziffer/Länge) als Hinweis an der Zeile vermerken

create or replace function marktbegleiter.produkte_zuordnen(p_import bigint default null, p_neu_pruefen boolean default false)
returns table (schritt text, anzahl bigint)
language plpgsql set search_path = marktbegleiter, pim, public, extensions as $$
declare n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  perform set_config('pg_trgm.similarity_threshold', '0.3', true);
  drop table if exists _p;
  create temp table _p on commit drop as
  select p.* from marktbegleiter.produkte p
   where (p_import is null or exists (select 1 from marktbegleiter.preise x where x.produkt_id = p.id and x.import_id = p_import))
     and (p.matching_status in ('offen', 'kein_treffer') or (p_neu_pruefen and p.matching_status in ('vorschlag')));

  with t as (select p.id, a.id as artikel_id from _p p
               join pim.hersteller h on upper(h.name) = coalesce(p.hersteller_norm, 'GRUNDFOS')
               join pim.artikel a on a.hersteller_id = h.id and a.artikelnummer_norm = p.mpn_norm
              where p.mpn_norm is not null)
  update marktbegleiter.produkte p set artikel_id = t.artikel_id, matching_status = 'eindeutig_mpn', gematcht_am = now(),
         matching_hinweis = case when p.hersteller_norm is null then 'Hersteller nicht angegeben – Grundfos angenommen' end
    from t where t.id = p.id;
  get diagnostics n = row_count; schritt := '1 Hersteller + Artikelnummer'; anzahl := n; return next;

  with k as (select ean, min(id) as artikel_id from pim.artikel where ean is not null
              and ean in (select ean from _p where ean is not null) group by ean having count(*) = 1)
  update marktbegleiter.produkte p set artikel_id = k.artikel_id, matching_status = 'eindeutig_ean', gematcht_am = now()
    from k where p.id in (select id from _p) and p.matching_status in ('offen', 'kein_treffer', 'vorschlag') and p.ean = k.ean;
  get diagnostics n = row_count; schritt := '2 EAN'; anzahl := n; return next;

  with k as (select al.wert, min(al.artikel_id) as artikel_id from pim.artikel_alias al
              where al.typ = 'vvs' and al.wert in (select btrim(mpn) from _p where mpn is not null)
              group by al.wert having count(distinct al.artikel_id) = 1)
  update marktbegleiter.produkte p set artikel_id = k.artikel_id, matching_status = 'eindeutig_alternativ', gematcht_am = now(),
         matching_hinweis = 'über Großhandelsnummer (VVS)'
    from k where p.id in (select id from _p) and p.matching_status in ('offen', 'kein_treffer', 'vorschlag') and btrim(p.mpn) = k.wert;
  get diagnostics n = row_count; schritt := '3 Großhandelsnummer'; anzahl := n; return next;

  with b as (select p.id, btrim(regexp_replace(upper(p.bezeichnung),
                    'GRUNDFOS|UMWÄLZPUMPE|HOCHEFFIZIENZ[A-ZÄÖÜ-]*|DRUCKERHÖHUNG[A-ZÄÖÜ-]*|PUMPE|HEBEANLAGE', ' ', 'g')) as txt
               from marktbegleiter.produkte p
              where p.id in (select id from _p) and p.matching_status in ('offen', 'kein_treffer') and p.bezeichnung is not null
                and p.vorschlag_artikel_id is null),
       k as (select b.id, al.artikel_id, al.wert, word_similarity(al.wert, b.txt) as s
               from b join pim.artikel_alias al on al.typ = 'typbezeichnung' and al.wert % b.txt),
       v as (select distinct on (id) id, artikel_id, wert, s, count(*) over (partition by id, wert) as varianten
               from k where s >= 0.8 order by id, s desc, length(wert) desc)
  update marktbegleiter.produkte p set vorschlag_artikel_id = v.artikel_id, matching_status = 'vorschlag', gematcht_am = now(),
         matching_hinweis = 'Vorschlag über Bezeichnung „' || v.wert || '“ (Ähnlichkeit ' || round(v.s::numeric, 2) || ', '
                            || v.varianten || ' Artikel mit diesem Typ) – bitte prüfen'
    from v where v.id = p.id;
  get diagnostics n = row_count; schritt := '4 Vorschlag (Bezeichnung)'; anzahl := n; return next;

  update marktbegleiter.produkte p set matching_status = 'kein_treffer', gematcht_am = now()
   where p.id in (select id from _p) and p.matching_status = 'offen';
  get diagnostics n = row_count; schritt := 'kein Treffer'; anzahl := n; return next;
end $$;

-- Dubletten innerhalb der Datei und ungültige EAN vor der Verarbeitung kennzeichnen
create or replace function marktbegleiter.import_vorpruefen(p_import bigint)
returns void language sql set search_path = marktbegleiter, public as $$
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
revoke all on function marktbegleiter.produkte_zuordnen(bigint, boolean) from public, anon, authenticated;

-- import_verarbeiten: ruft zuerst import_vorpruefen auf (sonst unverändert gegenüber 0038)
create or replace function marktbegleiter.import_verarbeiten(p_import bigint)
returns table (schritt text, anzahl bigint)
language plpgsql set search_path = marktbegleiter, public as $$
declare v_firma bigint; v_land text; v_stand date; v_preisart text; n bigint; v_fehler jsonb;
begin
  perform set_config('statement_timeout', '0', true);
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
