-- Korrektur: gpi.LiteratureFile.Id ist je Sprache gleich – Schlüssel = Id + Sprache + Dokument.
-- Die mit dem alten Schlüssel angelegten Literatur-Medien (nur je eine Sprache) werden ersetzt.
delete from pim.medium where quell_schluessel ~ '^gpi\.literaturefile:\d+$';
-- danach: select * from pim.medien_uebernehmen();  (übrige Schritte sind idempotent)
