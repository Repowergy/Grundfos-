-- Intelligente Suche und „Golden Record“.
--
--  pim.suche(eingabe, anzahl)  ein Suchfeld für alles:
--     • Artikelnummer (auch mit Leerzeichen/Kleinbuchstaben) und EAN → exakter Treffer
--     • Typbezeichnung („alpha2 25-60“, Tippfehler erlaubt) → Trigramm-Ähnlichkeit
--     • deutscher Text (Kurz-/Langtext) → Volltextsuche
--     • Typ einer Fremdpumpe („Wilo Stratos Pico 25/1-6“, „Star E 25/1-3“) → Grundfos-Ersatz
--  pim.v_artikel_de            je Artikel der beste Wert je Feld (Priorität der Quelle, dann neuester Stand)

create index if not exists artikel_alias_wert_trgm_idx
  on pim.artikel_alias using gin (wert extensions.gin_trgm_ops);

create or replace function pim.suche(eingabe text, anzahl integer default 20)
returns table (artikel_id bigint, artikelnummer text, typbezeichnung text, kurztext text,
               treffer_art text, grund text, punkte numeric)
language sql stable
set search_path = pim, extensions, public
as $$
  with q as (
    select trim(eingabe) as roh,
           upper(regexp_replace(trim(eingabe), '\s+', '', 'g')) as norm,
           lower(trim(eingabe)) as klein
  ), kandidaten as (
    -- 1. Artikelnummer exakt
    select a.id, 'nummer'::text as art, 'Artikelnummer'::text as grund, 100::numeric as punkte
      from pim.artikel a, q where a.artikelnummer_norm = q.norm
    union all
    -- 2. EAN exakt
    select a.id, 'ean', 'EAN', 100 from pim.artikel a, q where q.norm ~ '^\d{8,14}$' and a.ean = q.norm
    union all
    -- 3. Artikelnummer-Präfix (z. B. „9628“)
    select a.id, 'nummer_teil', 'Artikelnummer beginnt mit Eingabe', 40
      from pim.artikel a, q where length(q.norm) >= 5 and a.artikelnummer_norm like q.norm || '%'
    union all
    -- 4. Typbezeichnung / Aliasse (fehlertolerant)
    select al.artikel_id, 'typ', 'Typbezeichnung: ' || al.wert, round((60 + 40 * similarity(lower(al.wert), q.klein))::numeric, 1)
      from pim.artikel_alias al, q
     where al.wert % q.roh or al.wert ilike q.roh || '%'
    union all
    -- 5. Volltext deutsch (Kurz-/Lang-/Techniktext)
    select t.artikel_id, 'text', 'Text: ' || left(t.text, 60),
           round((20 + 30 * ts_rank(to_tsvector('german', t.text), plainto_tsquery('german', q.roh)))::numeric, 1)
      from pim.artikel_text t, q
     where t.sprache = 'de' and to_tsvector('german', t.text) @@ plainto_tsquery('german', q.roh)
    union all
    -- 6. Fremdpumpe → Grundfos-Ersatz
    select w.artikel_id, 'ersatz',
           'Ersatz für ' || coalesce(w.hersteller_name, w.fremdhersteller) || ' ' || w.fremdtyp,
           round((50 + 40 * similarity(lower(w.fremdtyp), q.klein) - coalesce(w.variante, 1))::numeric, 1)
      from pim.querverweis_wettbewerb w, q
     where w.fremdtyp % q.roh or w.fremdtyp ilike '%' || q.roh || '%'
        or (strpos(q.roh, ' ') > 0
            and w.fremdtyp % substr(q.roh, strpos(q.roh, ' ') + 1)
            and lower(coalesce(w.hersteller_name, w.fremdhersteller)) = lower(split_part(q.roh, ' ', 1)))
  ), best as (
    select distinct on (id) id, art, grund, punkte from kandidaten order by id, punkte desc
  )
  select a.id, a.artikelnummer,
         (select al.wert from pim.artikel_alias al where al.artikel_id = a.id and al.typ = 'typbezeichnung' limit 1),
         (select string_agg(t.text, ' ' order by t.art) from pim.artikel_text t
           where t.artikel_id = a.id and t.sprache = 'de' and t.art in ('kurz1', 'kurz2')
             and t.quelle_id = (select t2.quelle_id from pim.artikel_text t2 join pim.quelle qq on qq.id = t2.quelle_id
                                 where t2.artikel_id = a.id and t2.art = 'kurz1'
                                 order by qq.prioritaet desc, qq.datenstand desc nulls last limit 1)),
         b.art, b.grund, b.punkte
    from best b join pim.artikel a on a.id = b.id
   order by b.punkte desc, (a.status = 'historisch'), a.artikelnummer
   limit anzahl
$$;

-- Bester Wert je Feld (Quelle mit höchster Priorität, dann neuester Datenstand)
create or replace view pim.v_artikel_de with (security_invoker = true) as
select a.id, a.artikelnummer, a.ean, a.status, a.hersteller_url,
       (select al.wert from pim.artikel_alias al where al.artikel_id = a.id and al.typ = 'typbezeichnung' limit 1) as typbezeichnung,
       tx.kurz1, tx.kurz2, tx.lang, tx.technik,
       (select t.text from pim.artikel_text t where t.artikel_id = a.id and t.art = 'titel' and t.sprache = 'en' limit 1) as titel_en,
       pr.betrag as listenpreis, pr.waehrung, pr.preiseinheit, pr.datenstand as preis_stand,
       (select g.name from pim.artikel_gruppe ag join pim.produktgruppe g on g.id = ag.gruppe_id
         where ag.artikel_id = a.id limit 1) as produktgruppe
  from pim.artikel a
  left join lateral (
    select max(t.text) filter (where t.art = 'kurz1') as kurz1,
           max(t.text) filter (where t.art = 'kurz2') as kurz2,
           max(t.text) filter (where t.art = 'lang') as lang,
           max(t.text) filter (where t.art = 'technik') as technik
      from pim.artikel_text t
     where t.artikel_id = a.id and t.sprache = 'de'
       and t.quelle_id = (select t2.quelle_id from pim.artikel_text t2 join pim.quelle q on q.id = t2.quelle_id
                           where t2.artikel_id = a.id and t2.sprache = 'de'
                           order by q.prioritaet desc, q.datenstand desc nulls last limit 1)
  ) tx on true
  left join lateral (
    select p.betrag, p.waehrung, p.preiseinheit, q.datenstand
      from pim.artikel_preis p join pim.quelle q on q.id = p.quelle_id
     where p.artikel_id = a.id and p.preisart = 'listenpreis' and p.markt = 'DE'
     order by q.datenstand desc nulls last, q.prioritaet desc limit 1
  ) pr on true;

revoke execute on function pim.suche(text, integer) from public, anon, authenticated;
revoke all on pim.v_artikel_de from anon, authenticated;
