# KI-Stack Arbeitsvertrag

- Maßgeblich ist ausschließlich der tatsächlich vorhandene Dateiinhalt.
- Git, Commits, Tags und Tree-Hashes sind keine Installations- oder Validierungsgrundlage.
- Vor Änderungen zuerst reale Pfade, Manifeste, Versionen und vorhandene Tests prüfen.
- Bestehende Benutzeränderungen und nicht zum Auftrag gehörende Dateien erhalten.
- Vollständige direkt nutzbare Dateien und Pakete liefern; keine bloßen Patch-Anweisungen.
- Änderungen müssen transaktionsfähig, wiederholbar und rücksetzbar sein.
- Dateiverträge verwenden relative Pfade, Bytegrößen und SHA256.
- Nach Fehlern Ursache beheben und alle betroffenen Tests erneut ausführen.
- Keine Erfolgsmeldung ohne tatsächlichen Readback und dokumentierten Testnachweis.
- Längeren Quellcode nicht als Ergebnis ausgeben; stattdessen Dateien, Änderungen und Prüfergebnisse nennen.

## Prüfung

Vor einer Freigabe mindestens die vorhandenen Syntax-, Paket-, Pfad- und historischen Regressionstests ausführen. Neue Funktionen erhalten eigene negative und positive Tests.
