-- Großhändler- und Fremdhersteller-Daten richtig zuordnen
--
-- Großhändler-DATANORM verwenden eigene Artikelnummern. Die Grundfos-Nummer steht je nach Lieferant
-- in der Alternativ-Artikelnummer (B-Satz Feld 5) oder lässt sich über die EAN (B-Satz Feld 10) finden.
-- Fremdhersteller (z. B. Pumpengruppen „mit Grundfos Alpha2“) gehören nicht in den Grundfos-Stamm.
-- Die Rohdaten (raw.*) bleiben unverändert; bereinigt werden nur die pim-Tabellen.

alter table pim.quelle add column if not exists zuordnung text
  check (zuordnung in ('direkt','alternativnummer','ean','keine','fremd'));
comment on column pim.quelle.zuordnung is
  'Wie Artikel dieser Quelle auf Grundfos-Nummern abgebildet werden: direkt = Grundfos-Nummer, alternativnummer = B-Satz Feld 5, ean = über EAN, keine = nicht zuordenbar, fremd = anderer Hersteller';

create or replace function pim.grosshandel_zuordnen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $$
declare
  n bigint;
begin
  ------------------------------------------------------------------ 1. Quellen einstufen
  update pim.quelle set zuordnung = 'direkt'
   where typ in ('hersteller_datanorm', 'artikelliste') and zuordnung is distinct from 'direkt';

  with st as (
    select q.id,
           avg((upper(t.text) like 'GRUNDFOS%' or upper(t.text) like 'GF %')::int) as anteil_gf_text,
           avg((a.hersteller_url is not null)::int)                                as anteil_in_liste,
           avg((a.artikelnummer_norm ~ '^[0-9]{2}[0-9A-Z]{6}$')::int)               as anteil_gf_format
      from pim.quelle q
      join pim.artikel_text t on t.quelle_id = q.id and t.art = 'kurz1'
      join pim.artikel a on a.id = t.artikel_id
     where q.typ = 'grosshandel_datanorm' and q.zuordnung is null
     group by q.id
  ), b as (
    select q.id,
           avg((trim(s.felder[5]) ~ '^[0-9]{2}[0-9A-Z]{6}$')::int) as anteil_altnr,
           avg((trim(s.felder[10]) ~ '^57(00|08|10)[0-9]{9}$')::int) as anteil_gf_ean
      from pim.quelle q
      join raw.datanorm_satz s on s.datei_id = q.datei_id and s.satzart = 'B'
     where q.typ = 'grosshandel_datanorm' and q.zuordnung is null
     group by q.id
  )
  update pim.quelle q set zuordnung =
         case when st.anteil_gf_text < 0.5             then 'fremd'
              when st.anteil_in_liste >= 0.5           then 'direkt'
              when coalesce(b.anteil_altnr, 0) >= 0.5  then 'alternativnummer'
              when st.anteil_gf_format >= 0.8 and coalesce(b.anteil_gf_ean, 0) >= 0.5 then 'direkt'
              when coalesce(b.anteil_gf_ean, 0) >= 0.5 then 'ean'
              else 'keine' end
    from st left join b using (id)
   where q.id = st.id;
  -- Quellen ohne Artikeltexte (nur Waren-/Rabattgruppen o. Ä.)
  update pim.quelle set zuordnung = 'keine' where zuordnung is null;

  ------------------------------------------------------------------ 2. Zuordnung Großhändler-Nr. → Grundfos-Nr.
  create temp table _map (quelle_id bigint, wh_id bigint, wh_nr text, gf_nr text, gf_norm text, gf_id bigint)
    on commit drop;

  insert into _map (quelle_id, wh_id, wh_nr, gf_nr, gf_norm)
  select distinct on (a.id) q.id, a.id, a.artikelnummer, trim(s.felder[5]), upper(trim(s.felder[5]))
    from pim.quelle q
    join raw.datanorm_satz s on s.datei_id = q.datei_id and s.satzart = 'B'
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(replace(trim(s.felder[3]), ' ', ''))
   where q.zuordnung = 'alternativnummer'
     and trim(s.felder[5]) ~ '^[0-9]{2}[0-9A-Z]{6}$';

  insert into _map (quelle_id, wh_id, wh_nr, gf_nr, gf_norm)
  select distinct on (a.id) q.id, a.id, a.artikelnummer, g.artikelnummer, g.artikelnummer_norm
    from pim.quelle q
    join raw.datanorm_satz s on s.datei_id = q.datei_id and s.satzart = 'B'
    join pim.artikel a on a.hersteller_id = 1
                      and a.artikelnummer_norm = upper(replace(trim(s.felder[3]), ' ', ''))
    join pim.artikel g on g.hersteller_id = 1 and g.ean = trim(s.felder[10]) and g.id <> a.id
                      and g.artikelnummer_norm ~ '^[0-9]{2}[0-9A-Z]{6}$'
   where q.zuordnung = 'ean'
   order by a.id, g.hersteller_url is null, g.id;

  delete from _map where wh_nr = gf_nr;   -- Großhändler nutzt bereits die Grundfos-Nummer
  get diagnostics n = row_count;

  -- Grundfos-Artikel, die bisher nur beim Großhändler vorkommen (z. B. neue Modelle), anlegen
  insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm)
  select distinct on (gf_norm) 1, gf_nr, gf_norm from _map
  on conflict (hersteller_id, artikelnummer_norm) do nothing;
  get diagnostics n = row_count;
  schritt := 'neue Grundfos-Artikel aus Großhandel'; anzahl := n; return next;

  update _map m set gf_id = a.id
    from pim.artikel a where a.hersteller_id = 1 and a.artikelnummer_norm = m.gf_norm;

  ------------------------------------------------------------------ 3. Daten umhängen
  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select m.gf_id, t.sprache, t.art, t.text, t.quelle_id
    from pim.artikel_text t join _map m on m.wh_id = t.artikel_id and m.quelle_id = t.quelle_id
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Texte umgehängt'; anzahl := n; return next;

  insert into pim.artikel_preis (artikel_id, markt, preisart, betrag, waehrung, preiseinheit,
                                 mengeneinheit, rabattgruppe, gueltig_ab, gueltig_bis, quelle_id)
  select distinct on (m.gf_id, p.quelle_id, p.preisart)
         m.gf_id, p.markt, p.preisart, p.betrag, p.waehrung, p.preiseinheit,
         p.mengeneinheit, p.rabattgruppe, p.gueltig_ab, p.gueltig_bis, p.quelle_id
    from pim.artikel_preis p join _map m on m.wh_id = p.artikel_id and m.quelle_id = p.quelle_id
   where not exists (select 1 from pim.artikel_preis x
                      where x.artikel_id = m.gf_id and x.quelle_id = p.quelle_id and x.preisart = p.preisart);
  get diagnostics n = row_count;
  schritt := 'Preise umgehängt'; anzahl := n; return next;

  update pim.artikel g set ean = w.ean, aktualisiert_am = now()
    from _map m join pim.artikel w on w.id = m.wh_id
   where g.id = m.gf_id and g.ean is null and w.ean ~ '^57(00|08|10)';

  insert into pim.artikel_alias (artikel_id, typ, wert, quelle_id)
  select distinct m.gf_id, 'grosshandel', m.wh_nr, m.quelle_id from _map m
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := 'Großhändler-Nummern als Alias'; anzahl := n; return next;

  -- Daten der Großhändler-Nummer selbst entfernen (sie stecken jetzt beim Grundfos-Artikel)
  delete from pim.artikel_text t using _map m where t.artikel_id = m.wh_id and t.quelle_id = m.quelle_id;
  delete from pim.artikel_preis p using _map m where p.artikel_id = m.wh_id and p.quelle_id = m.quelle_id;

  ------------------------------------------------------------------ 4. Fremd / nicht zuordenbar entfernen
  delete from pim.artikel_text t using pim.quelle q
   where t.quelle_id = q.id and q.zuordnung in ('fremd', 'keine');
  get diagnostics n = row_count;
  schritt := 'Texte aus fremden/nicht zuordenbaren Quellen entfernt'; anzahl := n; return next;
  delete from pim.artikel_preis p using pim.quelle q
   where p.quelle_id = q.id and q.zuordnung in ('fremd', 'keine');

  -- Artikel ohne jeden Beleg mehr (keine Liste, kein Text, kein Preis, kein Alias) löschen
  delete from pim.artikel a
   where a.hersteller_url is null
     and not exists (select 1 from pim.artikel_text t where t.artikel_id = a.id)
     and not exists (select 1 from pim.artikel_preis p where p.artikel_id = a.id)
     and not exists (select 1 from pim.artikel_alias l where l.artikel_id = a.id)
     and not exists (select 1 from pim.artikel_beziehung b where a.id in (b.von_artikel_id, b.zu_artikel_id));
  get diagnostics n = row_count;
  schritt := 'Artikel ohne Beleg gelöscht'; anzahl := n; return next;
end;
$$;

revoke execute on function pim.grosshandel_zuordnen() from public, anon, authenticated;
