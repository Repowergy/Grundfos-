-- Text-Engine: Produkttexte in allen HybrisQt-Sprachen aus Merkmalen erzeugen (Nachbau der Grundfos-Logik).
--
-- Aufbau der Quelle (siehe 0015):
--   FAM_<Baureihe>          Einstieg je Baureihe, z. B. FAM_CR: {PRODNAME} · {%TEXTOPTION=SHORT}{_FI_TXTSHO_CR}{!}
--   _FI_TXTSHO_/_FI_TXTLON_ Vorlage je Sprache, Zeile für Zeile Verweise auf Regeldateien ({_FI_CONSHO_CR_MOTOR}{!})
--   Regeldatei              Zeilen {MERKMAL=WERT}…{ZIEL}{!}: die erste passende Zeile liefert den Baustein ({!} = Stopp)
--   Baustein je Sprache     Text mit Platzhaltern, z. B. „Die Pumpe ist mit einem {PHASE}-phasigen … Motor ausgestattet.“
-- Operatoren: =  ?(Regex)  <  >  >=  =<   ·  {br} = Absatz  ·  >>/>>> = Überschrift  ·  {_GI, …} = Bild (übersprungen)
--
-- Die Hybris-Merkmale weichen teils von der GPC-Datenbank ab: PUMPTYPE ist dort die Baureihe („CRN“), die Größe steht
-- in PUMP_SIZE („32“). pim.text_merkmale() leitet beides aus PUMPTYPE2 / PUMPTYPE („CR 32“) bzw. der Typbezeichnung ab.
-- Fehlt für eine Zeile ein Merkmal, entfällt die Zeile (lieber kürzer als falsch).
-- Ergebnis: pim.artikel_text art 'kurz1' (SHORT) bzw. 'lang' (LONG), Quelle 'textengine' (Priorität 50 = unter echten Texten).

create table if not exists pim.text_familie (
  familie       text primary key,        -- Regeldatei, z. B. 'FAM_CR'
  gruppen_regex text not null            -- Regex auf pim.produktgruppe.name
);
alter table pim.text_familie enable row level security;
insert into pim.text_familie values
  ('FAM_CR',            '^(CR|CRI|CRN|CRE|CRIE|CRNE|CRT|CRTE)( |-|$)'),
  ('FAM_CM',            '^(CM|CME)( |$)'),
  ('FAM_CM-V',          '^CMV( |$)'),
  ('FAM_MTR',           '^(MTR|MTRE)( |$)'),
  ('FAM_NB',            '^(NB|NBE|NBG|NBGE)( |$)'),
  ('FAM_NK',            '^(NK|NKE)( |$)'),
  ('FAM_NKG',           '^(NKG|NKGE)( |$)'),
  ('FAM_TP',            '^(TP|TPD|TPE|TPED)( |$)'),
  ('FAM_SP',            '^SP( |,|$)'),
  ('FAM_SEG',           '^SEG( |$)'),
  ('FAM_S',             '^S( |$)'),
  ('FAM_COMFORT',       '^COMFORT'),
  ('FAM_HYDRO_MPC',     '^Hydro MPC'),
  ('FAM_HYDRO_MULTI-E', '^Hydro Multi-E')
on conflict do nothing;

-- Merkmale eines Artikels als {CODE: Wert} (beste Quelle) + abgeleitete Hybris-Merkmale
create or replace function pim.text_merkmale(p_artikel bigint)
returns jsonb
language sql stable
set search_path = pim, public
as $$
  with m as (
    select distinct on (am.merkmal_code) am.merkmal_code, am.wert
      from pim.artikel_merkmal am left join pim.quelle q on q.id = am.quelle_id
     where am.artikel_id = p_artikel and am.wert is not null and am.wert <> ''
     order by am.merkmal_code, q.prioritaet desc nulls last
  ), j as (
    select coalesce(jsonb_object_agg(merkmal_code, wert), '{}'::jsonb) as j from m
  ), n as (
    select coalesce(j.j->>'PRODNAME',
                    (select al.wert from pim.artikel_alias al
                      where al.artikel_id = p_artikel and al.typ = 'typbezeichnung' order by al.wert limit 1)) as prodname,
           j.j
      from j
  ), t as (
    select n.*,
           regexp_match(coalesce(n.j->>'PUMPTYPE', ''), '^([A-Za-z]+)\s+(\d+[sS]?)$') as pt,
           regexp_match(coalesce(n.prodname, ''), '^([A-Za-z]+)\s*(\d+[sS]?)\M') as pn
      from n
  )
  select t.j
         || jsonb_strip_nulls(jsonb_build_object(
              'PRODNAME', t.prodname,
              'PUMPTYPE_GPC', t.j->>'PUMPTYPE',
              'PUMPTYPE', upper(coalesce(t.j->>'PUMPTYPE2', t.pt[1], t.pn[1], t.j->>'PUMPTYPE')),
              'PUMP_SIZE', coalesce(t.j->>'PUMP_SIZE', upper(t.pt[2]), upper(t.pn[2])),
              'PHASES', coalesce(t.j->>'PHASES', t.j->>'PHASE')))
    from t
