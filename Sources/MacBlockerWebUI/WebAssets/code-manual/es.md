# Manual de código de Mac Vault

[Manual de usuario](../manual/es.md)

## Contrato de las reglas

Código fuente: una expresión de función `(on, v) => { ... }`. Solo se admite JavaScript síncrono y la API indicada abajo; no hay callbacks de programación temporal de JavaScript, red, APIs nativas del sistema ni acceso a páginas del navegador. Las reglas basadas en el tiempo usan los temporizadores/rastreadores administrados descritos abajo, o `ev.now` y eventos. Las reglas de Safari usan el manual de código del navegador y se ejecutan en la propia aplicación contenedora de Safari Vault.

- La edición guarda un borrador; **Ejecutar** lo activa y activa el grupo. Los grupos congelados no pueden ejecutar. Un código fuente vacío descarga la regla.
- Una ejecución correcta sustituye los manejadores/paneles y borra el conjunto de bloqueos de aplicaciones de este grupo, conservando `v.state`. Un fallo de compilación/registro conserva la regla anterior; un tiempo de espera agotado puede detenerla. Reiniciar vuelve a registrar el último código activado; las variables de los cierres y los conjuntos de bloqueo de aplicaciones se restablecen.
- El registro puede inicializar el estado, registrar manejadores, mostrar paneles y escribir en el registro. Las acciones de aplicación/archivo y las emisiones deben estar en manejadores; su cola creada durante el registro se descarta.
- Desactivar suprime los manejadores y retira los paneles/bloqueos de aplicaciones. Activar reanuda la regla cargada y sus paneles/bloqueos retenidos. Eliminar quita sus manejadores/estado/efectos. Las aplicaciones cerradas previamente no se vuelven a abrir; las escrituras de archivos no se deshacen.
- Los eventos no están restringidos por los objetivos habituales del grupo; seleccione aplicaciones en la regla. Las acciones se encolan y se aplican después de distribuir el evento. Las excepciones detienen ese manejador sin revertir su estado/acciones; los manejadores posteriores pueden seguir ejecutándose. Solo las acciones de archivo tienen eventos de resultado.

## Temporizadores administrados y uso en ventana móvil

`v.timer(id, {direction:"down", durationMs:300000})` crea o devuelve una cuenta atrás con nombre, inicialmente en pausa. Use `{direction:"up"}` para un temporizador de cuenta ascendente. El objeto ofrece `start()`, `pause()`, `resume()`, `reset()` y `snapshot()`. Iniciar/reanudar son idempotentes; restablecer lo deja en pausa con cero tiempo transcurrido. Los campos de la instantánea incluyen `ready`, `error`, `elapsedMs`, `remainingMs` (null para la cuenta ascendente), `running` y `completed`.

