-- Marktbegleiter: Prüfung 27.10.2026 + direkte Einlieferung für OpenClaw (Scraping-Agent)
--  1. Wechselkurse: EZB-Referenzkurse vom 26.10.2026 (ersetzt die CHF-Annahme), CHF-Preise der Übernahme neu umgerechnet
--  2. Land „UK“ → ISO „GB“ (sonst kein USt-Satz bei neuen Preisen), firma_ermitteln übersetzt UK → GB
--  3. Shops aus der Recherche, die unter der Domain des Preisportals angelegt waren (selfio.de unter guenstiger.de …),
--     in den vorhandenen Firmeneintrag mit der richtigen Domain zusammengeführt – sonst landen neue Preise bei einer
--     anderen Firma als die alten und die Preisentwicklung reißt ab
--  4. marktbegleiter.einliefern(jsonb): ein Aufruf je Shop und Lauf, gleiche Verarbeitung wie Import 9
--     (Prüfung, USt/EUR, Dubletten, Historie, Zuordnung zum Grundfos-Stamm)
--  5. Rolle openclaw_import: darf NUR einliefern() aufrufen – keine Tabellen lesen/ändern, kein pim, keine öffentliche API.
--     Passwort setzt der Betreiber selbst: alter role openclaw_import with password '…';

-- ───────────── 1. Wechselkurse (EZB, 1 EUR = x Fremdwährung → eur_je_einheit = 1/x) ─────────────
delete from marktbegleiter.wechselkurse where waehrung = 'CHF' and quelle like 'Annahme%';
insert into marktbegleiter.wechselkurse (waehrung, datum, eur_je_einheit, quelle)
select w, date '2026-10-26', round(1 / k, 6), 'EZB-Referenzkurs 26.10.2026 (1 EUR = ' || k || ' ' || w || ')'
  from (values ('CHF', 0.9243), ('GBP', 0.83820), ('DKK', 7.4747), ('SEK', 11.1385), ('NOK', 10.4545), ('PLN', 4.4038),
               ('CZK', 24.369), ('HUF', 367.45), ('RON', 5.3473), ('ISK', 136.40), ('USD', 1.1188)) v(w, k)
on conflict (waehrung, datum) do update set eur_je_einheit = excluded.eur_je_einheit, quelle = excluded.quelle;
-- BGN: fester Umrechnungskurs zum Euro
insert into marktbegleiter.wechselkurse values ('BGN', date '2000-01-01', round(1 / 1.95583, 6), 'fester Kurs 1 EUR = 1,95583 BGN')
on conflict do nothing;

update marktbegleiter.preise p
   set wechselkurs = k.eur_je_einheit, wechselkurs_datum = k.datum, wechselkurs_quelle = k.quelle,
       preis_eur_netto = round(p.preis_netto * k.eur_je_einheit, 4), preis_eur_brutto = round(p.preis_brutto * k.eur_je_einheit, 4),
       versand_eur = round(p.versand * k.eur_je_einheit, 2)
  from marktbegleiter.wechselkurse k
 where k.waehrung = 'CHF' and k.datum = date '2026-10-26' and p.waehrung = 'CHF'
   and (p.wechselkurs_quelle is null or p.wechselkurs_quelle not like 'EZB%');

-- ───────────── 2. UK → GB ─────────────
update marktbegleiter.firmen set land = 'GB', geaendert_am = now() where land = 'UK';

create or replace function marktbegleiter.firma_ermitteln(p_name text, p_domain text, p_land text, p_website text default null)
returns bigint language plpgsql set search_path = marktbegleiter, public as $$
declare v_id bigint; v_dom text := marktbegleiter.domain_norm(coalesce(p_domain, p_website));
        v_land text := coalesce(nullif(upper(btrim(p_land)), ''), '?');
