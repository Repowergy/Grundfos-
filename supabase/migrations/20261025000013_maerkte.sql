-- Märkte (Länder) und Länder-Sortimente aus der GPC-Datenbank (Stand 10/2015).
--
--  pim.markt          Land/Markt mit ISO-Code, Währung und GPC-Kürzel (Deutschland = gws, Österreich = gpo, Schweiz = gps)
--  pim.artikel_markt  Artikel ist im Sortiment des Marktes (+ GPC-Status, Fasttrack)
--  pim.artikel_preis  Listenpreis je Markt und Währung (nur Preise > 0)
-- Sonder-Listen (General, Total, Händler-/Testlisten) bleiben als Markt 'GPC:<kürzel>' erhalten.

create table if not exists pim.markt (
  code      text primary key,          -- ISO 3166-1 alpha-2 oder 'GPC:<kürzel>'
  name      text not null,
  waehrung  text,
  gpc_code  text unique,               -- z. B. 'gws'
  ist_land  boolean not null default true
);
alter table pim.markt enable row level security;

alter table pim.artikel_markt add column if not exists gpc_status text, add column if not exists fasttrack boolean;

create or replace function pim.maerkte_uebernehmen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpi, public
as $body$
declare
  v_quelle bigint;
  r record;
  n bigint;
  gesamt_m bigint := 0;
  gesamt_p bigint := 0;
begin
  perform set_config('statement_timeout', '0', true);
  select id into v_quelle from pim.quelle where typ = 'gpc' order by id limit 1;

  insert into pim.markt (code, name, waehrung, gpc_code, ist_land)
  select coalesce(iso, 'GPC:' || kuerzel), c.designation, nullif(c.currency, 'TD'), kuerzel, iso is not null
    from (select designation, currency, lower(substr(prodrangetablename, 14)) as kuerzel,
                 case designation
                   when 'Australia' then 'AU' when 'Austria' then 'AT' when 'Belarus' then 'BY' when 'Bosnia' then 'BA'
                   when 'Brazil' then 'BR' when 'Bulgaria' then 'BG' when 'Canada' then 'CA' when 'China' then 'CN'
                   when 'Colombia' then 'CO' when 'Croatia' then 'HR' when 'Czech Republic' then 'CZ'
                   when 'Denmark' then 'DK' when 'Egypt' then 'EG' when 'Estonia' then 'EE' when 'Finland' then 'FI'
                   when 'France' then 'FR' when 'Germany' then 'DE' when 'Hungary' then 'HU' when 'India' then 'IN'
                   when 'Italy' then 'IT' when 'Kazakhstan' then 'KZ' when 'Korea' then 'KR' when 'Latvia' then 'LV'
                   when 'Lithuania' then 'LT' when 'Mexico' then 'MX' when 'Norway' then 'NO' when 'Poland' then 'PL'
                   when 'Portugal' then 'PT' when 'Romania' then 'RO' when 'Russia' then 'RU'
                   when 'Serbia and Montenegro' then 'RS' when 'Slovakia' then 'SK' when 'Slovenia' then 'SI'
                   when 'South Africa' then 'ZA' when 'Spain' then 'ES' when 'Sweden' then 'SE'
                   when 'Switzerland' then 'CH' when 'Taiwan' then 'TW' when 'The Netherlands' then 'NL'
                   when 'Turkey' then 'TR' when 'Ukraine' then 'UA' when 'United Arab Emirates' then 'AE'
                   when 'United Kingdom' then 'GB' when 'USA' then 'US' when 'Uzbekistan' then 'UZ'
                 end as iso
            from gpi.productrange__configuration
           where prodrangetablename like 'ProductRange\_%') c
  on conflict (code) do nothing;
  get diagnostics n = row_count;
  schritt := 'Märkte'; anzahl := n; return next;

  for r in
    select m.code, m.waehrung, 'productrange_' || m.gpc_code as tab
      from pim.markt m
     where m.gpc_code is not null
       and to_regclass('gpi.' || quote_ident('productrange_' || m.gpc_code)) is not null
  loop
    execute format($q$
      insert into pim.artikel_markt (artikel_id, markt, status, gpc_status, fasttrack, quelle_id)
      select distinct on (a.id) a.id, %L, 'sortiment', nullif(p.status, ''), p.fasttrack = '1', %s
        from gpi.%I p
        join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
       order by a.id
      on conflict do nothing$q$, r.code, v_quelle, r.tab);
    get diagnostics n = row_count;
    gesamt_m := gesamt_m + n;
    if r.waehrung is not null then
      execute format($q$
        insert into pim.artikel_preis (artikel_id, markt, preisart, betrag, waehrung, quelle_id)
        select distinct on (a.id) a.id, %L, 'listenpreis', pim.zahl(p.price), %L, %s
          from gpi.%I p
          join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = upper(replace(trim(p.productno), ' ', ''))
         where pim.zahl(p.price) > 0
           and not exists (select 1 from pim.artikel_preis x
                            where x.artikel_id = a.id and x.markt = %L and x.quelle_id = %s)
         order by a.id$q$, r.code, r.waehrung, v_quelle, r.tab, r.code, v_quelle);
      get diagnostics n = row_count;
      gesamt_p := gesamt_p + n;
    end if;
  end loop;
  schritt := 'Artikel ↔ Markt (Sortiment)'; anzahl := gesamt_m; return next;
  schritt := 'Listenpreise je Markt'; anzahl := gesamt_p; return next;
end;
$body$;
revoke execute on function pim.maerkte_uebernehmen() from public, anon, authenticated;
