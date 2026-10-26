-- Großhändler-Datei 09/2025 („Datanorm Neuanlage“ + „Änderung“): NUR Kurztexte übernehmen, keine Preise
-- (Entscheidung 26.10.2026). Zuordnung über die Grundfos-Nummer im B-Satz (Feld 5), z. B.
--   A: 30000566 · „GRUNDFOS Elektr. geregelte Umwälzpumpe“ / „MAGNA3 25-60 PN6/10 180mm 1x230V DE“
--   B: 30000566 · Grundfos-Nr. 97924624
-- Kopfsatz der Datei: „Weitergabe der Daten nur mit schriftl. Genehmigung“ → Quelle mit export_freigabe = false;
-- der Shop-Export nutzt diese Texte erst nach Freigabe. Priorität 55: unter allen Grundfos-Quellen,
-- über der Text-Engine (50) – gilt also nur, wo Grundfos selbst keinen Kurztext liefert.
-- Datei „Änderung“ (gleicher Stand) geht vor „Neuanlage“.

alter table pim.quelle add column if not exists export_freigabe boolean not null default true;
alter table pim.quelle add column if not exists hinweis text;

create or replace function pim.grosshandel_2025_texte()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, raw, public
as $body$
declare
  v_quelle bigint;
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);
  select id into v_quelle from pim.quelle where typ = 'grosshandel_texte' and datei_id = 41;
  if v_quelle is null then
    insert into pim.quelle (datei_id, typ, bezeichnung, datenstand, prioritaet, export_freigabe, hinweis)
    values (41, 'grosshandel_texte', 'Großhändler-Datei 09/2025 – nur Kurztexte', date '2025-09-05', 55, false,
            'Kopfsatz: „Weitergabe der Daten nur mit schriftl. Genehmigung“ – vor Shop-Export Freigabe einholen')
    returning id into v_quelle;
  end if;

  create temp table _gh on commit drop as
  select distinct on (ar.id) ar.id as artikel_id,
         nullif(trim(a.felder[5]), '') as kurz1, nullif(trim(a.felder[6]), '') as kurz2
    from raw.datanorm_satz b
    join raw.datanorm_satz a on a.datei_id = b.datei_id and a.satzart = 'A' and a.felder[3] = b.felder[3]
    join pim.artikel ar on ar.hersteller_id = 1 and ar.artikelnummer_norm = pim.gpc_nummer(b.felder[5])
   where b.datei_id in (41, 44) and b.satzart = 'B'
   order by ar.id, (b.datei_id = 44) desc, a.zeile desc;

  insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
  select artikel_id, 'de', x.art, x.text, v_quelle
    from _gh cross join lateral (values ('kurz1', kurz1), ('kurz2', kurz2)) x(art, text)
   where x.text is not null
  on conflict (artikel_id, sprache, art, quelle_id) do update set text = excluded.text;
  get diagnostics n = row_count;
  schritt := 'Kurztexte (kurz1 + kurz2)'; anzahl := n; return next;

  select count(*) into n from _gh g
   where not exists (select 1 from pim.artikel_text t join pim.quelle q on q.id = t.quelle_id
                      where t.artikel_id = g.artikel_id and t.sprache = 'de' and t.art in ('kurz1', 'kurz2', 'titel')
                        and q.id <> v_quelle);
  schritt := 'davon Artikel ohne anderen deutschen Text'; anzahl := n; return next;
  select count(*) into n from _gh;
  schritt := 'Artikel zugeordnet'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.grosshandel_2025_texte() from public, anon, authenticated;

-- Golden Record: beste Quelle JE TEXTART (vorher: alle Texte aus der einen besten Quelle – dadurch fiel z. B. der
-- Langtext der Text-Engine weg, sobald eine höher priorisierte Quelle nur Kurztexte hatte).
-- Quellen ohne Export-Freigabe (quelle.export_freigabe = false) bleiben draußen.
create or replace view pim.v_artikel_de with (security_invoker = true) as
select a.id, a.artikelnummer, a.ean, a.status, a.hersteller_url,
       (select al.wert from pim.artikel_alias al
         where al.artikel_id = a.id and al.typ = 'typbezeichnung' limit 1) as typbezeichnung,
       tx.kurz1, tx.kurz2, tx.lang, tx.technik,
       (select t.text from pim.artikel_text t
         where t.artikel_id = a.id and t.art = 'titel' and t.sprache = 'en' limit 1) as titel_en,
       pr.betrag as listenpreis, pr.waehrung, pr.preiseinheit, pr.datenstand as preis_stand,
       (select g.name from pim.artikel_gruppe ag join pim.produktgruppe g on g.id = ag.gruppe_id
         where ag.artikel_id = a.id limit 1) as produktgruppe,
       tx.beschreibung,
       tx.titel
  from pim.artikel a
  left join lateral (
    select max(b.text) filter (where b.art = 'kurz1') as kurz1,
           max(b.text) filter (where b.art = 'kurz2') as kurz2,
           max(b.text) filter (where b.art = 'lang') as lang,
           max(b.text) filter (where b.art = 'technik') as technik,
           max(b.text) filter (where b.art = 'beschreibung') as beschreibung,
           max(b.text) filter (where b.art = 'titel') as titel
      from (select distinct on (t.art) t.art, t.text
              from pim.artikel_text t join pim.quelle q on q.id = t.quelle_id
             where t.artikel_id = a.id and t.sprache = 'de' and q.export_freigabe
             order by t.art, q.prioritaet desc, q.datenstand desc nulls last) b
  ) tx on true
  left join lateral (
    select p.betrag, p.waehrung, p.preiseinheit, q.datenstand
      from pim.artikel_preis p join pim.quelle q on q.id = p.quelle_id
     where p.artikel_id = a.id and p.preisart = 'listenpreis' and p.markt = 'DE' and q.export_freigabe
     order by q.datenstand desc nulls last, q.prioritaet desc
     limit 1
  ) pr on true;

-- 26.10.2026: schriftliche Genehmigung liegt laut Inhaberin vor → Texte für den Export freigegeben
update pim.quelle
   set export_freigabe = true,
       hinweis = 'Kopfsatz: „Weitergabe der Daten nur mit schriftl. Genehmigung“ – Genehmigung liegt vor (Bestätigung 26.10.2026)'
 where typ = 'grosshandel_texte' and datei_id = 41;
