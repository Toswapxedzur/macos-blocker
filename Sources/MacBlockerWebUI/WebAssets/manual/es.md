# Manual de usuario de Mac Vault

Mac Vault tiene tres páginas: **Vault** bloquea aplicaciones nativas, **Clasificador** etiqueta contenido compatible del navegador y **Actividad** muestra el uso registrado. La extensión recopila contenido compatible y aplica el bloqueo del navegador. Instálela y conéctela en el navegador que utiliza.

## Primeros pasos

1. En **Vault**, añada un grupo de bloqueo y un objetivo de aplicaciones; después seleccione aplicaciones con el selector +.
2. Elija el comportamiento de bloqueo del grupo y actívelo.
3. En **Clasificador**, cree un grupo, elija sus plataformas y añada etiquetas con descripciones.
4. Elija un nivel de modelo local y descárguelo si es necesario. Active el etiquetado en los ajustes del Clasificador y reanude el grupo.
5. Abra contenido compatible en el navegador conectado. Configure un filtro de etiquetas en un grupo de bloqueo del navegador si desea que las etiquetas controlen el bloqueo.

## Grupos de bloqueo

Un **grupo de bloqueo** aplica una política de bloqueo. Un **grupo del Clasificador** asigna etiquetas al contenido; por sí mismo no bloquea nada.

1. Añada un grupo de bloqueo y asígnele un nombre.
2. Elija objetivos en **Se aplica a**.
3. Elija cuándo se aplica el bloqueo y configure los horarios o el tiempo permitido necesarios.
4. Active el grupo. Sus objetivos comparten la política del grupo.

Los cambios habituales se guardan automáticamente. Un error significa que el cambio no se ha aceptado; corrija el campo e inténtelo de nuevo. Desactive un grupo para detener su política y conservar su configuración. **Eliminar grupo** lo elimina. Arrastre los grupos para reordenarlos. Varios grupos pueden aplicarse a un objetivo; posponer uno no levanta el bloqueo de otro.

**Exportar** copia la configuración de un grupo. **Importar** sustituye la configuración del grupo seleccionado tras la confirmación.

### Tiempo permitido y horario

**Bloquear inmediatamente** se aplica siempre que el grupo activado coincida y su horario esté activo. **Bloquear al agotar el tiempo permitido** permite el uso correspondiente hasta que se agota el tiempo disponible.

Configure el tiempo permitido en minutos y el intervalo de restablecimiento en horas. Un límite móvil cuenta el uso dentro de la ventana anterior. Restablecer a medianoche inicia un nuevo período a la medianoche local, también con un límite móvil.

Elija los días activos de la semana y, opcionalmente, intervalos de hora local, uno por línea, como **09:00-12:00**. Una lista de intervalos vacía se aplica durante todo el día en los días seleccionados. Un intervalo debe terminar después de empezar en el mismo día; divida un horario nocturno entre días separados.

### Posponer

Configure la opción de posponer en cada grupo de bloqueo. **Pausar bloqueo** suspende la política de ese grupo durante la duración de la pausa. **Añadir al tiempo permitido** añade minutos utilizables a un grupo con límite de tiempo. Solo el tiempo adicional consumido cuenta como tiempo pospuesto. El tiempo adicional sin usar caduca en el siguiente restablecimiento; con un límite móvil, después de una ventana, o antes a medianoche si esa opción está activada.

**Retraso de activación** retrasa la pausa mientras continúa el bloqueo. **Tiempo de espera** es la espera tras finalizar la pausa antes de otra solicitud. **Confirmaciones requeridas** establece el número de pasos de confirmación. Posponer está disponible en un grupo congelado solo si se permitió antes de congelarlo.

### Bloqueo de edición y PIN

**Bloquear edición** impide los cambios habituales. Desbloquear la edición requiere diez confirmaciones separadas por cinco segundos, además de la espera configurada y el PIN de seis dígitos, si existen. **Espera antes de desbloquear la edición** acepta 0–72 horas; 0 no añade espera.

Mientras el grupo está congelado, se puede ampliar la espera y añadir un PIN si no existe ninguno. Estas condiciones no se pueden debilitar hasta descongelar el grupo. La eliminación también respeta la espera restante y el PIN.

### Grupos vinculados

Use **Vincular** para conectar grupos seleccionados explícitamente en otros programas Vault. Los grupos vinculados comparten nombre, ajustes de política compatibles, objetivos, uso y condiciones de congelación. Cada programa edita y aplica los tipos de objetivo que admite; las demás entradas siguen disponibles para los programas vinculados. Al desvincular, cada grupo y sus ajustes se conservan.

