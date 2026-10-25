-- Merkmal-Modul, Teil 2: deutsche Merkmalsnamen automatisch lernen (Werte-Abgleich).
--
-- DATANORM-Techniktexte enthalten Zeilen „Label: Wert Einheit“ (z. B. „Leistungsaufnahme P1: 300 W“).
-- Für Artikel, die zugleich GPC-Merkmale haben (z. B. P1W = 300), wird gezählt, wie oft ein Label
-- denselben Wert trägt wie ein Merkmalscode. Hohe Übereinstimmung ⇒ Label = deutscher Name des Codes.
--
--  * pim.merkmal_alias (quelle_typ 'datanorm_label'): alle Kandidaten mit Treffern und Quote
--  * pim.merkmal_uebersetzung (sprache 'de'): bestes Label je Code, Status 'maschinell' (bis geprüft)
--  * pim.technik_zeile: die zerlegten Techniktext-Zeilen (Label, Wert, Zahl, Einheit) – auch für
--    Artikel ohne GPC-Daten nutzbar: über merkmal_alias werden daraus echte Merkmale (Schritt 3)

alter table pim.merkmal_alias add column if not exists quote numeric;

create table if not exists pim.technik_zeile (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  quelle_id  bigint not null references pim.quelle(id),
  nr         integer not null,
  label      text not null,
  wert       text not null,
  wert_num   numeric,
  einheit    text,
  primary key (artikel_id, quelle_id, nr)
);
create index if not exists technik_zeile_label_idx on pim.technik_zeile (label);
alter table pim.technik_zeile enable row level security;

create or replace function pim.merkmale_lernen(min_treffer integer default 5, min_quote numeric default 0.8)
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, public
as $body$
declare
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  -- 1. Techniktexte zerlegen
  insert into pim.technik_zeile (artikel_id, quelle_id, nr, label, wert, wert_num, einheit)
  select t.artikel_id, t.quelle_id, z.nr::int, trim(split_part(z.zeile, ':', 1)),
         trim(substr(z.zeile, strpos(z.zeile, ':') + 1)),
         pim.zahl(substring(trim(substr(z.zeile, strpos(z.zeile, ':') + 1)) from '^[-+]?\d+(?:[.,]\d+)?')),
         nullif(trim(regexp_replace(trim(substr(z.zeile, strpos(z.zeile, ':') + 1)), '^[-+]?\d+(?:[.,]\d+)?\s*', '')), '')
    from pim.artikel_text t
    cross join lateral regexp_split_to_table(t.text, E'\n') with ordinality as z(zeile, nr)
   where t.art = 'technik' and z.zeile ~ '^[^:]{2,80}:\s*\S'
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '1 Techniktext-Zeilen zerlegt'; anzahl := n; return next;

  -- 2. Label ↔ Code über gleiche Werte am selben Artikel
  delete from pim.merkmal_alias where quelle_typ = 'datanorm_label' and status = 'kandidat';
  insert into pim.merkmal_alias (quelle_typ, quell_code, merkmal_code, sprache, treffer, quote, status)
  with paare as (
    select z.label, am.merkmal_code,
           (case when z.wert_num is not null and am.wert_num is not null then z.wert_num = am.wert_num
                 else lower(regexp_replace(z.wert, '\s+', '', 'g')) = lower(regexp_replace(am.wert, '\s+', '', 'g')) end) as gleich
      from pim.technik_zeile z
      join pim.artikel_merkmal am on am.artikel_id = z.artikel_id
  ), stat as (
    select label, merkmal_code, count(*) filter (where gleich) as treffer, count(*) as paare
      from paare group by 1, 2
  )
  select 'datanorm_label', label, merkmal_code, 'de', treffer, round(treffer::numeric / paare, 3), 'kandidat'
    from stat
   where treffer >= min_treffer and treffer::numeric / paare >= min_quote;
  get diagnostics n = row_count;
  schritt := '2 Label-Kandidaten'; anzahl := n; return next;

  -- 3. Deutscher Name je Code: Label mit den meisten Treffern (bei hoher Quote)
  insert into pim.merkmal_uebersetzung (merkmal_code, sprache, bezeichnung, status)
  select distinct on (merkmal_code) merkmal_code, 'de', quell_code, 'maschinell'
    from pim.merkmal_alias
   where quelle_typ = 'datanorm_label'
   order by merkmal_code, quote desc, treffer desc
  on conflict (merkmal_code, sprache) do update
     set bezeichnung = excluded.bezeichnung
   where pim.merkmal_uebersetzung.status = 'maschinell';
  get diagnostics n = row_count;
  schritt := '3 deutsche Merkmalsnamen'; anzahl := n; return next;

  -- 4. Artikel ohne GPC-Daten: Merkmale aus Techniktext über das beste Label je Code
  insert into pim.artikel_merkmal (artikel_id, merkmal_code, wert, wert_num, sprache, quelle_id)
  select distinct on (z.artikel_id, b.merkmal_code, z.quelle_id)
         z.artikel_id, b.merkmal_code, z.wert, z.wert_num, '-', z.quelle_id
    from pim.technik_zeile z
    join (select distinct on (quell_code) quell_code, merkmal_code
            from pim.merkmal_alias where quelle_typ = 'datanorm_label'
           order by quell_code, quote desc, treffer desc) b on b.quell_code = z.label
   order by z.artikel_id, b.merkmal_code, z.quelle_id, z.nr
  on conflict do nothing;
  get diagnostics n = row_count;
  schritt := '4 Merkmale aus Techniktexten'; anzahl := n; return next;
end;
$body$;

revoke execute on function pim.merkmale_lernen(integer, numeric) from public, anon, authenticated;