Los temporizadores en marcha avanzan según el tiempo real transcurrido mientras la aplicación/el navegador están cerrados o la regla está desactivada. Una cuenta atrás completada entrega `timerEnded` con `{id, direction, durationMs, generation, incarnation}` una vez por encarnación y generación del temporizador a cada miembro cuando su regla vuelve a ejecutarse; Ejecutar no lo repite. La entrega depende de los eventos del anfitrión; no es una alarma en tiempo real. Añada `{type:"timer", timerId:"focus", label:"Focus"}` a un panel para mostrarlo mediante el control de texto existente.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` crea o devuelve un rastreador con nombre del uso activo. `assign({websites:["youtube.com","reddit.com"], apps:[]})` sustituye las asignaciones de destinos de este miembro. Las reglas nativas pueden asignar en su lugar identificadores de aplicaciones de la plataforma. Los dominios incluyen los subdominios. Un rastreador agrupa sus destinos; otros identificadores tienen cuotas independientes. `snapshot()` devuelve `ready`, `error`, `usedMs`, `remainingMs`, `available` y `nextReturnAtMs` (el próximo milisegundo en que caduca cualquier uso registrado). `available(target?)` también comprueba la asignación si se proporciona un destino. `reset()` borra el historial de este objeto.

Todo uso observado que reúna los requisitos cuenta, incluido el que supera la cuota; el rastreador por sí solo no bloquea páginas ni aplicaciones. Los intervalos superpuestos de páginas visibles cuentan una vez, y las aplicaciones nativas cuentan el uso observado en primer plano. Las reglas desactivadas no añaden uso; el historial sigue caducando en los límites exactos de los intervalos. La disponibilidad solo se recupera cuando el historial restante está por debajo del límite. Las muestras periódicas se limitan a cinco segundos; los huecos por cierre o desactivación no generan actividad. Los eventos emitidos por el usuario no añaden uso.

Los mismos identificadores de objeto en grupos personalizados vinculados comparten una autoridad local en el concentrador nativo. La vinculación combina el historial y las asignaciones de los rastreadores y conserva el estado del temporizador iniciador; las configuraciones incompatibles impiden vincular. Cada miembro recibe su propio evento de finalización. La desconexión deja los rastreadores compartidos no disponibles y rechaza los controles de temporizador hasta que vuelven a estar disponibles los datos actuales de la autoridad. Al desvincular, cada miembro conserva el uso compartido final y el estado del temporizador, restaura sus propios destinos y descarta los comandos del vínculo anterior. El concentrador conserva la instantánea final hasta que el miembro que regresa la guarda y confirma; las transferencias pendientes terminan antes de que haya un nuevo vínculo disponible.

Los objetos con nombre se conservan al Ejecutar y reiniciar en el campo reservado `v.state.$vaultTime`; no edite ese campo directamente. Elimínelos explícitamente con `v.removeTime(id)`. Los identificadores tienen de 1 a 80 letras ASCII, dígitos, `_` o `-`; se rechazan los nombres de propiedad reservados. Hasta 32 objetos comparten el límite de estado de la regla de 64 KiB en UTF-8. Las duraciones son milisegundos enteros de hasta 365 días. El historial móvil se limita a 1024 bloques de un minuto y 2048 intervalos combinados. Los errores de capacidad del historial dejan el rastreador no disponible hasta que se restablece explícitamente; las configuraciones no válidas y los guardados demasiado grandes notifican errores sin borrar los datos guardados.

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → booleano. Registra `handler(ev)`; varios manejadores se ejecutan en orden de registro. False significa argumentos inválidos o límite de manejadores alcanzado. `ev = { type: string, now: number, data }`; `now` son milisegundos Unix.
- `v.state`: objeto JSON mutable, persistido después de distribuir el evento. Inicialice los campos ausentes en lugar de sobrescribir el estado existente. Asignar un valor que no sea objeto o un array lo restablece a `{}`; las actualizaciones no serializables/demasiado grandes no se persisten.
- `v.log(...values)`: añade entradas al Registro de este grupo. Los fallos de ejecución y entrega aparecen como entradas de error explícitas en el mismo registro. Los registros/Borrar son independientes por grupo. Los errores de carga también aparecen en el estado de ejecución; los eventos ejecutados parcialmente no se repiten automáticamente.
- `v.emit(type, data)`: encola una copia JSON de `data` para los manejadores de este grupo después del evento actual, con un `now` nuevo; no es una llamada síncrona.
- `v.panel(id, spec)`: sustituye el panel flotante con nombre de este grupo; un `spec` null lo elimina. Véase Paneles.
- `v.file(op, path, payload?)` → cadena con el ID de solicitud. Véase Archivos.
- `v.block(appId, on)`: true mantiene un bloqueo de aplicación, false quita el bloqueo de este grupo. Los bloqueos se combinan entre grupos activados; esta llamada no puede desbloquear el objetivo de otro grupo. Bloquear solicita un cierre normal y lo reintenta al intervalo de Ajustes; no impide iniciar procesos ni garantiza que una aplicación acepte cerrarse.
- `v.quit(appId)`: una solicitud de cierre normal, sujeta a la misma política de protección/reintento; sin bloqueo continuo.
- `v.open(appId)`: solicita a macOS abrir una aplicación instalada; sin callback de éxito.

Las demás llamadas devuelven `undefined`. Los IDs de aplicaciones son identificadores de paquete (por ejemplo, `com.valvesoftware.steam`), disponibles en los eventos. Block/Quit puede dirigirse a aplicaciones de Apple y navegadores completos. Ignora el identificador de paquete de Mac Vault y sus auxiliares, incluida cualquier otra aplicación que comparta esa identidad, y los IDs vacíos. Los IDs de panel/estado pertenecen a un grupo, no a su nombre visible.

## Eventos

La notación de datos siguiente describe tipos; no es código ejecutable. `?` marca campos opcionales.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
App = { appId: string, name: string }
```

