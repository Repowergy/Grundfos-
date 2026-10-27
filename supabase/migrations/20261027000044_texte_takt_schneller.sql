-- texte_takt: ein Durchlauf mit 120 Shop-Texten dauerte ~8 s → je Minute 700 Shop-Texte bzw. 1.500 Text-Engine-Aufträge
create or replace function pim.texte_takt()
returns text
language plpgsql
set search_path = pim, public
as $body$
declare a integer := 0; b integer := 0;
begin
  perform set_config('statement_timeout', '0', true);
  if exists (select 1 from pim.text_auftrag where not erledigt and prioritaet = 1) then
    a := pim.texte_schritt(800);
  else
    b := pim.shop_texte_schritt(700);
    if b = 0 then a := pim.texte_schritt(1500); end if;
  end if;
  return 'textengine ' || a || ' · shoptexte ' || b;
end;
$body$;
revoke execute on function pim.texte_takt() from public, anon, authenticated;
