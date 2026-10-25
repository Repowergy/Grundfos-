-- Sicherheits-Hinweis „function_search_path_mutable“ beheben: festen Suchpfad für Hilfsfunktionen setzen.
alter function pim.fuelle_vorlage(text[], text[]) set search_path = pim, public;
alter function pim.silben_zusammenfuegen(text) set search_path = pim, public;
alter function pim.gpi_datum(text) set search_path = pim, public;
alter function pim.einheit_norm(text) set search_path = pim, public;
alter function pim.zahl(text) set search_path = pim, public;
alter procedure pim.gpi_merkmale_job(integer) set search_path = pim, gpi, public;