Si un miembro vinculado está desconectado, la edición puede no estar disponible. Abra Mac Vault y el navegador vinculado para reconectarlos. Una política guardada localmente puede seguir aplicándose mientras un miembro está desconectado.

## Obtener ayuda

Pulse la pequeña **i** junto a un campo para ver su explicación. Pulse fuera o presione Escape para cerrarla. Las listas permanecen en cuadros desplazables; desplácese dentro del cuadro para acceder a más entradas. La búsqueda filtra la lista visible sin eliminar entradas.

Las reglas personalizadas tienen su propio [Manual de código](../code-manual/es.md). Explica el editor, la activación, los registros, el acceso a archivos y la API compatible.

## Aplicaciones nativas

Use el selector + de un objetivo de aplicaciones para seleccionar aplicaciones instaladas. **Bloquear todas las aplicaciones excepto estas** convierte la lista en una lista de permitidos. Las aplicaciones del sistema, los navegadores y el propio Vault se excluyen del bloqueo de aplicaciones nativas.

Se solicita a una aplicación bloqueada que se cierre. **Volver a pedir el cierre de una aplicación bloqueada cada (minutos)** controla los reintentos. La extensión del navegador aplica las redirecciones de sitios, las pausas de página y la ocultación de fuentes; estas no se convierten en acciones de aplicaciones nativas.

## Clasificador

Un grupo del Clasificador etiqueta contenido de sus plataformas asignadas con su propio árbol de etiquetas y ajustes de modelo. Cada plataforma pertenece a un grupo. Elija las plataformas al crear el grupo; no se pueden cambiar después. Los horarios y filtros de los grupos de bloqueo no controlan el etiquetado.

Active el etiquetado en los ajustes del Clasificador. Use **Pausar etiquetado / Reanudar etiquetado** de cada grupo por separado. Desactivar el registro de una fuente de plataforma en **Actividad → Registro** también detiene su etiquetado.

### Etiquetas y ajustes del modelo

Cree etiquetas, describa sus significados y establezca o elimine sus padres en el árbol de etiquetas. Arrastre una etiqueta para mover su rama. Las descripciones claras ayudan al modelo a distinguir etiquetas similares. Los ajustes de cada grupo son independientes.

- **Velocidad ↔ Calidad** selecciona un nivel de modelo local. Los modelos mayores usan más memoria; la velocidad y los resultados dependen de Mac y la carga de trabajo. Las descargas se comparten entre grupos.
- **Estricto ↔ Amplio** establece los requisitos de confianza y los recuentos de etiquetas predeterminados.
- **Mínimo de etiquetas / Máximo de etiquetas** en Más sustituyen esos recuentos predeterminados. Estricto ↔ Amplio sigue controlando la confianza para etiquetas adicionales. Deje cualquiera de los campos vacío para usar su valor predeterminado.
- **Instrucciones de etiquetado** añade instrucciones opcionales para este grupo.

Los cambios habituales del Clasificador se guardan automáticamente. Un nivel seleccionado debe estar descargado antes de poder etiquetar contenido. Los grupos que usan el mismo nivel comparten un modelo cargado; hasta dos niveles permanecen cargados a la vez.

Corrija las etiquetas de un elemento de contenido en la extensión del navegador. Pulse **+ etiqueta**, busque entre las etiquetas existentes del Clasificador y elija una para añadirla. Use el control de eliminación de una etiqueta o selecciónela y presione Supr una vez para quitarla. **Sin etiqueta** significa que el etiquetado terminó sin etiquetas; **Etiquetando** significa que hay un resultado pendiente. Las correcciones orientan futuros etiquetados.

## Conocimiento e investigación web

Conocimiento almacena descripciones breves en este Mac para el modelo local de etiquetado. **Fuentes de contenido** incluye creadores, cuentas, canales y comunidades. Las descripciones de las fuentes acompañan su contenido. **Términos conocidos** se aplica cuando un término aparece en un título.

Añada una fuente o término y su descripción, o deje la descripción vacía para solicitar investigación cuando esté activada. Las sugerencias de creadores ayudan a encontrar una fuente que el Clasificador haya recopilado. Las listas con seis o más entradas tienen una búsqueda justo encima: Términos y las Fuentes de contenido de cada plataforma tienen búsquedas separadas por nombre, identificador o descripción. Editar una descripción afecta a futuros etiquetados; eliminar el conocimiento de una fuente no impide que una investigación posterior lo vuelva a crear.

### Configurar un proveedor de investigación

