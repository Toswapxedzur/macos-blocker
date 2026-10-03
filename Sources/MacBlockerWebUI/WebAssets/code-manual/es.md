# Manual de código de Mac Vault

[Manual de usuario](../manual/es.md)

## Contrato de las reglas

Código fuente: una expresión de función `(on, v) => { ... }`. Solo se admite JavaScript síncrono y la API indicada abajo; no hay temporizadores, red, APIs nativas del sistema ni acceso a páginas del navegador. Las reglas basadas en el tiempo usan `ev.now` y eventos. Las reglas de Safari usan el manual de código del navegador y se ejecutan en la propia aplicación contenedora de Safari Vault.

- La edición guarda un borrador; **Ejecutar** lo activa y activa el grupo. Los grupos congelados no pueden ejecutar. Un código fuente vacío descarga la regla.
- Una ejecución correcta sustituye los manejadores/paneles y borra el conjunto de bloqueos de aplicaciones de este grupo, conservando `v.state`. Un fallo de compilación/registro conserva la regla anterior; un tiempo de espera agotado puede detenerla. Reiniciar vuelve a registrar el último código activado; las variables de los cierres y los conjuntos de bloqueo de aplicaciones se restablecen.
- El registro puede inicializar el estado, registrar manejadores, mostrar paneles y escribir en el registro. Las acciones de aplicación/archivo y las emisiones deben estar en manejadores; su cola creada durante el registro se descarta.
- Desactivar suprime los manejadores y retira los paneles/bloqueos de aplicaciones. Activar reanuda la regla cargada y sus paneles/bloqueos retenidos. Eliminar quita sus manejadores/estado/efectos. Las aplicaciones cerradas previamente no se vuelven a abrir; las escrituras de archivos no se deshacen.
- Los eventos no están restringidos por los objetivos habituales del grupo; seleccione aplicaciones en la regla. Las acciones se encolan y se aplican después de distribuir el evento. Las excepciones detienen ese manejador sin revertir su estado/acciones; los manejadores posteriores pueden seguir ejecutándose. Solo las acciones de archivo tienen eventos de resultado.

## API

- `on(type, handler)` → booleano. Registra `handler(ev)`; varios manejadores se ejecutan en orden de registro. False significa argumentos inválidos o límite de manejadores alcanzado. `ev = { type: string, now: number, data }`; `now` son milisegundos Unix.
- `v.state`: objeto JSON mutable, persistido después de distribuir el evento. Inicialice los campos ausentes en lugar de sobrescribir el estado existente. Asignar un valor que no sea objeto o un array lo restablece a `{}`; las actualizaciones no serializables/demasiado grandes no se persisten.
- `v.log(...values)`: único productor del Registro de este grupo. Los registros/Borrar son independientes por grupo. Los errores de carga aparecen en el estado de ejecución; los diagnósticos de los manejadores no rellenan el Registro.
- `v.emit(type, data)`: encola una copia JSON de `data` para los manejadores de este grupo después del evento actual, con un `now` nuevo; no es una llamada síncrona.
- `v.panel(id, spec)`: sustituye el panel flotante con nombre de este grupo; un `spec` null lo elimina. Véase Paneles.
- `v.file(op, path, payload?)` → cadena con el ID de solicitud. Véase Archivos.
- `v.block(appId, on)`: true mantiene un bloqueo de aplicación, false quita el bloqueo de este grupo. Los bloqueos se combinan entre grupos activados; esta llamada no puede desbloquear el objetivo de otro grupo. Bloquear solicita un cierre normal y lo reintenta al intervalo de Ajustes; no impide iniciar procesos ni garantiza que una aplicación acepte cerrarse.
- `v.quit(appId)`: una solicitud de cierre normal, sujeta a la misma política de protección/reintento; sin bloqueo continuo.
- `v.open(appId)`: solicita a macOS abrir una aplicación instalada; sin callback de éxito.

Las demás llamadas devuelven `undefined`. Los IDs de aplicaciones son identificadores de paquete (por ejemplo, `com.valvesoftware.steam`), disponibles en los eventos. Block/Quit ignora `com.apple.*`, los navegadores, Vault y sus auxiliares, y los IDs vacíos. Los IDs de panel/estado pertenecen a un grupo, no a su nombre visible.

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

Por evento y grupo: 256 acciones en cola, 200 llamadas de registro, 64 emisiones; el exceso se descarta. Por regla: 1000 manejadores, 24 paneles; cada lista de controles tiene 32 entradas y cada selección 64 opciones; el exceso se ignora/trunca. Las cadenas de emisiones se detienen tras 16 generaciones. Límite de estado serializado: 65536 caracteres de cadena JavaScript. Mantenga el registro y los manejadores combinados de cada evento por debajo de 1 segundo; los excesos repetidos o un tiempo de espera estricto agotado detienen la regla hasta Ejecutar. El registro conserva 200 entradas por grupo. Los tiempos/respuestas son de mejor esfuerzo, sin garantías de tiempo real.

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
