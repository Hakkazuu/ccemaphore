# ccemaphore

[English](README.md) · [Русский](README.ru.md) · [Español](README.es.md) · **Deutsch** · [Français](README.fr.md)

> Eine schwebende Ampel für deine [Claude-Code](https://claude.com/claude-code)-Sitzungen auf macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Öffne mehrere Cursor-/VS-Code-Fenster mit jeweils mehreren Claude-Code-Chats, und eine einzige,
stets sichtbare Anzeige sagt dir – auf einen Blick, ohne Fensterwechsel –, ob ein Agent arbeitet,
fertig ist oder dich braucht.

## ⬇️ Herunterladen

### **[Neueste Version herunterladen (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Von Apple signiert & notarisiert. Ziehe sie in **Programme** und starte sie – ohne Gatekeeper-Warnungen.
Erfordert **macOS 13 oder neuer**. [Vollständige Installationsschritte ↓](#installation)

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
  in **WARTET → ARBEITET → FERTIG**: Projekt · Git-Branch · Chat-Titel · Kontext-% · der laufende
  Befehl. Von hier aus gibt es außerdem **Aktualisieren**, **Verlauf**, **Einstellungen** und
  **Beenden**.
- **Ziehe** das Licht überallhin; **fixiere** es, um die Position zu sperren.
- **Ein Chat braucht eine Freigabe?** Das Licht verwandelt sich direkt an Ort und Stelle in ein **Band**
  – **Einmal erlauben / Alles in diesem Chat erlauben / Ablehnen**, samt genauem Befehl – damit du ohne
  den Chat zu öffnen entscheidest.
- **Ein Chat ist fertig?** Am Licht erscheint ein grüner „Fertig“-Hinweis; klicke **Zum Chat**, um
  direkt dorthin zu springen (es hebt den richtigen Cursor-Tab oder das Terminal hervor).
- **Kontext wird komprimiert?** Die gelbe Lampe zeigt ein kleines Komprimier-Symbol – beschäftigt,
  nicht hängengeblieben.

Alles passiert *am Licht*. Es gibt keine System-Benachrichtigungen, denen du hinterherlaufen musst.

Token- und Kostenstatistiken pro Sitzung sowie ein Tagesverlauf-Fenster stammen aus
[`ccusage`](https://github.com/ryoppippi/ccusage), sofern verfügbar.

## Sprachen

ccemaphore ist vollständig lokalisiert in **English, Русский, Español, Deutsch, Français**, mit
**Live**-Umschaltung – ohne Neustart. Öffne **Einstellungen ▸ Sprache** und wähle eine aus dem Menü
(jede zeigt ihren eigenen Namen und ihre Flagge); die gesamte Oberfläche wird sofort neu gezeichnet.
Belasse es auf **System**, um den bevorzugten Sprachen von macOS zu folgen (mit Rückfall auf Englisch).

Diese README gibt es in denselben fünf Sprachen – siehe die Umschaltung oben.

## Datenschutz

ccemaphore **liest nur lokale Dateien** und **sendet nie etwas von deinem Rechner**. Keine Telemetrie.
Es liest `~/.claude/projects` (Transkripte) nur für den Status – es analysiert, speichert oder überträgt
keine Chat-Inhalte. `~/.claude` ist ein Punkt-Ordner (kein TCC-geschützter Ort), daher erscheint keine
Zugriffsabfrage dafür.

## Wie es funktioniert

ccemaphore hat zwei zusammenarbeitende Modi.

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
- **Das interaktive Freigabe-Band** (die oben gezeigte 3-Knopf-Aufforderung Erlauben / Alles erlauben /
  Ablehnen).
- **Vertraute Befehle** — eine Liste von Befehlen, die du automatisch genehmigst, sodass für sie nie ein
  Band erscheint (Abgleich als Teilzeichenkette des Befehls).

Die Hook-Installation ist eine idempotente Zusammenführung in `~/.claude/settings.json` und vollständig
umkehrbar.

## Installation

1. [**Lade die neueste `.dmg` herunter**](https://github.com/hakkazuu/ccemaphore/releases/latest) — sie
   ist signiert & notarisiert, daher öffnet Gatekeeper sie ohne Warnungen.
2. Öffne die DMG und ziehe **ccemaphore** in **Programme**.
3. Starte es. ccemaphore läuft als menüfreie Hintergrund-App (kein Dock-Symbol) – nur das schwebende
   Licht.

### Ersteinrichtung (optional, aber empfohlen)

- **Bedienungshilfen freigeben** (Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Bedienungshilfen).
  Wird nur genutzt, um beim Klick auf **Zum Chat** das genaue Cursor-Fenster/-Tab hervorzuheben und um
  einen Hinweis für den Chat zu überspringen, den du ohnehin gerade ansiehst.
- **Aktiviere „Präzise Statuserkennung“** in den Einstellungen, um Modus B (Hooks + Freigabe-Band) zu
  aktivieren.
- **Für Token- und Kostenstatistiken** stelle sicher, dass Node oder Bun im `PATH` ist – ccemaphore ruft
  [`ccusage`](https://github.com/ryoppippi/ccusage) über `bunx`/`npx` auf. Der Verlauf funktioniert auch
  ohne; du siehst dann lediglich keine Token-Zahlen.
- **Wenn ein Klick auf einen Hinweis deine Schreibtische durcheinanderbringt** – das macht macOS, nicht
  ccemaphore: die Einstellung „Spaces automatisch anhand der letzten Verwendung ausrichten“
  (Systemeinstellungen ▸ Schreibtisch & Dock ▸ Mission Control). Schalte sie aus oder führe
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` aus – deine Spaces behalten
  ihre Reihenfolge, und der Sprung zum richtigen Fenster funktioniert weiterhin.

## Mitwirken & aus dem Quellcode bauen

Erfordert **macOS 13+** und **Xcode 26**. Das Projekt ist ein eingechecktes Xcode-Projekt (kein
SwiftPM), daher funktioniert `swift build` nicht – öffne es in Xcode:

```sh
open ccemaphore.xcodeproj   # dann ⌘R — schwebendes Licht, kein Dock-Symbol
```

Um ein lokales (unsigniertes) `.app` für schnelle Tests zu erzeugen:

```sh
Scripts/package_app.sh    # → build/ccemaphore.app  (Release-Build über xcodebuild)
```

App Sandbox ist **aus** (nötig, um `~/.claude` zu lesen), daher erfolgt die Verteilung außerhalb des
Mac App Store. Issues und Pull Requests sind willkommen. Signierte Releases erstellt der Maintainer über
GitHub Actions – siehe [`docs/RELEASING.md`](docs/RELEASING.md).

## Danksagungen

Dank an alle, die Funktionen zu ccemaphore beigetragen haben:

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — Überwachung entfernter
  Hosts per SSH und Berechtigungs-Relay ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)) sowie
  das horizontale Ampel-Layout und eine Korrektur, damit das schwebende Widget nicht mehr aus seiner
  Dock-Position ausbricht ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

## Lizenz

MIT — siehe [LICENSE](LICENSE).
