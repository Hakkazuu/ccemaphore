# ccemaphore

[English](README.md) · [Русский](README.ru.md) · [Español](README.es.md) · [Deutsch](README.de.md) · **Français**

> Un feu de circulation flottant pour vos sessions [Claude Code](https://claude.com/claude-code) sur macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Ouvrez plusieurs fenêtres Cursor / VS Code, chacune avec plusieurs conversations Claude Code, et un
seul indicateur toujours au premier plan vous dit — d'un coup d'œil, sans changer de fenêtre — si un
agent travaille, a terminé ou a besoin de vous.

## ⬇️ Télécharger

### **[Télécharger la dernière version (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Signé et notarié par Apple. Glissez-le dans **Applications** et lancez-le — sans avertissement
Gatekeeper. Nécessite **macOS 13 ou ultérieur**. [Étapes d'installation complètes ↓](#installation)

```
🟡  au moins une session travaille
🟢  aucune ne travaille — tout s'est terminé proprement
🔴  aucune ne travaille — au moins une vous attend
⚪  aucune session active
```

---

## Fonctionnalités

ccemaphore est une petite **lumière flottante** qui reste au-dessus de tout (y compris les espaces en
plein écran). Elle regroupe l'état de *toutes* vos conversations Claude Code, sur toutes les fenêtres,
en une seule couleur — pour que vous ne changiez jamais de fenêtre juste pour vérifier l'état.

- **Survolez la lumière** → un panneau se déploie avec chaque session active regroupée en
  **EN ATTENTE → EN COURS → TERMINÉ** : projet · branche git · titre de la conversation · % de contexte
  · la commande en cours. De là, vous avez aussi **Actualiser**, **Historique**, **Réglages** et
  **Quitter**.
- **Faites glisser** la lumière où vous voulez ; **épinglez-la** pour verrouiller sa position.
- **Une conversation demande une autorisation ?** La lumière se transforme sur place en un **bandeau** —
  **Autoriser une fois / Tout autoriser dans cette conversation / Refuser**, avec la commande exacte —
  pour décider sans ouvrir la conversation.
- **Une conversation est terminée ?** Un avis vert « terminé » apparaît près de la lumière ; cliquez
  **Aller à la conversation** pour y accéder directement (l'onglet Cursor adéquat, ou le terminal, est
  mis au premier plan).
- **Compactage du contexte en cours ?** La lampe jaune affiche un petit badge de compression — occupée,
  pas bloquée.

Tout se passe *au niveau de la lumière*. Aucune notification système à courir après.

Les statistiques de tokens et de coût par session ainsi qu'une fenêtre d'historique quotidien
proviennent de [`ccusage`](https://github.com/ryoppippi/ccusage) lorsqu'il est disponible.

## Langues

ccemaphore est entièrement localisé en **English, Русский, Español, Deutsch, Français**, avec bascule
**en direct** — sans redémarrage. Ouvrez **Réglages ▸ Langue** et choisissez-en une dans le menu
(chacune affiche son propre nom et son drapeau) ; toute l'interface est redessinée instantanément.
Laissez sur **Système** pour suivre les langues préférées de macOS (avec repli sur l'anglais).

Ce README est disponible dans les mêmes cinq langues — voir le sélecteur en haut.

## Confidentialité

ccemaphore **ne lit que des fichiers locaux** et **n'envoie jamais rien hors de votre machine**. Aucune
télémétrie. Il lit `~/.claude/projects` (transcriptions) uniquement pour l'état — il n'analyse, ne
stocke ni ne transmet le contenu des conversations. `~/.claude` est un dossier caché (pas un
emplacement protégé par TCC), donc aucune demande d'accès n'apparaît pour lui.

## Comment ça marche

ccemaphore a deux modes qui coopèrent.

### Mode A — surveillance de fichiers (toujours actif, sans configuration)

Il surveille `~/.claude/projects/**/*.jsonl` (les transcriptions que Claude Code écrit en direct) avec
FSEvents et classe chaque session d'après la fin de son fichier :

- **en cours** — la dernière ligne réelle est récente et en milieu de tour (`tool_use` de l'assistant,
  un flux non finalisé, un `tool_result` tout juste arrivé, un nouveau prompt ou une nouvelle tentative
  après `api_error`).
- **terminé** — le tour s'est terminé proprement (`stop_reason: end_turn`).
- **en attente** — au mieux : une fin refroidie mais encore vivante se terminant par un `tool_use` non
  apparié.

Les transcriptions des sous-agents sont repliées dans leur session parente — un sous-agent en cours
marque son parent comme « en cours ». L'activité est calculée à partir du dernier `timestamp` réel,
**et non** du mtime du fichier, car la réécriture des métadonnées (titres, dernier prompt) modifie le
mtime bien après qu'une conversation se soit tue.

### Mode B — hooks (optionnel, en un clic)

Activez **« Détection précise de l'état »** dans les Réglages et ccemaphore installe des hooks Claude
Code pour :

- **`done` / `waiting` précis** — plus fiable que la lecture de la fin de la transcription.
- **Le bandeau d'autorisation interactif** (l'invite à 3 boutons Autoriser / Tout autoriser / Refuser
  ci-dessus).
- **Commandes de confiance** — une liste de commandes que vous approuvez automatiquement, afin qu'aucun
  bandeau n'apparaisse pour elles (correspondance en tant que sous-chaîne de la commande).

L'installation des hooks est une fusion idempotente dans `~/.claude/settings.json` et est entièrement
réversible.

## Installation

1. [**Téléchargez le dernier `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — il est
   signé et notarié, donc Gatekeeper l'ouvre sans avertissement.
2. Ouvrez le DMG et glissez **ccemaphore** dans **Applications**.
3. Lancez-le. ccemaphore s'exécute comme une app d'arrière-plan sans menu (sans icône dans le Dock) —
   juste la lumière flottante.

### Configuration au premier lancement (facultative mais recommandée)

- **Accordez l'Accessibilité** (Réglages Système ▸ Confidentialité et sécurité ▸ Accessibilité). Elle
  sert uniquement à mettre au premier plan la fenêtre/l'onglet Cursor exact quand vous cliquez
  **Aller à la conversation**, et à ignorer un avis pour la conversation que vous regardez déjà.
- **Activez « Détection précise de l'état »** dans les Réglages pour activer le Mode B (hooks + bandeau
  d'autorisation).
- **Pour les statistiques de tokens et de coût**, assurez-vous d'avoir Node ou Bun dans votre `PATH` —
  ccemaphore exécute [`ccusage`](https://github.com/ryoppippi/ccusage) via `bunx`/`npx`. L'historique
  fonctionne quand même sans lui ; vous ne verrez simplement pas les chiffres de tokens.
- **Si un clic sur un avis réorganise vos bureaux** — c'est macOS, pas ccemaphore : le réglage
  « Réarranger automatiquement les Spaces en fonction de votre utilisation la plus récente »
  (Réglages Système ▸ Bureau et Dock ▸ Mission Control). Désactivez-le ou exécutez
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — vos Spaces garderont leur
  ordre et le saut vers la bonne fenêtre continuera de fonctionner.

## Contribuer et compiler depuis les sources

Nécessite **macOS 13+** et **Xcode 26**. Le projet est un projet Xcode versionné (pas SwiftPM), donc
`swift build` ne fonctionnera pas — ouvrez-le dans Xcode :

```sh
open ccemaphore.xcodeproj   # puis ⌘R — lumière flottante, sans icône dans le Dock
```

Pour assembler un `.app` local (non signé) pour un test rapide :

```sh
Scripts/package_app.sh    # → build/ccemaphore.app  (build Release via xcodebuild)
```

App Sandbox est **désactivé** (nécessaire pour lire `~/.claude`), la distribution se fait donc en dehors
du Mac App Store. Les issues et pull requests sont les bienvenus. Les versions signées sont publiées par
le mainteneur via GitHub Actions — voir [`docs/RELEASING.md`](docs/RELEASING.md).

## Licence

MIT — voir [LICENSE](LICENSE).
