-- Bilder und Dokumente physisch bereitstellen (Freigabe zur vollständigen Nutzung liegt vor, 26.10.2026).
--
--  storage-Bucket 'medien' (öffentlich lesbar) – der Shop lädt Bilder/PDFs direkt über die öffentliche URL
--  pim.medium_datei   je Medium die beste physische Datei in Drive (Container + Pfad), Zielpfad im Bucket, Status
--  pim.medien_dateien_zuordnen()   füllt medium_datei:
--     GPC 2023 (gpc2023.datei): ProdPic/DrawDim/DrawElc/Qtp.zip, InstOper/<SPR>.zip, Service (TIF) und Service/*.zip
--     ARGE 2015 (raw.quelldatei, format 'bild'): GF_BILDER_*.zip
--     Abgleich über den Dateinamen ohne Endung; bei mehreren Treffern: Sprache passend, dann png/jpg/pdf vor gif,
--     tif (wird beim Hochladen in PNG umgewandelt) und np2 (Grundfos-Format, wird geprüft)
--  Hochladen: tools/import/medien_upload.py (Colab, Drive), setzt status und medium.storage_pfad

insert into storage.buckets (id, name, public) values ('medien', 'medien', true)
on conflict (id) do update set public = true;

create table if not exists pim.medium_datei (
  medium_id   bigint primary key references pim.medium(id) on delete cascade,
  basis       text not null,                 -- Drive-Ordner relativ zu MyDrive, z. B. '02 Grundfos/…/GPC'
  container   text,                          -- ZIP relativ zu basis (null = einzelne Datei)
  pfad        text not null,                 -- Datei im ZIP bzw. relativ zu basis
  ext         text,
  groesse     bigint,
  ziel_pfad   text not null,                 -- Pfad im Bucket 'medien'
  status      text not null default 'offen'
              check (status in ('offen', 'hochgeladen', 'fehler', 'format_unbekannt')),
  fehler      text,
  geaendert_am timestamptz not null default now()
);
create index if not exists medium_datei_status_idx on pim.medium_datei (status);
create index if not exists medium_datei_ziel_idx on pim.medium_datei (ziel_pfad);   -- Upload setzt Status je Zieldatei
alter table pim.medium_datei enable row level security;

create or replace function pim.medien_url(p_ziel text)
returns text
language sql immutable
as $$
  select 'https://xgpkjxjwcxelskygojvl.supabase.co/storage/v1/object/public/medien/' || p_ziel
$$;

create or replace function pim.medien_dateien_zuordnen()
returns table (schritt text, anzahl bigint)
language plpgsql
set search_path = pim, gpc2023, raw, public
as $body$
declare
  v_gpc text := '02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC';
  n bigint;
begin
  perform set_config('statement_timeout', '0', true);

  -- GPC 2023
  create temp table _f on commit drop as
  select lower(regexp_replace(d.name, '\.[^.]+$', '')) as k, d.container, d.pfad, lower(d.ext) as ext, d.groesse,
         upper(substring(d.pfad from '/([A-Z]{3})\.zip!')) as spr
    from gpc2023.datei d
   where (d.pfad ~ '^datafile/(ProdPic|DrawDim|DrawElc|Qtp)\.zip!/' or d.pfad ~ '^datafile/(InstOper|Service)/')
     and d.art in ('binaer', 'text') and lower(d.ext) in ('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.tif', '.tiff', '.np2');
  create index on _f (k);

  insert into pim.medium_datei (medium_id, basis, container, pfad, ext, groesse, ziel_pfad)
  select distinct on (m.id) m.id, v_gpc, f.container,
         case when f.container is null then f.pfad else substring(f.pfad from position('!/' in f.pfad) + 2) end,
         f.ext, f.groesse,
         'gpc/' || m.typ || '/' || regexp_replace(f.k, '[^a-z0-9._-]+', '_', 'g')   -- Leerzeichen u. Ä. → _ (URL)
           || case when f.ext in ('.tif', '.tiff') then '.png' else f.ext end
    from pim.medium m
    join _f f on f.k = lower(regexp_replace(regexp_replace(m.dateiname, '^.*/', ''), '\.[^.]+$', ''))
    left join pim.sprache ms on ms.iso = m.sprache
   where m.quelle_id = (select id from pim.quelle where typ = 'gpc' order by id limit 1)
   order by m.id,
            (f.spr is not distinct from ms.gpc_code) desc,          -- Sprache des Dokuments passt
            (f.spr = 'DEU') desc, (f.spr = 'ENU') desc,
            case f.ext when '.png' then 1 when '.jpg' then 2 when '.jpeg' then 2 when '.pdf' then 1
                       when '.gif' then 3 when '.tif' then 5 when '.tiff' then 5 else 9 end,
            f.groesse desc
  on conflict (medium_id) do nothing;
  get diagnostics n = row_count;
  schritt := 'GPC 2023'; anzahl := n; return next;

  -- ARGE 2015
  insert into pim.medium_datei (medium_id, basis, container, pfad, ext, groesse, ziel_pfad)
  select distinct on (m.id) m.id, '', split_part(q.pfad, '!/', 1), split_part(q.pfad, '!/', 2),
         lower(substring(q.pfad from '(\.[^.]+)$')), q.groesse,
         'arge/' || regexp_replace(lower(m.dateiname), '[^a-z0-9._-]+', '_', 'g')
    from pim.medium m
    join raw.quelldatei q on q.format = 'bild' and lower(q.pfad) like '%/' || lower(m.dateiname)
   where m.quelle_id = (select id from pim.quelle where typ = 'arge' order by id limit 1)
   order by m.id, q.groesse desc
  on conflict (medium_id) do nothing;
  get diagnostics n = row_count;
  schritt := 'ARGE 2015'; anzahl := n; return next;
end;
$body$;
revoke execute on function pim.medien_dateien_zuordnen() from public, anon, authenticated;
