-- Produkte ohne Herstellerangabe werden nur noch als Grundfos behandelt, wenn die Bezeichnung „Grundfos“ oder eine
-- Grundfos-Baureihe nennt. Anlass: pumpen-heizung.de führt Ersatzteile im Format „Remeha - 97569102 - Flansch“ ohne
-- Herstellerspalte; 251 Teile (Remeha, Vaillant, Esbe, Stiebel Eltron …) waren über zufällig gleiche Nummern
-- Grundfos-Artikeln zugeordnet. Die 61 MAGNA3 ohne Herstellerangabe (1A-Pumpen) bleiben zugeordnet.
create or replace function marktbegleiter.grundfos_muster() returns text
language sql immutable set search_path = pg_catalog as $$
  select '(grundfos|\m(alpha ?[123]?|magna ?[123]?|ups|upm|upml|scala ?[12]?|sololift2?|conlift2?|multilift|unilift|uplift|comfort|sqe?|crn?|cri|cme?|cmbe|mq|tpe|nbg?e?|nkg?e?|seg|dda|ddc|dme|hydro ?(multi|solo|mpc)|easybox)\M)'::text
$$;
revoke all on function marktbegleiter.grundfos_muster() from public, anon, authenticated;

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
              where p.mpn_norm is not null
                and (p.hersteller_norm is not null or coalesce(p.bezeichnung, '') ~* marktbegleiter.grundfos_muster()))
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
              where al.typ = 'vvs' and al.wert in (select btrim(mpn) from _p where mpn is not null
                                                     and (hersteller_norm = 'GRUNDFOS' or (hersteller_norm is null
                                                          and coalesce(bezeichnung, '') ~* marktbegleiter.grundfos_muster())))
              group by al.wert having count(distinct al.artikel_id) = 1)
  update marktbegleiter.produkte p set artikel_id = k.artikel_id, matching_status = 'eindeutig_alternativ', gematcht_am = now(),
         matching_hinweis = 'über Großhandelsnummer (VVS)'
    from k where p.id in (select id from _p) and p.matching_status in ('offen', 'kein_treffer', 'vorschlag')
     and (p.hersteller_norm = 'GRUNDFOS' or (p.hersteller_norm is null and coalesce(p.bezeichnung, '') ~* marktbegleiter.grundfos_muster()))
     and btrim(p.mpn) = k.wert;
  get diagnostics n = row_count; schritt := '3 Großhandelsnummer'; anzahl := n; return next;

  with b as (select p.id, btrim(regexp_replace(upper(p.bezeichnung),
                    'GRUNDFOS|UMWÄLZPUMPE|HOCHEFFIZIENZ[A-ZÄÖÜ-]*|DRUCKERHÖHUNG[A-ZÄÖÜ-]*|PUMPE|HEBEANLAGE', ' ', 'g')) as txt
               from marktbegleiter.produkte p
              where p.id in (select id from _p) and p.matching_status in ('offen', 'kein_treffer') and p.bezeichnung is not null
                and p.vorschlag_artikel_id is null
                and (p.hersteller_norm = 'GRUNDFOS' or (p.hersteller_norm is null and p.bezeichnung ilike '%grundfos%'))),
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
revoke all on function marktbegleiter.produkte_zuordnen(bigint, boolean) from public, anon, authenticated;

-- bestehende Fehlzuordnungen aus den Shop-Exporten zurücknehmen
update marktbegleiter.produkte p
   set artikel_id = null, matching_status = 'kein_treffer', gematcht_am = now(),
       matching_hinweis = 'Zuordnung zurückgenommen: Hersteller nicht angegeben und keine Grundfos-Angabe in der Bezeichnung'
 where p.hersteller_norm is null and p.matching_status in ('eindeutig_mpn', 'eindeutig_alternativ')
   and not (coalesce(p.bezeichnung, '') ~* marktbegleiter.grundfos_muster())
   and exists (select 1 from marktbegleiter.preise x join marktbegleiter.importe i on i.id = x.import_id
                where x.produkt_id = p.id and i.quelle = 'scraping');
