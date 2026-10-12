# ccemaphore

[English](README.md) · [Русский](README.ru.md) · [Español](README.es.md) · [Deutsch](README.de.md) · **Français**

> Un feu de circulation flottant pour vos sessions [Claude Code](https://claude.com/claude-code) et
> [Codex](https://chatgpt.com/codex) (app ChatGPT) sur macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Ouvrez côte à côte l'app de bureau Claude, plusieurs fenêtres Cursor / VS Code et Codex dans l'app
ChatGPT, chacune avec plusieurs conversations d'agents, et un seul indicateur toujours au premier plan
vous dit — d'un coup d'œil, sans changer de fenêtre — si un agent travaille, a terminé ou a besoin de
vous.

## ⬇️ Télécharger

### **[Télécharger la dernière version (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Signé et notarié par Apple. Glissez-le dans **Applications** et lancez-le — sans avertissement
Gatekeeper. Nécessite **macOS 13 ou ultérieur**. Une fois installé, il
[se met à jour tout seul](#mises-à-jour). [Étapes d'installation complètes ↓](#installation)

📄 **[Journal des modifications](CHANGELOG.md)** — les nouveautés de chaque version.

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
  **En attente → En cours → Terminé** : projet · branche git · titre de la conversation · % de contexte
  · la commande en cours. En bas du panneau : **Discussions**, **Historique**, **Réglages** et
  **Quitter** ; **↻** en haut actualise la liste.
- **Faites glisser** la lumière où vous voulez ; activez **Fixer la position** dans les Réglages pour
  la verrouiller.
- **Une conversation demande une autorisation ?** La lumière se transforme sur place en un **bandeau** —
  **Autoriser / Refuser / Tout dans le chat** (tout autoriser désormais dans cette conversation), avec la
  commande exacte — pour décider sans ouvrir la conversation.
- **Une conversation est terminée ?** Un avis vert « terminé » apparaît près de la lumière ; cliquez
  **Ouvrir le chat** pour y accéder directement (l'onglet Cursor adéquat, ou le terminal, est mis au
  premier plan).
- **Compactage du contexte en cours ?** La lampe jaune affiche un petit badge de compression — occupée,
  pas bloquée.
- **Deux agents, un feu.** Les fils Codex de l’app ChatGPT (ou de la CLI Codex) apparaissent à côté des
  discussions Claude Code ; chaque ligne porte un badge d’agent (Claude / Codex) et une icône d’hôte (app
  Claude, IDE, Terminal, app ChatGPT). **Ouvrir le chat** — ou un clic sur la ligne de la discussion dans
  le panneau — ouvre le bon endroit : l’onglet Cursor, la session de l’app Claude ou le fil Codex.
- **Sous-agents.** Une discussion qui a lancé des sous-agents (agents `Task` de Claude, workflows, fils
  enfants Codex) affiche un chevron : dépliez-le pour voir ce que fait chacun.
- **Regrouper par produit.** Backend, frontend et landing d’un même produit en parallèle ? Choisissez
  **Par produit** dans **Réglages ▸ Groupes de produit** : l’onglet Discussions regroupe alors les
  discussions par dossier de produit (`produit › sous-dépôt`) ; les projets de l’app ChatGPT et les
  dossiers à plusieurs dépôts sont proposés automatiquement.
- **Limites Codex.** Les fenêtres d’usage 5 h / semaine signalées par Codex, en bas de l’onglet
  Discussions.

Tout se passe *au niveau de la lumière*. Aucune notification système à courir après.

Les statistiques de tokens et de coût par session ainsi qu'une fenêtre d'historique quotidien
proviennent de [`ccusage`](https://github.com/ryoppippi/ccusage) lorsqu'il est disponible — pour Claude Code
comme pour Codex (ccusage ≥ 20), avec répartition et filtre Claude / Codex dans la fenêtre d'historique.

## Langues

ccemaphore est entièrement localisé en **English, Русский, Español, Deutsch, Français**, avec bascule
**en direct** — sans redémarrage. Ouvrez **Réglages ▸ Langue** et choisissez-en une dans le menu
(chacune affiche son propre nom et son drapeau) ; toute l'interface est redessinée instantanément.
Laissez sur **Système** pour suivre les langues préférées de macOS (avec repli sur l'anglais).

Ce README est disponible dans les mêmes cinq langues — voir le sélecteur en haut.

## Confidentialité

Tout ce qu'affiche ccemaphore est calculé sur votre Mac à partir de fichiers locaux — principalement
`~/.claude` et `~/.codex`. Le contenu des conversations n'est jamais stocké ni envoyé nulle part.
`~/.claude` est un dossier caché (pas un emplacement protégé par TCC), donc aucune demande d'accès
n'apparaît pour lui. Aucune télémétrie, aucune mesure d'audience.

Seuls ces éléments passent par le réseau :

- **Vérification des mises à jour → GitHub.** Sauf si vous désactivez les mises à jour, ccemaphore
  demande une fois par jour à GitHub s'il existe une nouvelle version, et la télécharge depuis GitHub.
  GitHub voit votre adresse IP, la version de l'app (dans le User-Agent, p. ex.
  `ccemaphore/1.3.0 Sparkle/2.10.0`) et votre langue préférée (l'en-tête `Accept-Language` qu'ajoute
  macOS). Chaque vérification incrémente aussi le compteur public de téléchargements du fichier
  `appcast.xml` de la version — un seul chiffre global, visible de tous, qui ne permet pas de vous
  identifier. Aucun cookie n'est conservé et aucun profil système n'est envoyé.
- **C'est vous qui décidez.** Au premier lancement, le panneau demande comment mettre à jour —
  automatiquement, me prévenir seulement ou ne pas vérifier — et aucune vérification automatique n'a lieu avant
  votre réponse. Modifiez ce choix à tout moment dans **Réglages ▸ Mises à jour** ; mises à jour
  désactivées, ccemaphore ne vérifie jamais de lui-même (la vérification manuelle reste possible).
- **ccusage** (statistiques de tokens et de coût, seulement si Node ou Bun est installé) s'exécute via
  `bunx`/`npx`, qui peuvent télécharger le paquet depuis le registre npm ; ccusage lui-même peut
  récupérer les tarifs actuels des modèles.
- **Hôtes distants via SSH** (facultatif) — ccemaphore ne se connecte qu'aux hôtes que vous ajoutez, avec
  votre propre `ssh`.

Rien d'autre : ni le contenu des conversations ni aucun identifiant ne quittent jamais votre Mac. Si
vous utilisez un pare-feu sortant (Little Snitch, LuLu), attendez-vous à une demande unique concernant
GitHub lors de la première vérification des mises à jour.

## Comment ça marche

ccemaphore déduit l'état de chaque session à partir de fichiers locaux, en combinant plusieurs sources
par agent.

### Claude Code — registre des sessions (source principale, sans configuration)

Claude Code 2.1.29x et suivants publie lui-même l'état de chaque session en cours dans
`~/.claude/sessions/<pid>.json` : occupée / inactive / en attente (et *de quoi* — une demande
d'autorisation ou votre réponse), le nom de la session, où elle tourne (app de bureau, IDE, terminal) et
son dossier de lancement. ccemaphore considère ce signal comme le plus précis et l'applique par-dessus
les sources déduites ci-dessous. C'est la parole de Claude Code lui-même : aucun hook n'est nécessaire.

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

Activez **« Détection précise du statut »** dans les Réglages et ccemaphore installe des hooks Claude
Code pour :

- **`done` / `waiting` précis** — plus fiable que la lecture de la fin de la transcription.
- **Le bandeau d'autorisation interactif** (l'invite à 3 boutons **Autoriser / Refuser / Tout dans le
  chat** ci-dessus).
- **Commandes de confiance** — une liste de commandes que vous approuvez automatiquement, afin qu'aucun
  bandeau n'apparaisse pour elles (correspondance en tant que sous-chaîne de la commande).

L'installation des hooks est une fusion idempotente dans `~/.claude/settings.json` et est entièrement
réversible.

### Codex (app ChatGPT) — surveillance de fichiers + hooks facultatifs

Si `~/.codex` existe, ccemaphore surveille aussi Codex : les transcriptions des fils
(`~/.codex/sessions/**/rollout-*.jsonl` — `task_started` / `task_complete` / `turn_aborted` donnent
en cours / terminé), le catalogue des fils (`state_5.sqlite`, ouvert en lecture seule — titres, dossiers,
projets, archivage) et les verrous d'écriture de chaque fil (tenus tant que l'app ChatGPT garde le fil
ouvert). Codex n'écrit pas ses demandes d'approbation dans ses transcriptions, donc « a besoin de vous »
pour Codex passe uniquement par les hooks : **Statut précis via les hooks Codex** écrit les hooks de
ccemaphore dans `~/.codex/hooks.json`, et l'interrupteur distinct **Demandes d’autorisation Codex**
transforme une demande d'approbation en feu rouge + bandeau (les commandes de confiance sont autorisées
automatiquement). Codex n'exécute que les hooks auxquels il **fait confiance** : après l'installation,
approuvez `hooks.json` une fois dans l'app ChatGPT (réglages Codex → Hooks) ou avec `/hooks` dans la CLI
Codex — la ligne des Réglages indique où vous en êtes. Un fil que l'app ChatGPT a *importé* depuis
Claude Code garde son badge Claude ; un simple miroir sans tours Codex est masqué pour ne rien lister
deux fois.

## Installation

1. [**Téléchargez le dernier `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — il est
   signé et notarié, donc Gatekeeper l'ouvre sans avertissement.
2. Ouvrez le DMG et glissez **ccemaphore** dans **Applications**.
3. Lancez-le. ccemaphore s'exécute comme une app d'arrière-plan sans menu (sans icône dans le Dock) —
   juste la lumière flottante.

### Configuration au premier lancement (facultative mais recommandée)

- **Accordez l'Accessibilité** (Réglages Système ▸ Confidentialité et sécurité ▸ Accessibilité :
  activez ccemaphore et, s'il n'est pas dans la liste, ajoutez-le avec **+** ; l'app ne la demande
  jamais d'elle-même). Elle ne sert que lorsque vous sautez vers une conversation : vérifier que la
  bonne fenêtre Cursor est au premier plan avant d'ouvrir l'onglet de la conversation, et ramener au
  premier plan une fenêtre VS Code Remote-SSH déjà ouverte au lieu d'en ouvrir une nouvelle.
- **Choisissez comment ccemaphore se met à jour** — le panneau le demande une fois : automatiquement,
  me prévenir seulement ou ne pas vérifier ([détails ↓](#mises-à-jour)).
- **Activez « Détection précise du statut »** dans les Réglages pour activer le Mode B (hooks + bandeau
  d'autorisation).
- **Vous utilisez Codex dans l'app ChatGPT ?** Il est détecté automatiquement. Pour voir « terminé » et
  « a besoin de vous » instantanément, activez **Statut précis via les hooks Codex** (et **Demandes
  d’autorisation Codex**), puis approuvez les hooks une fois dans les réglages Codex de l'app ChatGPT — la
  ligne indique quand ils sont approuvés.
- **Les deux apps vous notifient déjà elles-mêmes.** Si le feu vous suffit, coupez les notifications de
  l'app Claude / de l'app ChatGPT dans Réglages Système ▸ Notifications ou dans les réglages de
  notification de chaque app.
- **Pour les statistiques de tokens et de coût**, assurez-vous d'avoir Node ou Bun dans votre `PATH` —
  ccemaphore exécute [`ccusage`](https://github.com/ryoppippi/ccusage) via `bunx`/`npx`. L'historique
  fonctionne quand même sans lui ; vous ne verrez simplement pas les chiffres de tokens.
- **Si un clic sur un avis réorganise vos bureaux** — c'est macOS, pas ccemaphore : le réglage
  « Réarranger automatiquement les Spaces en fonction de votre utilisation la plus récente »
  (Réglages Système ▸ Bureau et Dock ▸ Mission Control). Désactivez-le ou exécutez
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — vos Spaces garderont leur
  ordre et le saut vers la bonne fenêtre continuera de fonctionner.

### Mises à jour

ccemaphore se tient à jour tout seul grâce à [Sparkle](https://sparkle-project.org) :

- **Trois modes**, choisis une fois au premier lancement et modifiables dans **Réglages ▸ Mises à jour**
  (qui affiche aussi votre version et la dernière vérification) :
  - **Automatique** — vérifie une fois par jour et télécharge en arrière-plan ; quand la nouvelle
    version est prête, un seul clic sur **Redémarrer** l'installe et relance l'app. Quitter normalement
    l'installe aussi. Si votre compte ne peut pas remplacer l'app là où elle se trouve (pas de droit
    d'écriture, ou un autre compte l'a installée), la mise à jour téléchargée attend plutôt votre clic
    sur **Installer** et un mot de passe administrateur ; quitter ne l'installe pas.
  - **Prévenir seulement** — vérifie une fois par jour et vous prévient ; un clic sur
    **Mettre à jour** télécharge, installe et relance.
  - **Désactivé** — ne vérifie jamais de lui-même ; la vérification manuelle reste possible.
- **Signé et vérifié.** Une mise à jour est le même DMG signé et notarié que sur la page des versions, et
  ccemaphore vérifie sa signature EdDSA — ainsi que celle du flux de mises à jour — avant de décompresser
  quoi que ce soit.
- **Tout dans le panneau**, dans la langue de l'app. En dehors, vous pouvez quand même voir la petite
  fenêtre de l'installateur de Sparkle avec la progression, si l'installation prend du temps ; la demande
  de mot de passe administrateur de macOS, seulement si votre compte ne peut pas remplacer l'app là où
  elle se trouve (son message vient de Sparkle, en anglais) ; et, sous macOS 13 à 14.3, la fenêtre
  « Vérification… » de Gatekeeper au premier lancement de l'app mise à jour.
- **Jamais au milieu d'une autorisation.** Tant qu'une demande d'autorisation attend au niveau du feu,
  **Redémarrer**, **Mettre à jour** et **Installer** attendent aussi : le hook d'autorisation d'un agent
  n'est jamais coupé.
- **Gardez-le dans un dossier normal.** Lancé directement depuis le DMG (ou depuis un emplacement
  temporaire où macOS le déplace, l'« App Translocation »), ccemaphore ne peut pas se mettre à jour : le
  panneau vous demande de le déplacer dans **Applications**.
- **Vous venez de la 1.2.x ou d'une version antérieure ?** Elles n'ont pas de mise à jour intégrée :
  téléchargez la 1.3.0 et glissez-la une fois par-dessus l'ancienne copie — ensuite, ccemaphore se met à
  jour tout seul. La 1.3.0 est signée par une nouvelle équipe de développement : l'autorisation
  d'Accessibilité accordée à une version antérieure ne s'applique plus, même si Réglages Système ▸
  Confidentialité et sécurité ▸ Accessibilité continue d'afficher ccemaphore comme autorisé.
  Retirez-le de la liste (**−**) puis ajoutez-le de nouveau (**+**), ou désactivez-le puis réactivez-le.

## Contribuer et compiler depuis les sources

Nécessite **macOS 13+** et **Xcode 26**. Le projet est un projet Xcode versionné (pas SwiftPM), donc
`swift build` ne fonctionnera pas — ouvrez-le dans Xcode et appuyez sur ⌘R (la lumière flottante apparaît,
sans icône dans le Dock) :

```sh
open ccemaphore.xcodeproj
```

Pour assembler un `.app` local (non signé) pour un test rapide — un build Release via `xcodebuild`, écrit
dans `build/ccemaphore.app` :

```sh
Scripts/package_app.sh
```

Ce `.app` fonctionne tel quel. Ne le re-signez pas ad hoc avec `--options runtime` : le Hardened Runtime
refuserait alors de charger le framework Sparkle intégré, et l'app planterait au lancement.

Les builds que vous faites vous-même (⌘R, `package_app.sh`) ne se mettent jamais à jour : seules les
versions signées Developer ID le font. L'unique dépendance, [Sparkle](https://sparkle-project.org),
arrive sous forme de paquet Swift épinglé à la 2.10.0 ; Xcode la télécharge à la première ouverture du
projet.

App Sandbox est **désactivé** (nécessaire pour lire `~/.claude`), la distribution se fait donc en dehors
du Mac App Store. Les issues et pull requests sont les bienvenus. Les versions signées sont publiées par
le mainteneur via GitHub Actions — voir [`docs/RELEASING.md`](docs/RELEASING.md).

## Remerciements

Merci à toutes les personnes qui ont contribué des fonctionnalités à ccemaphore :

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — surveillance d'hôtes
  distants via SSH et relais de permissions ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)),
  ainsi que la disposition horizontale du feu tricolore et un correctif empêchant le widget flottant
  de s'échapper de son emplacement près du Dock ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

Les mises à jour intégrées reposent sur [Sparkle](https://sparkle-project.org) (licence MIT). Sa
licence, accompagnée des mentions du code qu'il intègre, est fournie dans l'app (à ouvrir depuis
**Réglages ▸ Mises à jour**) et dans [`Resources/ThirdPartyNotices.txt`](Resources/ThirdPartyNotices.txt).

## Licence

MIT — voir [LICENSE](LICENSE).
