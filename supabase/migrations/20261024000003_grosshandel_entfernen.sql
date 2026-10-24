-- Großhändler- und Fremdhersteller-Daten aus dem Grundfos-Stamm entfernen (Entscheidung 24.10.2026).
-- Behalten werden nur Grundfos-Quellen: Herstellerdateien der Grundfos GmbH und die „GF“-Datei
-- (Grundfos-Daten mit Grundfos-Nummern und -EAN). Die Rohdaten (raw.*) bleiben unverändert erhalten.

create temp table _weg on commit drop as
  select id from pim.quelle
   where typ = 'grosshandel_datanorm' and bezeichnung not like 'GF alle Preisangaben%';

delete from pim.artikel_text   where quelle_id in (select id from _weg);
delete from pim.artikel_preis  where quelle_id in (select id from _weg);
delete from pim.textbaustein   where quelle_id in (select id from _weg);
delete from pim.artikel_alias  where quelle_id in (select id from _weg);
delete from pim.artikel_markt  where quelle_id in (select id from _weg);
delete from pim.artikel_merkmal where quelle_id in (select id from _weg);

-- Artikel, die nur durch diese Quellen entstanden sind (keine Artikelliste, kein Text, kein Preis)
delete from pim.artikel a
 where a.hersteller_url is null
   and not exists (select 1 from pim.artikel_text t  where t.artikel_id = a.id)
   and not exists (select 1 from pim.artikel_preis p where p.artikel_id = a.id);

-- EAN, die nur aus Großhandelsdateien stammen und keine Grundfos-EAN sind, entfernen
update pim.artikel set ean = null where ean is not null and ean !~ '^57(00|08|10)';

delete from pim.quelle where id in (select id from _weg);