$$;

-- Eine Bedingung {NAME op WERT} prüfen; null = Token ist keine Bedingung
create or replace function pim.text_bedingung(token text, m jsonb, p_option text)
returns boolean
language plpgsql immutable
set search_path = pim, public
as $$
declare
  t text[] := regexp_match(token, '^(%?[A-Za-z0-9_]+)(=<|>=|<=|!=|=|<|>|\?)(.*)$');
  v text;
begin
  if t is null then return null; end if;
  v := case when t[1] = '%TEXTOPTION' then p_option else m->>t[1] end;
  if v is null then return false; end if;
  case t[2]
    when '='  then return upper(trim(v)) = upper(trim(t[3]));
    when '!=' then return upper(trim(v)) <> upper(trim(t[3]));
    when '?'  then
      begin return v ~* t[3]; exception when others then return false; end;
    else
      if pim.zahl(v) is null or pim.zahl(t[3]) is null then return false; end if;
      return case t[2] when '<' then pim.zahl(v) < pim.zahl(t[3]) when '>' then pim.zahl(v) > pim.zahl(t[3])
                       when '>=' then pim.zahl(v) >= pim.zahl(t[3]) else pim.zahl(v) <= pim.zahl(t[3]) end;
  end case;
end;
$$;

-- Schlüssel auflösen: Regeldatei (erste passende Zeile) oder Baustein der Sprache (mit Platzhaltern)
create or replace function pim.text_aufloesen(p_schluessel text, p_sprache text, m jsonb, p_option text,
                                              p_tiefe integer default 0)
returns text
language plpgsql stable
set search_path = pim, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'gpc2023' order by id limit 1);
  r record;
  tok record;
  ok boolean;
  b boolean;
  stop boolean;
  teil text;
  zeile text;
  zeilen text[] := '{}';
begin
  if p_tiefe > 10 then return null; end if;

  if exists (select 1 from pim.text_regel where quelle_id = v_quelle and schluessel = p_schluessel) then
    for r in select roh from pim.text_regel where quelle_id = v_quelle and schluessel = p_schluessel order by nr loop
      ok := true; stop := false; zeile := '';
      for tok in select x[1] as klammer, x[2] as frei from regexp_matches(r.roh, '\{([^}]*)\}|([^{}]+)', 'g') x loop
        if tok.klammer is null then
          if trim(tok.frei) not in ('', '??') then zeile := zeile || tok.frei; end if;
        elsif trim(tok.klammer) = '!' then stop := true;
        else
          b := pim.text_bedingung(tok.klammer, m, p_option);
          if b is false then ok := false; exit; end if;
          if b is null then
            if tok.klammer like '\_GI,%' then null;                            -- Bild
            elsif tok.klammer like '\_%' then
              teil := pim.text_aufloesen(tok.klammer, p_sprache, m, p_option, p_tiefe + 1);
              if teil is not null then zeile := zeile || teil; end if;
            elsif m ? tok.klammer then zeile := zeile || (m->>tok.klammer);  -- Platzhalter, z. B. {PRODNAME}
            end if;
          end if;
        end if;
      end loop;
      if ok then
        if trim(zeile) <> '' then zeilen := zeilen || zeile; end if;
        if stop then exit; end if;
      end if;
    end loop;
    return nullif(array_to_string(zeilen, E'\n'), '');
  end if;

  for r in select text from pim.textbaustein
            where quelle_id = v_quelle and schluessel = p_schluessel and sprache = p_sprache order by textbaustein.zeile loop
    ok := true; zeile := '';
    for tok in select x[1] as klammer, x[2] as frei from regexp_matches(coalesce(r.text, ''), '\{([^}]*)\}|([^{}]+)', 'g') x loop
      if tok.klammer is null then zeile := zeile || tok.frei;
      elsif trim(tok.klammer) in ('!', '') then null;
      elsif tok.klammer = 'br' then zeile := zeile || E'\n';
      else
        b := pim.text_bedingung(tok.klammer, m, p_option);
        if b is false then ok := false; exit; end if;
        if b is null then
          if tok.klammer like '\_GI,%' then null;
          elsif tok.klammer like '\_%' then
            teil := pim.text_aufloesen(tok.klammer, p_sprache, m, p_option, p_tiefe + 1);
            if teil is not null then zeile := zeile || teil; end if;
          elsif m ? tok.klammer then zeile := zeile || (m->>tok.klammer);
          else ok := false; exit;                                              -- Merkmal fehlt → Zeile entfällt
          end if;
        end if;
      end if;
    end loop;
    if ok and trim(zeile) <> '' then zeilen := zeilen || zeile; end if;
  end loop;
  return nullif(array_to_string(zeilen, E'\n'), '');
end;
$body$;

-- Text für einen Artikel: Baureihe über die Produktgruppe, dann FAM_<Baureihe> auswerten.
-- Überschriften (>>…) ohne folgenden Inhalt werden entfernt.
create or replace function pim.text_erzeugen(p_artikel bigint, p_sprache text default 'de', p_option text default 'SHORT')
returns text
language plpgsql stable
set search_path = pim, public
as $body$
declare
  v_fam text;
  v_text text;
  z text[];
  aus text[] := '{}';
  i integer;
