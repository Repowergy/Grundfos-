-- Marktpreise: Preise anderer Shops je Artikel und Land (Recherche 27.10.2026: DE, AT, CH; später weitere Länder)
--
--  pim.wettbewerber          Shops (Name, URL, Land, Art, Schwerpunkt, Grundfos-Ersatzteile ja/nein)
--  pim.marktpreis            ein beobachteter Preis: Artikel, Shop, Land, Bruttopreis, Währung, Versand, URL, Datum, Quelle
--  pim.v_marktpreis_aktuell  je Artikel und Land: Anzahl Angebote, Minimum, Median, Maximum (letzte 90 Tage, in EUR)
-- Erfasst werden nur einzeln aufgerufene, öffentliche Seiten bzw. Preisportale (kein Massenabruf).

create table if not exists pim.wettbewerber (
  id            bigserial primary key,
  name          text not null,
  url           text,
  land          text not null,                 -- DE, AT, CH, … (DE/AT bei mehreren)
  art           text,                          -- B2C, B2B, Marktplatz, Hersteller-Partner
  schwerpunkt   text,
  ersatzteile   boolean,
  notiz         text,
  gefunden_ueber text,
  erfasst_am    date not null default current_date,
  unique (name, land)
);
alter table pim.wettbewerber enable row level security;

create table if not exists pim.marktpreis (
  id             bigserial primary key,
  artikel_id     bigint references pim.artikel(id) on delete cascade,
  typbezeichnung text,                         -- wie im Shop angezeigt
  artikelnummer_im_shop text,
  ean_passt      boolean,
  wettbewerber_id bigint references pim.wettbewerber(id) on delete set null,
  shop           text not null,
  land           text not null,
  url            text,
  preis_brutto   numeric(12,2) not null,
  waehrung       text not null default 'EUR',
  preis_eur      numeric(12,2),                 -- umgerechnet (CHF → EUR mit dem Kurs des Erfassungstags)
  versand        numeric(12,2),
  verfuegbarkeit text,
  quelle         text,                          -- Portal (idealo, geizhals, toppreise …) oder Shop direkt
  datum          date not null default current_date
);
create index if not exists marktpreis_artikel_idx on pim.marktpreis (artikel_id, land, datum);
alter table pim.marktpreis enable row level security;

create or replace view pim.v_marktpreis_aktuell with (security_invoker = true) as
select m.artikel_id, a.artikelnummer, m.land,
       count(*) as angebote,
       min(m.preis_eur) as min_eur,
       percentile_cont(0.5) within group (order by m.preis_eur) as median_eur,
       max(m.preis_eur) as max_eur,
       (array_agg(m.shop order by m.preis_eur))[1] as guenstigster_shop,
       max(m.datum) as stand
  from pim.marktpreis m
  join pim.artikel a on a.id = m.artikel_id
 where m.datum >= current_date - 90 and m.preis_eur is not null
 group by m.artikel_id, a.artikelnummer, m.land;
