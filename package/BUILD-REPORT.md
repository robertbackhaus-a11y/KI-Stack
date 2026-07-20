# KI-Stack Applications v1.4.10 – Repair Report

## Ursache

`Bootstrap\Test-Bundle.ps1` prüfte den Publisher mit expandierbaren Doppelquote-Strings. Unter `Set-StrictMode -Version Latest` wurden dabei `$GitAuthorName`, `$GitAuthorEmail` und `$workPath` im Validator selbst ausgewertet, obwohl diese Variablen dort nicht definiert sind. Die Bundle-Validierung brach deshalb vor dem Publisher ab.

## Korrektur

- Sämtliche Publisher-Quelltextprüfungen verwenden echte PowerShell-Literale ohne Variablenexpansion.
- Neuer Regressionstest blockiert doppelt quotierte `.Contains(...)`-Prüfungen mit `$GitAuthorName`, `$GitAuthorEmail` oder `$workPath`.
- Git-Autoridentität bleibt repository-lokal im temporären Clone und wird vor Commit und annotiertem Tag validiert.
- Applications-Laufzeitlogik bleibt gegenüber dem zielsystemvalidierten Stand funktional unverändert.