begin
  if v_land = 'UK' then v_land := 'GB'; end if;
  if v_dom is not null then
    select id into v_id from marktbegleiter.firmen where domain = v_dom order by (land = v_land) desc, id limit 1;
  end if;
  if v_id is null then
    select id into v_id from marktbegleiter.firmen where lower(name) = lower(btrim(p_name)) and land = v_land;
  end if;
  if v_id is null then
    insert into marktbegleiter.firmen (name, domain, website, land, gefunden_ueber)
    values (btrim(p_name), v_dom, coalesce(p_website, case when v_dom is not null then 'https://' || v_dom end), v_land, 'Import')
    returning id into v_id;
  end if;
  return v_id;
end $$;
revoke all on function marktbegleiter.firma_ermitteln(text, text, text, text) from public, anon, authenticated;

-- ───────────── 3. Shops unter Portal-Domain zusammenführen ─────────────
-- Preise bleiben unverändert; nur die Firma/das Produkt wird umgehängt (Änderungssperre dafür kurz aus)
alter table marktbegleiter.preise disable trigger preise_unveraenderlich;
do $$
declare r record;
begin
  for r in select * from (values (302, 229), (297, 115), (298, 142), (301, 210), (280, 15), (287, 93)) m(von, nach)
            where exists (select 1 from marktbegleiter.firmen where id = m.von)
              and exists (select 1 from marktbegleiter.firmen where id = m.nach) loop
    -- gleiches Produkt schon beim Ziel vorhanden → Preise dorthin, Doppel entfernen
    update marktbegleiter.preise x set produkt_id = q.id
      from marktbegleiter.produkte p join marktbegleiter.produkte q on q.firma_id = r.nach and q.schluessel = p.schluessel
     where p.firma_id = r.von and x.produkt_id = p.id;
    delete from marktbegleiter.produkte p
     where p.firma_id = r.von and exists (select 1 from marktbegleiter.produkte q where q.firma_id = r.nach and q.schluessel = p.schluessel);
    update marktbegleiter.produkte set firma_id = r.nach where firma_id = r.von;
    update marktbegleiter.preise set firma_id = r.nach where firma_id = r.von;
    update marktbegleiter.importe set firma_id = r.nach where firma_id = r.von;
    update marktbegleiter.firmen t
       set bemerkungen = concat_ws(' · ', t.bemerkungen, 'zusammengeführt mit „' || s.name || '“ (Recherche über ' || s.domain || ')'),
           letzte_preisliste = greatest(t.letzte_preisliste, s.letzte_preisliste), geaendert_am = now()
      from marktbegleiter.firmen s where s.id = r.von and t.id = r.nach;
    delete from marktbegleiter.firmen where id = r.von;
  end loop;
end $$;
alter table marktbegleiter.preise enable trigger preise_unveraenderlich;

-- ───────────── 4. Einlieferung (JSON) ─────────────
create or replace function marktbegleiter.zahl_norm(t text) returns numeric
language plpgsql immutable set search_path = pg_catalog as $$
declare s text := regexp_replace(coalesce(t, ''), '[^0-9,.\-]', '', 'g'); rk int; rp int;
begin
  if s = '' or s ~ '^[-.,]+$' then return null; end if;
  rk := strpos(reverse(s), ','); rp := strpos(reverse(s), '.');
  if rk > 0 and rp > 0 then
    s := case when rk < rp then replace(replace(s, '.', ''), ',', '.') else replace(s, ',', '') end;
  elsif rk > 0 then
    s := replace(s, ',', '.');
  end if;
  return s::numeric;
exception when others then return null;
end $$;

create or replace function marktbegleiter.datum_norm(t text) returns date
language plpgsql immutable set search_path = pg_catalog as $$
declare s text := btrim(coalesce(t, ''));
begin
  if s ~ '^\d{4}-\d{2}-\d{2}' then return left(s, 10)::date; end if;
  if s ~ '^\d{1,2}\.\d{1,2}\.\d{4}' then return to_date(substring(s from '^\d{1,2}\.\d{1,2}\.\d{4}'), 'DD.MM.YYYY'); end if;
  return null;
exception when others then return null;
end $$;