1. Abra **Ajustes del Clasificador → Claves de API y proveedores**.
2. Elija un tipo de proveedor y **Añadir proveedor**. Esto crea una configuración; no emite una clave de API.
3. Obtenga las credenciales de ese proveedor e introdúzcalas. Para un punto de conexión personalizado compatible, configure también su dirección y campos de protocolo.
4. En **Investigación web**, elija un proveedor con búsqueda web integrada. Obtenga su lista de modelos y seleccione un modelo de investigación. Use la búsqueda del selector de modelos para reducir la lista; actualícela para obtenerla de nuevo.
5. Lea la información de consentimiento y actívelo. Elija **Activado**, **Desactivado** o **Seguir los ajustes del Clasificador** en cada grupo.

**Configurar investigación web…** le lleva a los ajustes cuando falta configuración. Un grupo no puede omitir el consentimiento de investigación. **Probar conexión** confirma que la solicitud de prueba se completó correctamente, no que todos los modelos admitan investigación. El modelo de prueba de un proveedor es independiente del modelo de investigación seleccionado.

Las claves se almacenan en la carpeta de soporte de la aplicación en este Mac, no en el llavero del sistema. Autentican solicitudes al proveedor configurado; Vault no las sube a su propio servidor. La investigación envía temas públicos saneados al proveedor seleccionado, no cuerpos de contenido privados ni resúmenes. Lea la información de consentimiento para conocer los campos exactos enviados. El uso del proveedor incluye pruebas de conexión y solicitudes de listas de modelos, además de investigación.

El estado de investigación muestra solicitudes en cola, esperas de reintento, fallos y el uso de tokens del día. **Reintentar ahora los temas fallidos** reintenta fallos aptos; no omite el tiempo permitido diario ni el consentimiento.

## Actividad

Actividad registra localmente el uso de aplicaciones habilitado, las visitas a sitios web y el **Contenido visto** compatible. Sus gráficos reflejan datos registrados; un área vacía no demuestra que Mac estuviera inactivo.

Elija un intervalo de fechas. **Línea de tiempo** muestra el uso a su hora del día; **Totales** suma la duración. **Intervalo de tiempo** combina el uso dentro de cada intervalo en bloques verticales. **Colores** es una leyenda interactiva: seleccione una fuente para centrar los gráficos en ella. Seleccione un día para ver el uso desde ese día.

### Grupos de actividad

Cree un grupo para mostrar juntas sus aplicaciones y sitios seleccionados en Uso. **Combinar** usa un solo nombre y color para sus miembros en toda Actividad. Un grupo de actividad organiza el uso registrado; es independiente de un grupo de bloqueo o del Clasificador. Guarde explícitamente el editor del grupo de actividad con **Guardar**.

### Registro y conservación

En **Registro**, active o desactive el registro de cada categoría o fuente individual. **Conservar** controla cuánto tiempo se conserva el historial; **Para siempre** lo mantiene sin caducidad automática. Las elecciones individuales pueden seguir el ajuste general. Desactivar el registro detiene los nuevos registros; eliminar el historial quita las entradas registradas.

Las fuentes de plataformas recopilan contenido mostrado en páginas compatibles, se abra o no. Una fuente con **Etiquetado compatible** puede abastecer al Clasificador mientras el registro está activado. Su conservación controla el contenido recopilado por separado del uso de aplicaciones y sitios web. Un grupo del Clasificador pausado no desactiva por sí mismo el registro.

## Ajustes del Clasificador

**Actualizaciones de paquetes de etiquetas** selecciona cuándo entran en vigor las actualizaciones verificadas: **Automático**, **Preguntar primero** o **Manual**. Es independiente de descargar el modelo local elegido en un grupo. Los archivos de modelos se descargan de Hugging Face al elegir **Descargar**; use el progreso/estado del grupo y los controles **Cancelar** durante una descarga.

Elija el idioma de la interfaz en Ajustes. Las explicaciones de los campos están disponibles mediante los pequeños botones de información en el idioma seleccionado.

## Guardado y solución de problemas

Los cambios habituales de Vault y del Clasificador se guardan automáticamente. La edición de grupos de actividad usa **Guardar**. Añadir, eliminar, descargar un modelo, probar una conexión y obtener una lista de modelos siguen siendo acciones explícitas.

Si faltan etiquetas, compruebe la conexión del navegador, el interruptor global de etiquetado, la pausa del grupo, el registro de la plataforma y la descarga del modelo. Si no se ejecuta la investigación, compruebe el consentimiento, la opción del grupo, las credenciales del proveedor, el modelo de investigación y el estado de investigación. Si no se puede editar un grupo vinculado, reconecte sus programas o desbloquee su edición según lo indicado.