- `tick` es aproximado; use marcas de tiempo, no recuentos de ticks. Running incluye procesos `.app` de primer plano, barra de menús y segundo plano con IDs de paquete; no todos los procesos Unix. Frontmost puede ser null o tener un ID de aplicación vacío.
- `app` informa de cambios de ciclo de vida observados antes del evento `tick` de ese tick. Solo focus incluye `previousAppId` (null si se desconoce). Los nombres son nombres visibles, no IDs estables.
- `snooze` significa que se pulsó el botón Posponer del grupo. Por sí mismo no aplica una pausa.
- Las respuestas de archivos se dirigen al grupo solicitante. Correlacione `requestId`, compruebe `ok` y establezca un plazo usando ticks: las respuestas pueden perderse si la regla se recarga/desactiva. Los IDs de solicitud pueden repetirse después de Ejecutar; las solicitudes pendientes no son trabajo duradero.

## Paneles

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Valores predeterminados: posición abajo a la derecha, anchura 300px; las opciones small/medium/large son 220/280/360px; la anchura numérica se limita a 180–520px y acepta cadenas en píxeles. Los paneles/secciones nativos apilan controles verticalmente; los campos de disposición, alineación, rol, autofocus y dimensiones de controles del navegador no afectan al renderizador nativo.

Los IDs se normalizan a letras/dígitos ASCII/`_`/`-` (máximo 80); elija IDs únicos y estables. Si se omite el ID del control, pasa a ser `control-N`; el tipo omitido/desconocido pasa a ser text. Los textos/listas omitidos están vacíos; disabled es false. Cada llamada sustituye toda la especificación. Un `value` explícito sobrescribe la entrada guardada; un valor omitido usa el último valor del evento y después normaliza el tipo. Los eventos nativos proporcionan cadenas: conviértalas al tipo de valor declarado antes de renderizar un panel actualizado. Los campos desconocidos se descartan; los colores/fuentes/CSS del panel pertenecen a Vault.

Campos y valores iniciales de los controles:

- `text`: cadena `text`; por defecto, etiqueta. `html`: cadena `html`, saneada y mostrada como texto sin formato en Mac.
- `button`: `label`, `action: "submit" | "cancel" | "close"` opcional. El valor del clic es la cadena de acción o vacío. Las acciones no envían/cierran nada automáticamente.
- `checkbox`, `toggle`: `value` booleano (false por defecto); el valor del evento es `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; valor de cadena (vacío por defecto). Los valores de opciones vacíos se eliminan; las etiquetas usan el valor por defecto. Actualice el valor tipado del panel después de seleccionar.
- `textInput`, `textarea`: valor de cadena (vacío por defecto); textInput `placeholder`; textarea `rows` 1–12 (3 por defecto). La textarea nativa ignora placeholder.
- `numberInput`, `range`: valor numérico (0 por defecto), `min`, `max`, `step` positivo. Los valores se limitan al actualizar el panel; los límites de normalización no especificados son −1000000…1000000. La numberInput nativa es entrada de texto: valide `Number(event.value)` usted mismo; min/max/step no limitan la escritura. La range nativa usa 0…100 con paso 1 por defecto.
- `date`, `time`: entrada de texto; formatos de valor inicial `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (los formatos iniciales inválidos quedan vacíos). Valide las ediciones usted mismo. `color`: `#RRGGBB` (`#000000` por defecto).
- `pin`: cadena de dígitos; `length` 3–12 (6 por defecto), `masked` true por defecto, `autoSubmit` false. `section`: `text`, `controls`; las secciones hijas de profundidad 3 no tienen hijos (controles raíz, profundidad 0).