create or replace function marktbegleiter.einliefern(p jsonb)
returns jsonb
language plpgsql security definer set search_path = marktbegleiter, pg_catalog, pg_temp as $$
declare
  f jsonb := coalesce(p->'firma', '{}'::jsonb);
  v_pos jsonb := p->'positionen';
  v_land text := upper(btrim(coalesce(f->>'land', p->>'land', '')));
  v_name text := nullif(btrim(coalesce(f->>'name', '')), '');
  v_domain text := nullif(btrim(coalesce(f->>'domain', '')), '');
  v_stand date := coalesce(marktbegleiter.datum_norm(p->>'stand'), current_date);
  v_preisart text := coalesce(nullif(lower(btrim(p->>'preisart')), ''), 'oeffentlich');
  v_firma bigint; v_import bigint; v_sha text; v_erg jsonb; r record;
  leer constant text[] := array['', '-', '--', 'n/a', 'na', 'k.a.', 'k. a.', 'unbekannt', 'unknown', 'keine', 'none', 'null'];
begin
  if v_land = 'UK' then v_land := 'GB'; end if;
  if v_land !~ '^[A-Z]{2}$' then
    raise exception 'firma.land fehlt oder ist kein 2-stelliger Ländercode (z. B. DE, AT, CH) – erhalten: %', coalesce(f->>'land', 'nichts');
  end if;
  if v_name is null and v_domain is null then raise exception 'firma.name oder firma.domain fehlt'; end if;
  if jsonb_typeof(v_pos) is distinct from 'array' or jsonb_array_length(v_pos) = 0 then
    raise exception 'positionen fehlt oder ist leer (Liste von Produkten erwartet)';
  end if;
  if jsonb_array_length(v_pos) > 10000 then raise exception 'höchstens 10.000 Positionen je Aufruf – bitte aufteilen'; end if;
  if v_preisart not in ('oeffentlich', 'haendlerpreis', 'angebot') then
    raise exception 'preisart muss oeffentlich, haendlerpreis oder angebot sein – erhalten: %', v_preisart;
  end if;

  v_firma := marktbegleiter.firma_ermitteln(coalesce(v_name, v_domain), v_domain, v_land, nullif(f->>'website', ''));

  -- derselbe Lauf (gleicher Stand + gleiche Positionen) für dieselbe Firma nur einmal
  v_sha := encode(sha256(convert_to(v_stand::text || v_pos::text, 'UTF8')), 'hex');
  select id, status into r from marktbegleiter.importe where firma_id = v_firma and datei_sha256 = v_sha;
  if found then
    return jsonb_build_object('status', 'schon_eingeliefert', 'import_id', r.id, 'firma_id', v_firma,
                              'hinweis', 'Dieser Lauf wurde bereits gespeichert – nichts doppelt angelegt');
  end if;

  insert into marktbegleiter.importe (firma_id, dateiname, datei_sha256, format, quelle, preisart, stand, notiz)
  values (v_firma, coalesce(nullif(p->>'lauf', ''), 'OpenClaw') || ' ' || v_stand, v_sha, 'json',
          coalesce(nullif(p->>'quelle', ''), 'openclaw'), v_preisart, v_stand, nullif(p->>'notiz', ''))
  returning id into v_import;

  insert into marktbegleiter.import_zeilen (import_id, zeile, rohdaten, hersteller, mpn, ean, bezeichnung, baureihe, kategorie, url,
              preis, preis_typ, ust_satz, waehrung, preiseinheit, mengeneinheit, mindestmenge, staffel_ab, versand, lagerbestand,
              lieferzeit, gueltig_ab, gueltig_bis, erfasst_am, preisart, quelle_url, land)
  select v_import, o.n, o.e,
         nullif(btrim(o.e->>'hersteller'), ''),
         case when lower(btrim(coalesce(o.e->>'artikelnummer', o.e->>'mpn', ''))) = any (leer) then null
              else btrim(coalesce(o.e->>'artikelnummer', o.e->>'mpn')) end,
         case when lower(btrim(coalesce(o.e->>'ean', ''))) = any (leer) then null else btrim(o.e->>'ean') end,
         nullif(btrim(coalesce(o.e->>'bezeichnung', o.e->>'titel', '')), ''),
         nullif(btrim(o.e->>'baureihe'), ''), nullif(btrim(o.e->>'kategorie'), ''), nullif(btrim(o.e->>'url'), ''),
         case when x.preis > 0 and x.preis < 1e9 then x.preis end,
         lower(btrim(coalesce(o.e->>'preis_typ', p->>'preis_typ'))),
         case when x.ust between 0 and 30 then x.ust end,
         upper(left(btrim(coalesce(nullif(o.e->>'waehrung', ''), nullif(p->>'waehrung', ''), 'EUR')), 3)),
         case when x.pe > 0 and x.pe < 1e8 then x.pe end, nullif(btrim(o.e->>'mengeneinheit'), ''),
         case when x.mm > 0 and x.mm < 1e8 then x.mm end, case when x.st > 0 and x.st < 1e8 then x.st end,
         case when x.vs >= 0 and x.vs < 1e9 then x.vs end,
         coalesce(nullif(btrim(o.e->>'lagerbestand'), ''),
                  case lower(o.e->>'lieferbar') when 'true' then 'verfügbar' when 'false' then 'nicht lieferbar' end),
         nullif(btrim(o.e->>'lieferzeit'), ''),
         marktbegleiter.datum_norm(o.e->>'gueltig_ab'), marktbegleiter.datum_norm(o.e->>'gueltig_bis'),
         coalesce(marktbegleiter.datum_norm(o.e->>'erfasst_am'), v_stand),
         case when lower(o.e->>'preisart') in ('oeffentlich', 'haendlerpreis', 'angebot') then lower(o.e->>'preisart') end,
         nullif(btrim(o.e->>'url'), ''), v_land
    from jsonb_array_elements(v_pos) with ordinality o(e, n)
    cross join lateral (select marktbegleiter.zahl_norm(o.e->>'preis') preis, marktbegleiter.zahl_norm(o.e->>'ust_satz') ust,
                               marktbegleiter.zahl_norm(o.e->>'preiseinheit') pe, marktbegleiter.zahl_norm(o.e->>'mindestmenge') mm,
                               marktbegleiter.zahl_norm(o.e->>'staffel_ab') st, marktbegleiter.zahl_norm(o.e->>'versand') vs) x
   where jsonb_typeof(o.e) = 'object';

  select jsonb_object_agg(schritt, anzahl) into v_erg from marktbegleiter.import_verarbeiten(v_import);

  select jsonb_build_object('status', i.status, 'import_id', i.id, 'firma_id', f2.id, 'firma', f2.name, 'land', f2.land,
                            'ergebnis', v_erg, 'fehler', (select coalesce(jsonb_agg(e), '[]') from
                              (select e from jsonb_array_elements(i.fehlerprotokoll) e limit 50) s))
    into v_erg
    from marktbegleiter.importe i join marktbegleiter.firmen f2 on f2.id = i.firma_id where i.id = v_import;
  return v_erg;
end $$;

revoke all on function marktbegleiter.zahl_norm(text) from public, anon, authenticated;
revoke all on function marktbegleiter.datum_norm(text) from public, anon, authenticated;
revoke all on function marktbegleiter.einliefern(jsonb) from public, anon, authenticated;

-- ───────────── 5. Rolle für OpenClaw (nur einliefern) ─────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'openclaw_import') then
    create role openclaw_import login noinherit nosuperuser nocreatedb nocreaterole noreplication connection limit 3;
  end if;
end $$;
comment on role openclaw_import is 'OpenClaw-Scraper: darf nur marktbegleiter.einliefern(jsonb) aufrufen';
grant usage on schema marktbegleiter to openclaw_import;
grant execute on function marktbegleiter.einliefern(jsonb) to openclaw_import;
alter role openclaw_import set statement_timeout = '5min';
