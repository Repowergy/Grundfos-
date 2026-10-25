-- Technischer Austauschfinder: Grundfos-Pumpen mit passenden Eckdaten zu einer Fremdpumpe
-- (ergänzt die von Grundfos hinterlegten Austauschlisten um eigene Vorschläge).
--
-- Gleiche Codes auf beiden Seiten (gemeinsamer Merkmalskatalog): Pflicht = gleiche Baulänge (PORTPORT),
-- gleicher Anschluss (PIPECON) und gleiche Phasenzahl (PHASE), soweit bei der Fremdpumpe vorhanden.
-- Bewertung: Abweichung von Förderhöhe (HEADMAXM), Förderstrom (FLOWMAX) und Leistung (P2KW56/P1) – je kleiner,
-- desto besser (fehlende Werte zählen als halbe Abweichung); aktuelle Artikel der Grundfos-Website werden
-- bevorzugt, historische abgewertet.

create or replace function pim.technischer_austausch(p_fremdprodukt_id bigint, anzahl integer default 10)
returns table (artikel_id bigint, artikelnummer text, typbezeichnung text, punkte numeric, begruendung text)
language sql stable
set search_path = pim, public
as $$
  with f as (
    select max(wert) filter (where merkmal_code = 'PORTPORT') as baulaenge,
           max(wert) filter (where merkmal_code = 'PIPECON') as anschluss,
           max(wert) filter (where merkmal_code = 'PHASE') as phase,
           max(wert_num) filter (where merkmal_code = 'HEADMAXM') as hoehe,
           max(wert_num) filter (where merkmal_code = 'FLOWMAX') as strom,
           max(wert_num) filter (where merkmal_code = 'P2KW56') as p2
      from pim.v_fremdprodukt_merkmal where fremdprodukt_id = p_fremdprodukt_id
  ), kand as (
    select am.artikel_id
      from pim.artikel_merkmal am, f
     where f.baulaenge is not null and am.merkmal_code = 'PORTPORT' and am.wert_num = pim.zahl(f.baulaenge)
  ), daten as (
    select k.artikel_id,
           max(am.wert) filter (where am.merkmal_code = 'PIPECON') as anschluss,
           max(am.wert) filter (where am.merkmal_code = 'PHASE') as phase,
           max(am.wert_num) filter (where am.merkmal_code in ('HEADMAXM', 'HEADMAXDM')) as hoehe,
           max(am.wert_num) filter (where am.merkmal_code = 'FLOWMAX') as strom,
           max(am.wert_num) filter (where am.merkmal_code = 'ENERGYEEI') as eei
      from kand k join pim.artikel_merkmal am on am.artikel_id = k.artikel_id
     where am.merkmal_code in ('PIPECON', 'PHASE', 'HEADMAXM', 'HEADMAXDM', 'FLOWMAX', 'ENERGYEEI')
     group by k.artikel_id
  )
  select d.artikel_id, a.artikelnummer,
         (select al.wert from pim.artikel_alias al where al.artikel_id = a.id and al.typ = 'typbezeichnung' limit 1),
         round(85
               - 40 * case when d.hoehe is null or f.hoehe is null or f.hoehe = 0 then 0.5   -- unbekannt = halbe Abweichung
                           else least(1, abs(d.hoehe - f.hoehe) / f.hoehe) end
               - 30 * case when d.strom is null or f.strom is null or f.strom = 0 then 0.5
                           else least(1, abs(d.strom - f.strom) / f.strom) end
               + 10 * (d.eei is not null)::int                -- Energieeffizienz-Index vorhanden = ErP-konform
               +  5 * (a.hersteller_url is not null)::int     -- auf der Grundfos-Website gelistet
               - 10 * (a.status = 'historisch')::int, 1),
         concat_ws(' · ', 'Baulänge ' || f.baulaenge || ' mm',
                   'Anschluss ' || d.anschluss, 'Phase ' || d.phase,
                   'H max ' || d.hoehe || ' m (Fremd: ' || f.hoehe || ')',
                   'Q max ' || d.strom || ' m³/h (Fremd: ' || f.strom || ')', 'EEI ' || d.eei)
    from daten d cross join f
    join pim.artikel a on a.id = d.artikel_id
   where (f.anschluss is null   -- 'G 1 1/2' (Grundfos) = '1 1/2"' (Wilo): nur Ziffern und Bruchstrich vergleichen
          or regexp_replace(d.anschluss, '[^0-9/]', '', 'g') = regexp_replace(f.anschluss, '[^0-9/]', '', 'g'))
     and (f.phase is null or d.phase = f.phase)
   order by 4 desc nulls last, a.artikelnummer
   limit anzahl
$$;
revoke execute on function pim.technischer_austausch(bigint, integer) from public, anon, authenticated;