Eventos de panel: las entradas normales envían `change`; los botones solo `click`; PIN envía `change` y también `submit` cuando autoSubmit lo completa. No hay eventos nativos mount/unmount/focus/key. Los valores son cadenas, incluidos números/booleanos. `values` contiene los valores de entrada de la instantánea renderizada y puede ir por detrás de la edición desencadenante; `value` identifica esa edición. Guárdelo en `v.state` y renderice valores tipados para formularios fiables. Los eventos que no son clics se agrupan dentro de 100ms por control; no cuente los eventos como pulsaciones de teclas.

Límites de texto: title/label 240; description/text 1000; HTML 20000; placeholder 500; texto de entrada 2000; otras cadenas de valor 512; valor/etiqueta de opción 256. El exceso se trunca.

## Archivos

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Requiere **Carpeta de reglas personalizadas** en Ajustes y su permiso.

- `path` es relativo; `/` separa directorios. Los segmentos permiten letras/dígitos ASCII, espacios y `_.,@()-`; no un punto inicial, `.`/`..`, una ruta absoluta o una URL. Sufijos de archivo: `.txt`, `.csv`, `.json` (sin distinguir mayúsculas). La ruta de list es un directorio; `""` lista la raíz elegida. Se rechazan las rutas que salen de la carpeta elegida, también mediante enlaces simbólicos.
- Read devuelve texto UTF-8. Write sustituye/crea; append crea/añade sin salto de línea automático. Las escrituras crean los directorios superiores. Los datos de cadena se escriben literalmente; otros datos JSON se serializan; null/omitido significa texto vacío. Analizar JSON/CSV es tarea de la regla. Tamaño máximo del archivo: 1048576 bytes UTF-8.
- List devuelve los subdirectorios visibles inmediatos y los archivos compatibles. Entradas: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension incluye el punto en los archivos. Exists devuelve un booleano para una ruta de archivo compatible.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Los campos de resultado sin usar son null; con éxito, error está vacío. Los fallos incluyen invalid-path, unsupported-file-type, carpeta no disponible, archivo ausente y file-too-large. Trate error como cadena, no como enum fijo y exhaustivo. No hay API de transacciones; serialice las operaciones de lectura-modificación-escritura por ruta.

## Límites

Por evento y grupo: 256 acciones en cola, 200 llamadas de registro, 64 emisiones; el exceso se descarta. Por regla: 1000 manejadores, 24 paneles; cada lista de controles tiene 32 entradas y cada selección 64 opciones; el exceso se ignora/trunca. Las cadenas de emisiones se detienen tras 16 generaciones. Límite de estado serializado: 65536 bytes UTF-8. Mantenga el registro de la regla y los manejadores combinados de cada evento por debajo de 1 segundo; los excesos repetidos o un tiempo de espera estricto agotado detienen la regla hasta Ejecutar. El registro conserva 200 entradas por grupo. Los tiempos/respuestas funcionan según el mejor esfuerzo, sin garantías de tiempo real.

## Regla completa