begin
  select f.familie into v_fam
    from pim.artikel_gruppe ag
    join pim.produktgruppe pg on pg.id = ag.gruppe_id
    join pim.text_familie f on pg.name ~ f.gruppen_regex
   where ag.artikel_id = p_artikel
   order by length(f.gruppen_regex) desc
   limit 1;
  if v_fam is null then return null; end if;

  v_text := pim.text_aufloesen(v_fam, p_sprache, pim.text_merkmale(p_artikel), p_option);
  if v_text is null then return null; end if;
  z := regexp_split_to_array(v_text, E'\n');
  for i in 1 .. coalesce(array_length(z, 1), 0) loop
    if trim(z[i]) = '' then continue; end if;
    if z[i] ~ '^>>' and (i = array_length(z, 1) or z[i + 1] ~ '^>>' or trim(z[i + 1]) = '') then
      -- Überschrift ohne Inhalt direkt darunter: nur behalten, wenn eine Unterüberschrift mit Inhalt folgt
      if not (i < array_length(z, 1) and z[i + 1] ~ '^>>>' and z[i] !~ '^>>>') then continue; end if;
    end if;
    aus := aus || z[i];
  end loop;
  return nullif(array_to_string(aus, E'\n'), '');
end;
$body$;

revoke execute on function pim.text_merkmale(bigint) from public, anon, authenticated;
revoke execute on function pim.text_bedingung(text, jsonb, text) from public, anon, authenticated;
revoke execute on function pim.text_aufloesen(text, text, jsonb, text, integer) from public, anon, authenticated;
revoke execute on function pim.text_erzeugen(bigint, text, text) from public, anon, authenticated;

-- Massenlauf: Arbeitsliste (Artikel × Sprache), abgearbeitet in Paketen per pg_cron (pim.texte_schritt)
alter table pim.artikel_text drop constraint if exists artikel_text_art_check;
alter table pim.artikel_text add constraint artikel_text_art_check
  check (art in ('kurz1', 'kurz2', 'titel', 'lang', 'technik', 'ausschreibung', 'seo_titel', 'seo_beschreibung',
                 'beschreibung'));

insert into pim.quelle (typ, bezeichnung, datenstand, prioritaet)
select 'textengine', 'Text-Engine (HybrisQt-Regeln × Merkmale, maschinell erzeugt)', current_date, 50
 where not exists (select 1 from pim.quelle where typ = 'textengine');

create table if not exists pim.text_auftrag (
  artikel_id bigint not null references pim.artikel(id) on delete cascade,
  sprache    text not null,
  erledigt   boolean not null default false,
  primary key (artikel_id, sprache)
);
create index if not exists text_auftrag_offen_idx on pim.text_auftrag (sprache, artikel_id) where not erledigt;
alter table pim.text_auftrag enable row level security;

create or replace function pim.texte_auftrag_anlegen(p_sprachen text[] default array['de', 'en'])
returns bigint
language sql
set search_path = pim, public
as $$
  with ins as (
    insert into pim.text_auftrag (artikel_id, sprache)
    select distinct ag.artikel_id, s
      from pim.text_familie f
      join pim.produktgruppe pg on pg.name ~ f.gruppen_regex
      join pim.artikel_gruppe ag on ag.gruppe_id = pg.id
      cross join unnest(p_sprachen) s
    on conflict do nothing returning 1)
  select count(*) from ins
$$;

-- Ein Paket: SHORT → art 'beschreibung', LONG → art 'lang'; gibt die Zahl der bearbeiteten Aufträge zurück
create or replace function pim.texte_schritt(p_paket integer default 400)
returns integer
language plpgsql
set search_path = pim, public
as $body$
declare
  v_quelle bigint := (select id from pim.quelle where typ = 'textengine' order by id limit 1);
  r record;
  t text;
  n integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  for r in select artikel_id, sprache from pim.text_auftrag where not erledigt
            order by sprache, artikel_id limit p_paket for update skip locked loop
    t := pim.text_erzeugen(r.artikel_id, r.sprache, 'SHORT');
    if t is not null then
      insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
      values (r.artikel_id, r.sprache, 'beschreibung', t, v_quelle)
      on conflict (artikel_id, sprache, art, quelle_id) do update set text = excluded.text;
    end if;
    t := pim.text_erzeugen(r.artikel_id, r.sprache, 'LONG');
    if t is not null then
      insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
      values (r.artikel_id, r.sprache, 'lang', t, v_quelle)
      on conflict (artikel_id, sprache, art, quelle_id) do update set text = excluded.text;
    end if;
    update pim.text_auftrag set erledigt = true where artikel_id = r.artikel_id and sprache = r.sprache;
    n := n + 1;
  end loop;
  return n;
end;
$body$;
revoke execute on function pim.texte_auftrag_anlegen(text[]) from public, anon, authenticated;
revoke execute on function pim.texte_schritt(integer) from public, anon, authenticated;
