-- Lang- und Techniktexte aus den DATANORM-Rohdaten (neu) aufbauen.
--
-- Techniktext: E-Sätze sind Vorlagen je Baureihe. Jede Folge von '$' ist EIN Platzhalter (Länge = Feldbreite).
-- D-Sätze liefern je Artikel die Werte als fortlaufende '$'-getrennte Liste (verteilt auf mehrere Abschnitte).
-- Beispiel 011H1300: Vorlage „Leistungsaufnahme P1: $$$ W“ + Werte [Unilift KP 150 M 1, 300, …] → „… P1: 300 W“.
-- Langtext: T-Zeilen zusammenfügen; Silbentrennung („verti- kale“) auflösen, Ergänzungsstriche („Saug- und“) behalten.

create or replace function pim.fuelle_vorlage(zeilen text[], werte text[])
returns text
language plpgsql immutable
as $$
declare
  i int := 1;
  l text;
  res text[] := '{}';
  ist_fortsetzung boolean;
begin
  foreach l in array coalesce(zeilen, '{}') loop
    ist_fortsetzung := btrim(l) ~ '^\$';           -- Zeile beginnt mit Platzhalter → gehört zur Vorzeile
    while l ~ '\$' loop
      l := regexp_replace(l, '\$+', replace(replace(btrim(coalesce(werte[i], '')), '\', '\\'), '&', '\&'));
      i := i + 1;
    end loop;
    l := btrim(regexp_replace(l, '\s+', ' ', 'g'));
    continue when l = '';
    if ist_fortsetzung and cardinality(res) > 0 then
      res[cardinality(res)] := res[cardinality(res)] || ' ' || l;
    else
      res := res || l;
    end if;
  end loop;
  return array_to_string(res, E'\n');
end;
$$;

create or replace function pim.silben_zusammenfuegen(t text)
returns text
language sql immutable
as $$
  select regexp_replace(t, '(\w)- (?!(?:und|oder|bzw|sowie|u\.)\M)([a-zäöüß])', '\1\2', 'g')
$$;

create or replace function pim.texte_neu_aufbauen()
returns table (art text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $body$
declare
  n bigint;
begin
  -- Techniktexte -------------------------------------------------------------
  create temp table _technik on commit drop as
  with d as (
    select q.id as quelle_id,
           upper(replace(trim(s.felder[3]), ' ', '')) as nr,
           s.zeile,
           k,
           trim(s.felder[6 + 4 * k]) as ekey,
           s.felder[7 + 4 * k] as werte
      from raw.datanorm_satz s
      join pim.quelle q on q.datei_id = s.datei_id
      cross join lateral generate_series(0, (cardinality(s.felder) - 4) / 4) k
     where s.satzart = 'D'
       and s.felder[4 + 4 * k] ~ '^\d+$'
  ), dv as (
    select quelle_id, nr, ekey,
           string_to_array(regexp_replace(string_agg(werte, '' order by zeile, k), '\$$', ''), '$') as werte
      from d group by quelle_id, nr, ekey
  ), tpl as (
    select quelle_id, schluessel, array_agg(text order by zeile) as zeilen
      from pim.textbaustein where zeile >= 100000
     group by quelle_id, schluessel
  )
  select a.id as artikel_id, dv.quelle_id,
         string_agg(pim.fuelle_vorlage(tpl.zeilen, dv.werte), E'\n' order by dv.ekey) as text
    from dv
    join tpl on tpl.quelle_id = dv.quelle_id and tpl.schluessel = dv.ekey
    join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = dv.nr
   group by a.id, dv.quelle_id;

  delete from pim.artikel_text t using _technik x
   where t.artikel_id = x.artikel_id and t.quelle_id = x.quelle_id and t.art = 'technik';
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select artikel_id, 'de', 'technik', text, quelle_id from _technik where coalesce(text, '') <> '';
  get diagnostics n = row_count;
  art := 'technik'; anzahl := n; return next;

  -- Langtexte (T-Bausteine, auch aus Nachbardatei gleichen Datenstands) -------
  create temp table _lang on commit drop as
  with a_satz as (
    select q.id as quelle_id, q.datenstand,
           upper(replace(trim(s.felder[3]), ' ', '')) as nr,
           trim(s.felder[13]) as lkey
      from raw.datanorm_satz s
      join pim.quelle q on q.datei_id = s.datei_id
     where s.satzart = 'A' and coalesce(trim(s.felder[13]), '') <> ''
  ), tpl as (
    select tb.quelle_id, q.datenstand, tb.schluessel,
           pim.silben_zusammenfuegen(string_agg(tb.text, ' ' order by tb.zeile)) as text
      from pim.textbaustein tb join pim.quelle q on q.id = tb.quelle_id
     where tb.zeile < 100000
     group by tb.quelle_id, q.datenstand, tb.schluessel
  )
  select distinct on (ar.id, a_satz.quelle_id) ar.id as artikel_id, a_satz.quelle_id, tpl.text
    from a_satz
    join tpl on tpl.schluessel = a_satz.lkey and tpl.datenstand is not distinct from a_satz.datenstand
    join pim.artikel ar on ar.hersteller_id = 1 and ar.artikelnummer_norm = a_satz.nr
   order by ar.id, a_satz.quelle_id, (tpl.quelle_id = a_satz.quelle_id) desc;

  delete from pim.artikel_text t using _lang x
   where t.artikel_id = x.artikel_id and t.quelle_id = x.quelle_id and t.art = 'lang';
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select artikel_id, 'de', 'lang', text, quelle_id from _lang where coalesce(text, '') <> '';
  get diagnostics n = row_count;
  art := 'lang'; anzahl := n; return next;
end;
$body$;

revoke execute on function pim.texte_neu_aufbauen() from public, anon, authenticated;