Steam se bloquea excepto durante una pausa de cinco minutos activada mediante Posponer o el botón de su panel:

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```

## Registros del grupo

`v.store(request)` inicia una operación asíncrona de registro JSON dentro de un handler. Los registros son privados del grupo, persisten tras Run y reinicio, y se eliminan con el grupo. Los grupos vinculados tienen registros separados. La regla elige claves, valores, versiones, invalidación de caché y prioridad de comentarios. Mac y navegador usan la misma API, pero cada app/navegador tiene su almacén.

| Solicitud | Resultado |
|---|---|
| `{op:"get", key}` | `record` o `null` |
| `{op:"put", key, value, version?, ifRevision?}` | `record` guardado |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | `entries` ordenadas y `next` |
| `{op:"clear", prefix?}` | recuento `deleted` |

Cada registro contiene `{value, revision, version, updatedAt}`. `revision` es opaca y cambia con una escritura real; `version` son metadatos del llamador. `list` devuelve encabezados sin valores; usa `get` para leer uno y `after: next` para la página siguiente. Sin `ifRevision`, put/delete son incondicionales; `null` exige que no exista la clave y una cadena de revisión exige coincidencia exacta. Un conflicto devuelve `ok:false`, `error:"store-conflict"` y el `record` actual. Así una respuesta automática tardía no sobrescribe comentarios del usuario. `v.context.revision` es un marcador opaco de configuración que la regla puede incluir en su versión; el framework no impone política de caché.

Límites: clave 1–2048 caracteres, versión ≤128, valor JSON ≤64KiB, profundidad ≤32, 10000 claves por grupo y documento total de16MiB. `list` devuelve como máximo100 encabezados y96KiB por página. Máximo32 solicitudes por grupo y128 inicios/segundo en total; la sobrecarga informa un `store-busy` por grupo y segundo y descarta las demás. Los errores de almacenamiento devuelven `ok:false`; un documento futuro o malformado se conserva y produce `store-unavailable`. No hay reintentos ni expulsión automáticos. Usa ticks para plazos.

## Llamadas de IA desde una regla activa

Cada grupo personalizado elige conexión/modelo y nivel de razonamiento en **AI calls**. Las reglas de Mac y navegador usan la misma API; las solicitudes del navegador requieren Mac Vault conectado y las credenciales del proveedor permanecen allí. Los grupos vinculados comparten la selección y un límite diario opcional. En blanco significa sin límite de grupo; siguen aplicándose los límites de la cuenta. El límite usa el día UTC, persiste tras reinicio y cuenta intentos enviados, incluidos fallos. Vincular combina el uso previo; desvincular conserva el uso anterior.

`v.ai({ prompt, input? })` devuelve un ID de solicitud inmediatamente. Llámala dentro de un handler, no al registrar la regla. `input` acepta cualquier JSON; cada prompt/input está limitado a20KB. Las respuestas llegan como eventos `ai`: `{requestId, ok, text, citations, error}`. Texto exitoso hasta48KB; citas `{url,title}`. Conserva enlaces de fuente visibles y clicables al mostrar respuestas de búsqueda web. La búsqueda siempre está disponible para el modelo. No hay plazo fijo de la app; la concurrencia es limitada; no hay alternativa de proveedor ni reintento automático. Las respuestas son datos, nunca JavaScript ejecutable; la regla decide qué acciones existentes tomar.

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ prompt: "Summarize this text.", input: data.values?.note ?? "" });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Las llamadas pendientes no se reproducen tras reiniciar. Run, desactivar/activar y eliminar descartan respuestas obsoletas; un navegador desconectado informa `ai-unavailable`. Otros errores: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Las llamadas fallidas no sustituyen un resultado anterior conservado por la regla. El estado mantiene el límite64KB.

Descubre opciones sin credenciales con `rule_ai_models` en Mac o `settings-rule-ai-models` en navegador; configura `ruleAI` mediante la ruta set-group existente. Campos: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) y `dailyRequestLimit` (null o1–100000). Usa una opción devuelta; no incluyas una clave o URL de proveedor en el código fuente.
