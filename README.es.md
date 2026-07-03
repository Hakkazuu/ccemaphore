# ccemaphore

[English](README.md) · [Русский](README.ru.md) · **Español** · [Deutsch](README.de.md) · [Français](README.fr.md)

> Un semáforo flotante para tus sesiones de [Claude Code](https://claude.com/claude-code) en macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Abre varias ventanas de Cursor / VS Code, cada una con varios chats de Claude Code, y un único
indicador siempre visible te dice —de un vistazo, sin cambiar de ventana— si un agente está
trabajando, ha terminado o te necesita.

## ⬇️ Descargar

### **[Descargar la última versión (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Firmado y notarizado por Apple. Arrástralo a **Aplicaciones** y ábrelo — sin avisos de Gatekeeper.
Requiere **macOS 13 o posterior**. [Pasos de instalación completos ↓](#instalación)

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
  **ESPERANDO → TRABAJANDO → HECHO**: proyecto · rama de git · título del chat · % de contexto · el
  comando en ejecución. Desde aquí también tienes **Actualizar**, **Historial**, **Ajustes** y
  **Salir**.
- **Arrastra** el semáforo a donde quieras; **fíjalo** para bloquear su posición.
- **¿Un chat necesita permiso?** El semáforo se convierte en una **cinta** allí mismo — **Permitir una vez /
  Permitir todo en este chat / Denegar**, junto con el comando exacto — para que decidas sin abrir el
  chat.
- **¿Un chat ha terminado?** Aparece un aviso verde de «hecho» junto al semáforo; pulsa **Ir al chat**
  para saltar directamente a él (levanta la pestaña de Cursor correcta, o el terminal).
- **¿Compactando el contexto?** La lámpara amarilla muestra una pequeña insignia de compresión —
  ocupado, no bloqueado.

Todo ocurre *en el semáforo*: sin notificaciones del sistema de las que estar pendiente.

Las estadísticas de tokens y coste por sesión y una ventana de historial diario provienen de
[`ccusage`](https://github.com/ryoppippi/ccusage) cuando está disponible.

## Idiomas

ccemaphore viene totalmente localizado en **English, Русский, Español, Deutsch, Français**, con cambio
**en vivo** — sin reiniciar. Abre **Ajustes ▸ Idioma** y elige uno del menú (cada uno muestra su propio
nombre y bandera); toda la interfaz se vuelve a dibujar al instante. Déjalo en **Sistema** para seguir
los idiomas preferidos de macOS (con retroceso al inglés).

Este README está disponible en los mismos cinco idiomas — mira el selector arriba.

## Privacidad

ccemaphore **solo lee archivos locales** y **nunca envía nada fuera de tu equipo**. Sin telemetría. Lee
`~/.claude/projects` (transcripciones) solo para el estado — no analiza, almacena ni transmite el
contenido de los chats. `~/.claude` es una carpeta oculta (no una ubicación protegida por TCC), así que
no aparece ningún aviso de acceso para ella.

## Cómo funciona

ccemaphore tiene dos modos que cooperan.

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

Activa **«Detección precisa de estado»** en Ajustes y ccemaphore instala hooks de Claude Code para:

- **`done` / `waiting` precisos** — más fiable que leer el final de la transcripción.
- **La cinta de permisos interactiva** (el aviso de 3 botones Permitir / Permitir todo / Denegar de
  arriba).
- **Comandos de confianza** — una lista de comandos que autoapruebas, para que nunca aparezca la cinta
  con ellos (coincidencia como subcadena del comando).

La instalación de hooks es una fusión idempotente en `~/.claude/settings.json` y es totalmente
reversible.

## Instalación

1. [**Descarga el último `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — está firmado
   y notarizado, así que Gatekeeper lo abre sin advertencias.
2. Abre el DMG y arrastra **ccemaphore** a **Aplicaciones**.
3. Ábrelo. ccemaphore se ejecuta como una app de fondo sin menú (sin icono en el Dock) — solo el semáforo
   flotante.

### Configuración inicial (opcional pero recomendada)

- **Concede Accesibilidad** (Ajustes del Sistema ▸ Privacidad y seguridad ▸ Accesibilidad). Solo se usa
  para levantar la ventana/pestaña exacta de Cursor cuando pulsas **Ir al chat**, y para omitir un aviso
  del chat que ya estás mirando.
- **Activa «Detección precisa de estado»** en Ajustes para habilitar el Modo B (hooks + la cinta de
  permisos).
- **Para las estadísticas de tokens y coste**, asegúrate de tener Node o Bun en tu `PATH` — ccemaphore
  ejecuta [`ccusage`](https://github.com/ryoppippi/ccusage) vía `bunx`/`npx`. El historial funciona
  igualmente sin él; simplemente no verás las cifras de tokens.
- **Si al pulsar un aviso se reordenan tus escritorios** — es macOS, no ccemaphore: el ajuste
  «Reordenar Spaces automáticamente en función del uso más reciente» (Ajustes del Sistema ▸ Escritorio
  y Dock ▸ Mission Control). Desactívalo o ejecuta
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — tus Spaces mantendrán su
  orden y el salto a la ventana correcta seguirá funcionando.

## Contribuir y compilar desde el código fuente

Requiere **macOS 13+** y **Xcode 26**. El proyecto es un proyecto de Xcode versionado (no SwiftPM), así
que `swift build` no funcionará — ábrelo en Xcode:

```sh
open ccemaphore.xcodeproj   # luego ⌘R — semáforo flotante, sin icono en el Dock
```

Para armar un `.app` local (sin firmar) para pruebas rápidas:

```sh
Scripts/package_app.sh    # → build/ccemaphore.app  (compilación Release vía xcodebuild)
```

App Sandbox está **desactivado** (necesario para leer `~/.claude`), por lo que la distribución es fuera
de la Mac App Store. Los issues y pull requests son bienvenidos. Las versiones firmadas las publica el
responsable del proyecto mediante GitHub Actions — consulta [`docs/RELEASING.md`](docs/RELEASING.md).

## Licencia

MIT — consulta [LICENSE](LICENSE).
