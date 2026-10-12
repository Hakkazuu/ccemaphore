# ccemaphore

[English](README.md) · [Русский](README.ru.md) · [Español](README.es.md) · **Deutsch** · [Français](README.fr.md)

> Eine schwebende Ampel für deine [Claude-Code](https://claude.com/claude-code)- und
> [Codex](https://chatgpt.com/codex)-Sitzungen (ChatGPT-App) auf macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Öffne die Claude-Desktop-App, mehrere Cursor-/VS-Code-Fenster und Codex in der ChatGPT-App
nebeneinander, jeweils mit mehreren Agenten-Chats, und eine einzige, stets sichtbare Anzeige sagt dir –
auf einen Blick, ohne Fensterwechsel –, ob ein Agent arbeitet, fertig ist oder dich braucht.

## ⬇️ Herunterladen

### **[Neueste Version herunterladen (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Von Apple signiert & notarisiert. Ziehe sie in **Programme** und starte sie – ohne Gatekeeper-Warnungen.
Erfordert **macOS 13 oder neuer**. Einmal installiert, [aktualisiert es sich selbst](#updates).
[Vollständige Installationsschritte ↓](#installation)

📄 **[Änderungsprotokoll](CHANGELOG.md)** — was in jeder Version neu ist.

```
🟡  mindestens eine Sitzung arbeitet
🟢  keine arbeitet — alles sauber abgeschlossen
🔴  keine arbeitet — mindestens eine wartet auf dich
⚪  keine aktiven Sitzungen
```

---

## Funktionen

ccemaphore ist ein kleines **schwebendes Licht**, das über allem liegt (auch über Vollbild-Spaces). Es
fasst den Zustand *aller* deiner Claude-Code-Chats über alle Fenster hinweg in einer einzigen Farbe
zusammen – damit du nie das Fenster wechseln musst, nur um den Status zu prüfen.

- **Fahre mit der Maus über das Licht** → es öffnet sich ein Panel mit jeder aktiven Sitzung, gruppiert
  in **Wartend → Arbeitet → Fertig**: Projekt · Git-Branch · Chat-Titel · Kontext-% · der laufende
  Befehl. Unten im Panel liegen **Chats**, **Verlauf**, **Einstellungen** und **Beenden**; **↻** oben
  aktualisiert die Liste.
- **Ziehe** das Licht überallhin; schalte **Position fixieren** in den Einstellungen ein, um es dort
  festzusetzen.
- **Ein Chat braucht eine Freigabe?** Das Licht verwandelt sich direkt an Ort und Stelle in ein **Band**
  – **Erlauben / Ablehnen / Alle im Chat** (ab jetzt alles in diesem Chat erlauben), samt genauem Befehl –
  damit du ohne den Chat zu öffnen entscheidest.
- **Ein Chat ist fertig?** Am Licht erscheint ein grüner „Fertig“-Hinweis; klicke **Chat öffnen**, um
  direkt dorthin zu springen (es hebt den richtigen Cursor-Tab oder das Terminal hervor).
- **Kontext wird komprimiert?** Die gelbe Lampe zeigt ein kleines Komprimier-Symbol – beschäftigt,
  nicht hängengeblieben.
- **Zwei Agenten, ein Licht.** Codex-Threads aus der ChatGPT-App (oder der Codex-CLI) stehen neben den
  Claude-Code-Chats; jede Zeile trägt ein Agenten-Badge (Claude / Codex) und ein Host-Symbol (Claude-App,
  IDE, Terminal, ChatGPT-App). **Chat öffnen** – oder ein Klick auf die Zeile des Chats im Panel – öffnet
  den richtigen Ort: den Cursor-Tab, die Sitzung in der Claude-App oder den Codex-Thread.
- **Unteragenten.** Ein Chat mit Unteragenten (Claude-`Task`-Agenten, Workflows, Codex-Unterthreads)
  bekommt ein Chevron – ausklappen und sehen, was jeder gerade tut.
- **Nach Produkt gruppieren.** Backend, Frontend und Landing eines Produkts gleichzeitig? Wähle
  **Nach Produkt** unter **Einstellungen ▸ Produktgruppen**: Der Chats-Tab gruppiert die Chats dann nach
  Produktordner (`Produkt › Unter-Repo`); ChatGPT-App-Projekte und Ordner mit mehreren Repos werden
  automatisch vorgeschlagen.
- **Codex-Limits.** Die 5-Stunden- / Wochenfenster, die Codex meldet, am Ende des Chats-Tabs.

Alles passiert *am Licht*. Es gibt keine System-Benachrichtigungen, denen du hinterherlaufen musst.

Token- und Kostenstatistiken pro Sitzung sowie ein Tagesverlauf-Fenster stammen aus
[`ccusage`](https://github.com/ryoppippi/ccusage), sofern verfügbar – für Claude Code und Codex gleichermaßen
(ccusage ≥ 20), mit Claude-/Codex-Aufteilung und Filter im Verlaufsfenster.

## Sprachen

ccemaphore ist vollständig lokalisiert in **English, Русский, Español, Deutsch, Français**, mit
**Live**-Umschaltung – ohne Neustart. Öffne **Einstellungen ▸ Sprache** und wähle eine aus dem Menü
(jede zeigt ihren eigenen Namen und ihre Flagge); die gesamte Oberfläche wird sofort neu gezeichnet.
Belasse es auf **System**, um den bevorzugten Sprachen von macOS zu folgen (mit Rückfall auf Englisch).

Diese README gibt es in denselben fünf Sprachen – siehe die Umschaltung oben.

## Datenschutz

Alles, was ccemaphore anzeigt, wird auf deinem Mac aus lokalen Dateien ermittelt – vor allem aus
`~/.claude` und `~/.codex`. Chat-Inhalte werden nirgends gespeichert und nirgendwohin gesendet.
`~/.claude` ist ein Punkt-Ordner (kein TCC-geschützter Ort), daher erscheint keine Zugriffsabfrage dafür.
Keine Telemetrie, keine Analytics.

Nur Folgendes geht ins Netz:

- **Update-Prüfung → GitHub.** Sofern du Updates nicht ausschaltest, fragt ccemaphore einmal täglich bei
  GitHub nach einer neuen Version und lädt sie von dort. GitHub sieht deine IP-Adresse, die App-Version
  (im User-Agent, z. B. `ccemaphore/1.3.0 Sparkle/2.10.0`) und deine bevorzugte Sprache (den
  `Accept-Language`-Header, den macOS hinzufügt). Jede Prüfung erhöht außerdem den öffentlichen
  Download-Zähler der `appcast.xml` des Releases – eine einzige Gesamtzahl, die jeder sehen kann und die
  nichts über dich verrät. Cookies werden nicht gespeichert, und es wird kein Systemprofil gesendet.
- **Du entscheidest.** Beim ersten Start fragt das Panel, wie aktualisiert werden soll – automatisch, nur
  benachrichtigen oder aus –, und vor deiner Antwort läuft keine automatische Prüfung. Ändern kannst du
  das jederzeit unter **Einstellungen ▸ Updates**; sind Updates aus, prüft ccemaphore nie von selbst
  (manuell prüfen geht weiterhin).
- **ccusage** (Token- und Kostenstatistik, nur wenn Node oder Bun installiert ist) läuft über
  `bunx`/`npx`, die das Paket aus der npm-Registry laden können; ccusage selbst kann aktuelle
  Modellpreise abrufen.
- **SSH-Remote-Hosts** (optional) – ccemaphore verbindet sich nur mit den Hosts, die du selbst
  hinzufügst, über dein eigenes `ssh`.

Sonst nichts – weder Chat-Inhalte noch irgendwelche Kennungen verlassen jemals deinen Mac. Nutzt du
eine ausgehende Firewall (Little Snitch, LuLu), rechne bei der ersten Update-Prüfung mit einer
einmaligen Abfrage für GitHub.

## Wie es funktioniert

ccemaphore ermittelt den Zustand jeder Sitzung aus lokalen Dateien und kombiniert dafür je Agent
mehrere Quellen.

### Claude Code — Sitzungsregister (primär, keine Einrichtung)

Claude Code ab 2.1.29x veröffentlicht für jede laufende Sitzung seinen eigenen Zustand in
`~/.claude/sessions/<pid>.json`: beschäftigt / inaktiv / wartet (und *worauf* – eine Berechtigungsabfrage
oder deine Antwort), den Namen der Sitzung, wo sie läuft (Desktop-App, IDE, Terminal) und ihren
Startordner. ccemaphore behandelt das als das genaueste Signal und legt es über die abgeleiteten Quellen
unten. Es ist die Aussage von Claude Code selbst, daher braucht es dafür keine Hooks.

### Modus A — Dateiüberwachung (immer an, keine Einrichtung)

Er überwacht `~/.claude/projects/**/*.jsonl` (die Transkripte, die Claude Code live schreibt) mit
FSEvents und klassifiziert jede Sitzung anhand des Endes ihrer Datei:

- **arbeitet** — die letzte echte Zeile ist aktuell und mitten im Zug (`tool_use` des Assistenten, ein
  nicht abgeschlossener Stream, ein gerade eingetroffenes `tool_result`, ein frischer Prompt oder ein
  erneuter Versuch nach `api_error`).
- **fertig** — der Zug wurde sauber beendet (`stop_reason: end_turn`).
- **wartet** — nach bestem Bemühen: ein abgekühltes, aber noch lebendes Ende, das mit einem ungepaarten
  `tool_use` schließt.

Subagenten-Transkripte werden in ihre übergeordnete Sitzung eingeklappt – ein laufender Subagent
markiert seinen Elternteil als „arbeitet“. Die Aktivität wird aus dem letzten echten `timestamp`
berechnet, **nicht** aus dem mtime der Datei, weil das Umschreiben von Metadaten (Titel, letzter Prompt)
das mtime lange nach dem Ruhen eines Chats anhebt.

### Modus B — Hooks (optional, ein Klick)

Aktiviere **„Präzise Statuserkennung“** in den Einstellungen, und ccemaphore installiert
Claude-Code-Hooks für:

- **Präzises `done` / `waiting`** — zuverlässiger als das Lesen des Transkript-Endes.
- **Das interaktive Freigabe-Band** (die oben gezeigte 3-Knopf-Aufforderung **Erlauben / Ablehnen /
  Alle im Chat**).
- **Vertrauenswürdige Befehle** — eine Liste von Befehlen, die du automatisch genehmigst, sodass für sie
  nie ein Band erscheint (Abgleich als Teilzeichenkette des Befehls).

Die Hook-Installation ist eine idempotente Zusammenführung in `~/.claude/settings.json` und vollständig
umkehrbar.

### Codex (ChatGPT-App) — Dateiüberwachung + optionale Hooks

Existiert `~/.codex`, beobachtet ccemaphore auch Codex: die Thread-Transkripte
(`~/.codex/sessions/**/rollout-*.jsonl` – `task_started` / `task_complete` / `turn_aborted` liefern
arbeitet / fertig), den Thread-Katalog (`state_5.sqlite`, nur lesend geöffnet – Titel, Ordner, Projekte,
Archivstatus) und die Schreibsperren pro Thread (gehalten, solange die ChatGPT-App den Thread offen hat).
Freigabeanfragen schreibt Codex nicht in seine Transkripte, daher kommt „braucht dich“ für Codex nur über
Hooks: **Präziser Status über Codex-Hooks** schreibt die Hooks von ccemaphore in `~/.codex/hooks.json`,
und der separate Schalter **Codex-Berechtigungsabfragen** macht aus einer Freigabeanfrage rotes Licht +
Band (vertrauenswürdige Befehle werden automatisch erlaubt). Codex führt nur Hooks aus, denen es
**vertraut**: Genehmige `hooks.json` nach der Installation einmal in der ChatGPT-App
(Codex-Einstellungen → Hooks) oder mit `/hooks` in der Codex-CLI – die Zeile in den Einstellungen zeigt
dir den Stand. Ein Thread, den die ChatGPT-App aus Claude Code *importiert* hat, behält sein
Claude-Badge; ein reiner Spiegel ohne Codex-Züge wird ausgeblendet, damit nichts doppelt erscheint.

## Installation

1. [**Lade die neueste `.dmg` herunter**](https://github.com/hakkazuu/ccemaphore/releases/latest) — sie
   ist signiert & notarisiert, daher öffnet Gatekeeper sie ohne Warnungen.
2. Öffne die DMG und ziehe **ccemaphore** in **Programme**.
3. Starte es. ccemaphore läuft als menüfreie Hintergrund-App (kein Dock-Symbol) – nur das schwebende
   Licht.

### Ersteinrichtung (optional, aber empfohlen)

- **Bedienungshilfen freigeben** (Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Bedienungshilfen:
  ccemaphore einschalten und, falls es nicht in der Liste steht, mit **+** hinzufügen – die App fragt nie
  selbst danach). Wird nur beim Sprung in einen Chat genutzt: um zu prüfen, dass das richtige
  Cursor-Fenster vorne ist, bevor der Chat-Tab geöffnet wird, und um ein bereits offenes VS-Code-Fenster
  mit Remote-SSH nach vorne zu holen, statt ein neues zu öffnen.
- **Wähle, wie ccemaphore sich aktualisiert** – das Panel fragt einmal: automatisch, nur benachrichtigen
  oder aus ([Details ↓](#updates)).
- **Aktiviere „Präzise Statuserkennung“** in den Einstellungen, um Modus B (Hooks + Freigabe-Band) zu
  aktivieren.
- **Nutzt du Codex in der ChatGPT-App?** Es wird automatisch erkannt. Für sofortiges „fertig“ / „braucht
  dich“ schalte **Präziser Status über Codex-Hooks** (und **Codex-Berechtigungsabfragen**) ein und
  genehmige die Hooks einmal in den Codex-Einstellungen der ChatGPT-App – die Zeile zeigt, sobald sie
  vertraut sind.
- **Beide Apps benachrichtigen dich auch selbst.** Reicht dir das Licht, schalte die Claude-App /
  ChatGPT-App unter Systemeinstellungen ▸ Mitteilungen oder in den Mitteilungseinstellungen der
  jeweiligen App stumm.
- **Für Token- und Kostenstatistiken** stelle sicher, dass Node oder Bun im `PATH` ist – ccemaphore ruft
  [`ccusage`](https://github.com/ryoppippi/ccusage) über `bunx`/`npx` auf. Der Verlauf funktioniert auch
  ohne; du siehst dann lediglich keine Token-Zahlen.
- **Wenn ein Klick auf einen Hinweis deine Schreibtische durcheinanderbringt** – das macht macOS, nicht
  ccemaphore: die Einstellung „Spaces automatisch anhand der letzten Verwendung ausrichten“
  (Systemeinstellungen ▸ Schreibtisch & Dock ▸ Mission Control). Schalte sie aus oder führe
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` aus – deine Spaces behalten
  ihre Reihenfolge, und der Sprung zum richtigen Fenster funktioniert weiterhin.

### Updates

ccemaphore hält sich mit [Sparkle](https://sparkle-project.org) selbst auf dem neuesten Stand:

- **Drei Modi** – einmal beim ersten Start gewählt und jederzeit unter **Einstellungen ▸ Updates**
  änderbar (dort siehst du auch deine Version und die letzte Prüfung):
  - **Automatisch** – prüft einmal täglich und lädt im Hintergrund; ist die neue Version bereit, setzt
    ein einziger Klick auf **Neu starten** sie ein und startet die App neu. Auch normales Beenden
    installiert sie. Kann dein Benutzerkonto die App an ihrem Ort nicht ersetzen (keine Schreibrechte,
    oder ein anderes Konto hat sie installiert), wartet das geladene Update stattdessen auf deinen Klick
    auf **Installieren** und ein Administratorpasswort – beim Beenden wird es dann nicht installiert.
  - **Nur melden** – prüft einmal täglich und sagt Bescheid; ein Klick auf **Aktualisieren** lädt,
    installiert und startet neu.
  - **Aus** – prüft nie von selbst; manuell prüfen geht weiterhin.
- **Signiert und geprüft.** Ein Update ist dieselbe signierte, notarisierte DMG wie auf der
  Release-Seite, und ccemaphore prüft ihre EdDSA-Signatur – und die des Update-Feeds –, bevor irgendetwas
  entpackt wird.
- **Alles im Panel**, in der Sprache der App. Außerhalb davon kannst du trotzdem das kleine
  Installer-Fenster von Sparkle mit dem Fortschritt sehen, falls eine Installation länger dauert; die
  Administrator-Passwortabfrage von macOS, nur wenn dein Benutzerkonto die App an ihrem Ort nicht
  ersetzen kann (ihr Text stammt von Sparkle, auf Englisch); und unter macOS 13 bis 14.3 beim ersten
  Start der aktualisierten App das Gatekeeper-Fenster „wird überprüft …“.
- **Nie mitten in einer Freigabe.** Solange am Licht eine Berechtigungsanfrage wartet, warten auch
  **Neu starten**, **Aktualisieren** und **Installieren** – so wird der Berechtigungs-Hook eines Agenten
  nie abgeschnitten.
- **Lass es in einem normalen Ordner.** Startest du ccemaphore direkt aus der DMG (oder von einem
  temporären Ort, an den macOS es verlegt – App Translocation genannt), kann es sich nicht aktualisieren:
  Das Panel bittet dich, es nach **Programme** zu verschieben.
- **Du kommst von 1.2.x oder älter?** Diese Versionen haben keinen Updater: Lade 1.3.0 herunter und ziehe
  sie einmal über die alte Kopie – danach aktualisiert sich ccemaphore selbst. 1.3.0 ist von einem neuen
  Entwicklerteam signiert, daher gilt eine Freigabe für Bedienungshilfen, die du einer älteren Version
  gegeben hast, nicht mehr – auch wenn Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Bedienungshilfen
  ccemaphore weiter als erlaubt anzeigen. Entferne es dort (**−**) und füge es wieder hinzu (**+**), oder
  schalte es aus und wieder ein.

## Mitwirken & aus dem Quellcode bauen

Erfordert **macOS 13+** und **Xcode 26**. Das Projekt ist ein eingechecktes Xcode-Projekt (kein
SwiftPM), daher funktioniert `swift build` nicht – öffne es in Xcode und drücke ⌘R (das schwebende Licht
erscheint, ohne Dock-Symbol):

```sh
open ccemaphore.xcodeproj
```

Um ein lokales (unsigniertes) `.app` für schnelle Tests zu erzeugen – ein Release-Build über `xcodebuild`,
abgelegt in `build/ccemaphore.app`:

```sh
Scripts/package_app.sh
```

Dieses `.app` läuft so, wie es gebaut wurde. Signiere es nicht ad hoc mit `--options runtime` neu: Die
Hardened Runtime würde dann das eingebettete Sparkle-Framework nicht laden, und die App würde beim Start
abstürzen.

Selbst gebaute Versionen (⌘R, `package_app.sh`) aktualisieren sich nie selbst – das tun nur mit
Developer ID signierte Releases. Die einzige Abhängigkeit, [Sparkle](https://sparkle-project.org), kommt
als Swift-Paket, fixiert auf 2.10.0; Xcode lädt es beim ersten Öffnen des Projekts.

App Sandbox ist **aus** (nötig, um `~/.claude` zu lesen), daher erfolgt die Verteilung außerhalb des
Mac App Store. Issues und Pull Requests sind willkommen. Signierte Releases erstellt der Maintainer über
GitHub Actions – siehe [`docs/RELEASING.md`](docs/RELEASING.md).

## Danksagungen

Dank an alle, die Funktionen zu ccemaphore beigetragen haben:

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — Überwachung entfernter
  Hosts per SSH und Berechtigungs-Relay ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)) sowie
  das horizontale Ampel-Layout und eine Korrektur, damit das schwebende Widget nicht mehr aus seiner
  Dock-Position ausbricht ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

Die In-App-Updates laufen mit [Sparkle](https://sparkle-project.org) (MIT-Lizenz). Seine Lizenz liegt
zusammen mit den Hinweisen zum enthaltenen Fremdcode in der App (zu öffnen unter
**Einstellungen ▸ Updates**) und in [`Resources/ThirdPartyNotices.txt`](Resources/ThirdPartyNotices.txt).

## Lizenz

MIT — siehe [LICENSE](LICENSE).
