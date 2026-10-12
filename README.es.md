# ccemaphore

[English](README.md) · [Русский](README.ru.md) · **Español** · [Deutsch](README.de.md) · [Français](README.fr.md)

> Un semáforo flotante para tus sesiones de [Claude Code](https://claude.com/claude-code) y
> [Codex](https://chatgpt.com/codex) (app de ChatGPT) en macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Abre a la vez la app de escritorio de Claude, varias ventanas de Cursor / VS Code y Codex en la app de
ChatGPT, cada una con varios chats de agentes, y un único indicador siempre visible te dice —de un
vistazo, sin cambiar de ventana— si un agente está trabajando, ha terminado o te necesita.

## ⬇️ Descargar

### **[Descargar la última versión (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Firmado y notarizado por Apple. Arrástralo a **Aplicaciones** y ábrelo — sin avisos de Gatekeeper.
Requiere **macOS 13 o posterior**. Una vez instalado, [se actualiza solo](#actualizaciones).
[Pasos de instalación completos ↓](#instalación)

📄 **[Registro de cambios](CHANGELOG.md)** — novedades de cada versión.

```
🟡  al menos una sesión está trabajando
🟢  ninguna trabajando — todo terminó correctamente
🔴  ninguna trabajando — al menos una te está esperando
⚪  no hay sesiones activas
```

---

## Características

ccemaphore es un pequeño **semáforo flotante** que se sitúa por encima de todo (incluidos los espacios a
pantalla completa). Agrupa el estado de *todos* tus chats de Claude Code, de todas las ventanas, en un
solo color — para que nunca cambies de ventana solo para comprobar el estado.

- **Pasa el cursor sobre el semáforo** → se despliega un panel con cada sesión activa agrupada en
  **En espera → Trabajando → Listo**: proyecto · rama de git · título del chat · % de contexto · el
  comando en ejecución. En la barra inferior tienes **Chats**, **Historial**, **Ajustes** y **Salir**;
  **↻** arriba actualiza la lista.
- **Arrastra** el semáforo a donde quieras; activa **Fijar posición** en Ajustes para bloquearlo ahí.
- **¿Un chat necesita permiso?** El semáforo se convierte en una **cinta** allí mismo — **Permitir /
  Denegar / Todo en el chat** (permitir todo en ese chat a partir de ahora), junto con el comando exacto —
  para que decidas sin abrir el chat.
- **¿Un chat ha terminado?** Aparece un aviso verde de «hecho» junto al semáforo; pulsa **Abrir chat**
  para saltar directamente a él (levanta la pestaña de Cursor correcta, o el terminal).
- **¿Compactando el contexto?** La lámpara amarilla muestra una pequeña insignia de compresión —
  ocupado, no bloqueado.
- **Dos agentes, un semáforo.** Los hilos de Codex de la app de ChatGPT (o de la CLI de Codex) aparecen
  junto a los chats de Claude Code; cada fila lleva una insignia de agente (Claude / Codex) y un icono de
  host (app de Claude, IDE, Terminal, app de ChatGPT). **Abrir chat** —o un clic en la fila del chat en
  el panel— abre el lugar correcto: una pestaña de Cursor, la sesión de la app de Claude o el hilo de
  Codex.
- **Subagentes.** Un chat que lanzó subagentes (agentes `Task` de Claude, workflows, hilos hijos de Codex)
  muestra un chevrón: despliégalo para ver qué hace cada uno.
- **Agrupar por producto.** ¿Trabajas a la vez en el backend, el frontend y la landing de un producto?
  Elige **Por producto** en **Ajustes ▸ Grupos de producto**: la pestaña Chats agrupa entonces los chats
  por carpeta de producto (`producto › subrepositorio`); los proyectos de la app de ChatGPT y las carpetas
  con varios repos se sugieren automáticamente.
- **Límites de Codex.** Las ventanas de uso de 5 horas / semana que informa Codex, al final de la pestaña
  Chats.

Todo ocurre *en el semáforo*: sin notificaciones del sistema de las que estar pendiente.

Las estadísticas de tokens y coste por sesión y una ventana de historial diario provienen de
[`ccusage`](https://github.com/ryoppippi/ccusage) cuando está disponible — tanto para Claude Code como para
Codex (ccusage ≥ 20), con desglose y filtro Claude / Codex en la ventana de historial.

## Idiomas

ccemaphore viene totalmente localizado en **English, Русский, Español, Deutsch, Français**, con cambio
**en vivo** — sin reiniciar. Abre **Ajustes ▸ Idioma** y elige uno del menú (cada uno muestra su propio
nombre y bandera); toda la interfaz se vuelve a dibujar al instante. Déjalo en **Sistema** para seguir
los idiomas preferidos de macOS (con retroceso al inglés).

Este README está disponible en los mismos cinco idiomas — mira el selector arriba.

## Privacidad

Todo lo que muestra ccemaphore se calcula en tu Mac a partir de archivos locales, sobre todo `~/.claude`
y `~/.codex`. El contenido de los chats nunca se guarda ni se envía a ningún sitio. `~/.claude` es una
carpeta oculta (no una ubicación protegida por TCC), así que no aparece ningún aviso de acceso para ella.
Sin telemetría ni analíticas.

Solo esto sale a la red:

- **Comprobación de actualizaciones → GitHub.** Salvo que desactives las actualizaciones, ccemaphore
  pregunta a GitHub una vez al día si hay una versión nueva y la descarga de allí. GitHub ve tu dirección
  IP, la versión de la app (en el User-Agent, p. ej. `ccemaphore/1.3.0 Sparkle/2.10.0`) y tu idioma
  preferido (la cabecera `Accept-Language` que añade macOS). Cada comprobación incrementa además el
  contador público de descargas del `appcast.xml` de la versión: un único número agregado que cualquiera
  puede ver y que no te identifica. No se guardan cookies ni se envía ningún perfil del sistema.
- **Tú decides.** En el primer inicio el panel pregunta cómo actualizar —automáticamente, solo avisar o
  desactivado— y no se hace ninguna comprobación automática hasta que respondas. Cámbialo cuando
  quieras en **Ajustes ▸ Actualizaciones**; con las actualizaciones desactivadas, ccemaphore nunca
  comprueba por su cuenta (puedes seguir comprobando a mano).
- **ccusage** (estadísticas de tokens y coste, solo si tienes Node o Bun) se ejecuta vía `bunx`/`npx`, que
  pueden descargar el paquete del registro de npm; el propio ccusage puede descargar los precios actuales
  de los modelos.
- **Hosts remotos por SSH** (opcional): ccemaphore solo se conecta a los hosts que tú añadas, con tu propio
  `ssh`.

Nada más: ni el contenido de los chats ni ningún identificador salen nunca de tu Mac. Si usas un
cortafuegos de salida (Little Snitch, LuLu), espera un único aviso sobre GitHub en la primera
comprobación de actualizaciones.

## Cómo funciona

ccemaphore deduce el estado de cada sesión a partir de archivos locales, combinando varias fuentes por
agente.

### Claude Code — registro de sesiones (principal, sin configuración)

Claude Code 2.1.29x y posteriores publica su propio estado para cada sesión en ejecución en
`~/.claude/sessions/<pid>.json`: ocupado / inactivo / esperando (con *qué* espera: una solicitud de
permiso o tu respuesta), el nombre de la sesión, dónde se ejecuta (app de escritorio, IDE, terminal) y su
carpeta de inicio. ccemaphore lo trata como la señal más precisa y la aplica sobre las fuentes deducidas
de abajo. Es la palabra del propio Claude Code, así que no necesita hooks.

### Modo A — vigilancia de archivos (siempre activo, sin configuración)

Vigila `~/.claude/projects/**/*.jsonl` (las transcripciones que Claude Code escribe en vivo) con
FSEvents y clasifica cada sesión por el final de su archivo:

- **trabajando** — la última línea real es reciente y está a mitad de turno (`tool_use` del asistente,
  un flujo sin finalizar, un `tool_result` recién llegado, un prompt nuevo o un reintento tras
  `api_error`).
- **hecho** — el turno terminó correctamente (`stop_reason: end_turn`).
- **esperando** — con el mejor esfuerzo: una cola enfriada pero aún viva que termina en un `tool_use`
  sin emparejar.

Las transcripciones de subagentes se pliegan en su sesión padre — un subagente en marcha marca a su
padre como «trabajando». La actividad se calcula a partir del último `timestamp` real, **no** del mtime
del archivo, porque reescribir metadatos (títulos, último prompt) mueve el mtime mucho después de que
un chat quede inactivo.

### Modo B — hooks (opcional, con un clic)

Activa **«Detección precisa del estado»** en Ajustes y ccemaphore instala hooks de Claude Code para:

- **`done` / `waiting` precisos** — más fiable que leer el final de la transcripción.
- **La cinta de permisos interactiva** (el aviso de 3 botones **Permitir / Denegar / Todo en el chat**
  de arriba).
- **Comandos de confianza** — una lista de comandos que autoapruebas, para que nunca aparezca la cinta
  con ellos (coincidencia como subcadena del comando).

La instalación de hooks es una fusión idempotente en `~/.claude/settings.json` y es totalmente
reversible.

### Codex (app de ChatGPT) — vigilancia de archivos + hooks opcionales

Si existe `~/.codex`, ccemaphore también vigila Codex: las transcripciones de los hilos
(`~/.codex/sessions/**/rollout-*.jsonl` — `task_started` / `task_complete` / `turn_aborted` dan
trabajando / hecho), el catálogo de hilos (`state_5.sqlite`, abierto en solo lectura: títulos, carpetas,
proyectos, estado de archivo) y los bloqueos de escritura de cada hilo (los mantiene la app de ChatGPT
mientras el hilo está abierto). Codex no escribe las solicitudes de aprobación en sus transcripciones, así
que el «te necesita» de Codex solo llega con hooks: **Estado preciso mediante hooks de Codex** escribe los
hooks de ccemaphore en `~/.codex/hooks.json`, y el interruptor aparte **Solicitudes de permiso de Codex**
convierte una solicitud de aprobación en luz roja + cinta (los comandos de confianza se aprueban solos).
Codex solo ejecuta hooks en los que **confía**: tras instalarlos, aprueba `hooks.json` una vez en la app
de ChatGPT (ajustes de Codex → Hooks) o con `/hooks` en la CLI de Codex; la fila de Ajustes te indica en
qué punto está. Un hilo que la app de ChatGPT *importó* de Claude Code conserva su insignia de Claude; un
espejo puro sin turnos de Codex se oculta para no listar nada dos veces.

## Instalación

1. [**Descarga el último `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — está firmado
   y notarizado, así que Gatekeeper lo abre sin advertencias.
2. Abre el DMG y arrastra **ccemaphore** a **Aplicaciones**.
3. Ábrelo. ccemaphore se ejecuta como una app de fondo sin menú (sin icono en el Dock) — solo el semáforo
   flotante.

### Configuración inicial (opcional pero recomendada)

- **Concede Accesibilidad** (Ajustes del Sistema ▸ Privacidad y seguridad ▸ Accesibilidad: activa
  ccemaphore y, si no aparece en la lista, añádelo con **+**; la app nunca pide este permiso por su
  cuenta). Solo se usa al saltar a un chat: para comprobar que la ventana de Cursor correcta está delante
  antes de abrir la pestaña del chat, y para levantar una ventana de VS Code Remote-SSH ya abierta en
  lugar de abrir otra.
- **Elige cómo se actualiza ccemaphore**: el panel lo pregunta una vez —automáticamente, solo avisar o
  desactivado— ([detalles ↓](#actualizaciones)).
- **Activa «Detección precisa del estado»** en Ajustes para habilitar el Modo B (hooks + la cinta de
  permisos).
- **¿Usas Codex en la app de ChatGPT?** Se detecta automáticamente. Para ver «hecho» y «te necesita» al
  instante, activa **Estado preciso mediante hooks de Codex** (y **Solicitudes de permiso de Codex**) y
  aprueba los hooks una vez en los ajustes de Codex de la app de ChatGPT; la fila muestra cuándo son de
  confianza.
- **Ambas apps ya te avisan por su cuenta.** Si te basta con el semáforo, silencia la app de Claude / la
  app de ChatGPT en Ajustes del Sistema ▸ Notificaciones o en los ajustes de notificaciones de cada app.
- **Para las estadísticas de tokens y coste**, asegúrate de tener Node o Bun en tu `PATH` — ccemaphore
  ejecuta [`ccusage`](https://github.com/ryoppippi/ccusage) vía `bunx`/`npx`. El historial funciona
  igualmente sin él; simplemente no verás las cifras de tokens.
- **Si al pulsar un aviso se reordenan tus escritorios** — es macOS, no ccemaphore: el ajuste
  «Reordenar Spaces automáticamente en función del uso más reciente» (Ajustes del Sistema ▸ Escritorio
  y Dock ▸ Mission Control). Desactívalo o ejecuta
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — tus Spaces mantendrán su
  orden y el salto a la ventana correcta seguirá funcionando.

### Actualizaciones

ccemaphore se mantiene al día solo, con [Sparkle](https://sparkle-project.org):

- **Tres modos**, que eliges una vez en el primer inicio y puedes cambiar en **Ajustes ▸ Actualizaciones**
  (donde también ves tu versión y la última comprobación):
  - **Automático**: comprueba una vez al día y descarga en segundo plano; cuando la nueva versión
    está lista, un solo clic en **Reiniciar** la instala y vuelve a abrir la app. Salir de la app de forma
    normal también la instala. Si tu cuenta no puede reemplazar la app donde está (sin permiso de
    escritura, o la instaló otra cuenta), la actualización descargada espera en su lugar a que pulses
    **Instalar** y a una contraseña de administrador; al salir no se instala.
  - **Solo avisar**: comprueba una vez al día y te avisa; un clic en **Actualizar** la descarga, la
    instala y reinicia la app.
  - **Desactivado**: nunca comprueba por su cuenta; puedes seguir comprobando a mano.
- **Firmado y verificado.** Una actualización es el mismo DMG firmado y notarizado que hay en la página de
  versiones, y ccemaphore comprueba su firma EdDSA —y la del feed de actualizaciones— antes de
  desempaquetar nada.
- **Todo en el panel**, en el idioma de la app. Fuera de él aún puedes ver la pequeña ventana del
  instalador de Sparkle con el progreso, si la instalación tarda; la solicitud de contraseña de
  administrador de macOS, solo si tu cuenta no puede reemplazar la app donde está (su mensaje viene de
  Sparkle, en inglés); y, en macOS 13 a 14.3, la ventana «Verificando…» de Gatekeeper la primera vez que
  se abre la app actualizada.
- **Nunca en mitad de un permiso.** Mientras una solicitud de permiso espera en el semáforo, **Reiniciar**,
  **Actualizar** e **Instalar** también esperan, así que el hook de permisos de un agente nunca se corta.
- **Tenlo en una carpeta normal.** Si lo abres directamente desde el DMG (o desde una ubicación temporal a
  la que macOS lo traslada, la llamada App Translocation), ccemaphore no puede actualizarse: el panel te
  pide moverlo a **Aplicaciones**.
- **¿Vienes de la 1.2.x o anterior?** Esas versiones no tienen actualizador: descarga la 1.3.0 y
  arrástrala sobre la copia antigua una vez; a partir de ahí ccemaphore se actualiza solo. La 1.3.0 está
  firmada por un nuevo equipo de desarrollo, así que el permiso de Accesibilidad que diste a una versión
  anterior deja de valer, aunque Ajustes del Sistema ▸ Privacidad y seguridad ▸ Accesibilidad siga
  mostrando ccemaphore como permitido. Quítalo ahí (**−**) y vuelve a añadirlo (**+**), o desactívalo y
  actívalo de nuevo.

## Contribuir y compilar desde el código fuente

Requiere **macOS 13+** y **Xcode 26**. El proyecto es un proyecto de Xcode versionado (no SwiftPM), así
que `swift build` no funcionará — ábrelo en Xcode y pulsa ⌘R (aparece el semáforo flotante, sin icono en
el Dock):

```sh
open ccemaphore.xcodeproj
```

Para armar un `.app` local (sin firmar) para pruebas rápidas — una compilación Release vía `xcodebuild`, en
`build/ccemaphore.app`:

```sh
Scripts/package_app.sh
```

Ese `.app` funciona tal cual. No lo vuelvas a firmar ad hoc con `--options runtime`: Hardened Runtime se
negaría entonces a cargar el framework Sparkle incluido y la app fallaría al abrirse.

Las compilaciones que haces tú (⌘R, `package_app.sh`) nunca se actualizan solas: solo lo hacen las
versiones firmadas con Developer ID. La única dependencia, [Sparkle](https://sparkle-project.org), llega
como paquete de Swift fijado a la 2.10.0; Xcode la descarga la primera vez que abres el proyecto.

App Sandbox está **desactivado** (necesario para leer `~/.claude`), por lo que la distribución es fuera
de la Mac App Store. Los issues y pull requests son bienvenidos. Las versiones firmadas las publica el
responsable del proyecto mediante GitHub Actions — consulta [`docs/RELEASING.md`](docs/RELEASING.md).

## Créditos

Gracias a todos los que contribuyeron con funcionalidades a ccemaphore:

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — monitorización de hosts
  remotos por SSH y relé de permisos ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)), además de
  la disposición horizontal del semáforo y una corrección para el widget flotante que se salía de su
  posición junto al Dock ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

Las actualizaciones dentro de la app funcionan con [Sparkle](https://sparkle-project.org) (licencia MIT).
Su licencia, junto con los avisos del código que incluye, va dentro de la app (se abre desde
**Ajustes ▸ Actualizaciones**) y en [`Resources/ThirdPartyNotices.txt`](Resources/ThirdPartyNotices.txt).

## Licencia

MIT — consulta [LICENSE](LICENSE).
