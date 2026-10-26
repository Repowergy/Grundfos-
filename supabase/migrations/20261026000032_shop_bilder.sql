-- Bilder je Shop-Produkt mit Ersatzlösungen (Entscheidung 26.10.2026):
--   1. eigene Produktbilder (ARGE: nur Druckversion, s. 0029)
--   2. Ersatzteil ohne Bild → Explosionszeichnung der Pumpen, in die es passt (häufigste zuerst, max. 2);
--      Bildtext „Explosionszeichnung – Position 49“ (Positionsnummer aus artikel_beziehung)
--   3. sonst → Bild der Baureihe (eigene Gruppe oder übergeordnete Gruppe)
-- Ergebnis: {"urls": [...], "alt": "…", "art": "eigen" | "explosionszeichnung" | "baureihe"}

create or replace function pim.shop_bilder(p_artikel bigint, p_produktart text default null)
returns jsonb
language plpgsql stable
set search_path = pim, public
as $body$
declare
  v_urls jsonb;
  v_pos text;
begin
  select coalesce(jsonb_agg(b.extern_url order by b.sortierung nulls last, b.id), '[]') into v_urls
    from (select distinct on (regexp_replace(lower(m.dateiname), '^(gf[a-z])_[wd]', '\1_'))
                 m.id, m.extern_url, am.sortierung
            from pim.artikel_medium am join pim.medium m on m.id = am.medium_id
           where am.artikel_id = p_artikel and m.typ = 'bild' and m.extern_url is not null
           order by regexp_replace(lower(m.dateiname), '^(gf[a-z])_[wd]', '\1_'),
                    (lower(m.dateiname) ~ '^gf[a-z]_d') desc, m.id) b;
  if jsonb_array_length(v_urls) > 0 then
    return jsonb_build_object('urls', v_urls, 'art', 'eigen');
  end if;

  if p_produktart = 'ersatzteil' then
    with p as (
      select b.von_artikel_id, b.position from pim.artikel_beziehung b
       where b.zu_artikel_id = p_artikel and b.typ = 'ersatzteil' limit 5000
    ), z as (
      select m.extern_url, count(*) as n,
             mode() within group (order by p.position) filter (where p.position is not null) as pos
        from p
        join pim.artikel_medium am on am.artikel_id = p.von_artikel_id
        join pim.medium m on m.id = am.medium_id and m.typ = 'explosionszeichnung' and m.extern_url is not null
       group by m.extern_url
       order by count(*) desc limit 2
    )
    select jsonb_agg(extern_url order by n desc), max(pos) into v_urls, v_pos from z;
    if v_urls is not null then
      return jsonb_build_object('urls', v_urls, 'art', 'explosionszeichnung',
                                'alt', 'Explosionszeichnung' || coalesce(' – Position ' || v_pos, ''));
    end if;
  end if;

  select jsonb_agg(u) into v_urls from (
    select m.extern_url as u
      from pim.artikel_gruppe ag
      join pim.produktgruppe g on g.id = ag.gruppe_id
      join pim.produktgruppe o on g.baum like o.baum || '%'
      join pim.gruppe_medium gm on gm.gruppe_id = o.id
      join pim.medium m on m.id = gm.medium_id and m.typ = 'bild' and m.extern_url is not null
     where ag.artikel_id = p_artikel
     order by length(o.baum) desc, m.id
     limit 1) x;
  if v_urls is not null then
    return jsonb_build_object('urls', v_urls, 'art', 'baureihe', 'alt', 'Abbildung Baureihe');
  end if;
  return jsonb_build_object('urls', '[]'::jsonb, 'art', null);
end;
$body$;
revoke execute on function pim.shop_bilder(bigint, text) from public, anon, authenticated;
