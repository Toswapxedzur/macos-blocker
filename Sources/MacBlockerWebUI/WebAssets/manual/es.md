# Manual de usuario de Mac Vault

Mac Vault tiene tres páginas: **Vault** bloquea apps nativas, **Etiquetado de contenido** etiqueta contenido compatible del navegador y **Actividad** muestra el uso registrado. La extensión del navegador recopila contenido compatible y aplica el bloqueo del navegador. Instálala y conéctala en el navegador que uses.

## Inicio rápido

1. En **Vault**, añade un grupo de bloqueo y un destino Apps; selecciona apps con el selector +.
2. Elige el comportamiento de bloqueo y activa el grupo.
3. En **Etiquetado de contenido**, crea un grupo, elige sus plataformas y añade etiquetas con descripciones.
4. En Ajustes → **Conexiones de IA**, elige ChatGPT subscription, OpenAI API, Gemini API o Grok API. Conecta la cuenta o introduce su clave y obtén los modelos; después elige conexión/modelo en el grupo. Activa el etiquetado y reanuda el grupo.
5. Abre contenido compatible en el navegador conectado. Añade un filtro de etiquetas a un grupo de bloqueo del navegador si quieres que las etiquetas controlen el bloqueo.

## Grupos de bloqueo

Un **grupo de bloqueo** aplica una política de bloqueo. Un grupo de **Etiquetado de contenido** asigna etiquetas y no bloquea por sí solo. Añade el grupo y un nombre, elige destinos en **Se aplica a**, define cuándo se bloquea y configura horario o límite de tiempo; después actívalo. Los cambios habituales se guardan automáticamente. Un error significa que el cambio no se aceptó; corrige el campo y vuelve a intentarlo. Desactivar detiene la política y conserva su configuración; **Borrar grupo** la elimina. Arrastra los grupos para ordenarlos. Varios grupos pueden aplicarse al mismo destino; posponer uno no levanta el bloqueo de otro. **Exportar** copia una configuración; **Importar** reemplaza la del grupo seleccionado tras confirmarlo.

### Límite de tiempo y horario

**Block immediately** bloquea cuando coinciden el grupo activo y su horario. **Block when the time allowance is used** permite el uso hasta agotar el límite. Define el límite en minutos y el intervalo de reinicio en horas. El límite móvil cuenta el uso de la ventana anterior. Elige días laborables y ventanas opcionales de hora local, una por línea, como **09:00-12:00**. Sin ventanas, se aplica durante todos los días seleccionados; divide los horarios nocturnos entre días.

### Pausa

Configura snooze para cada grupo. **Pause blocking** suspende la política durante la pausa; **Add to the time allowance** añade minutos utilizables a un grupo limitado por tiempo. Solo cuenta el tiempo adicional consumido; el no usado caduca al reinicio (o tras una ventana para un límite móvil, antes si se activa el reinicio de medianoche). **Activation delay**, **Cooldown** y **Required confirmations** definen demora, espera entre solicitudes y pasos de confirmación.

### Freeze y PIN

**Freeze** impide ediciones habituales. Para descongelar se necesitan diez confirmaciones separadas por cinco segundos, la espera configurada y un PIN de seis dígitos. **Wait before unfreezing** admite 0–72 horas; 0 no añade espera. Congelado, se puede alargar la espera y añadir PIN, pero no relajar las condiciones hasta descongelar. El borrado también respeta la espera restante y el PIN.

### Grupos vinculados

**Vincular** conecta grupos seleccionados expresamente de otros programas Vault. Comparten nombre, ajustes compatibles, destinos, uso y condiciones de congelación. Cada programa edita y aplica los tipos de destino que admite; las demás entradas de destino siguen disponibles para los programas vinculados. **Desvincular** separa los grupos y conserva su configuración. Si un miembro está desconectado, quizá no se pueda editar. Abre Mac Vault y el navegador vinculado para reconectar. La política guardada localmente puede seguir aplicándose mientras el miembro está sin conexión.

## Ayuda

Pulsa la pequeña **i** junto a un campo para ver la explicación; haz clic fuera o pulsa Escape para cerrarla. Las listas se muestran en cajas desplazables; la búsqueda filtra lo visible sin borrar entradas. Las reglas personalizadas tienen su propio [Manual de código](../code-manual/es.md), con editor, activación, registros, archivos y API.

## Apps nativas

Usa el selector + de un destino Apps para elegir apps instaladas o en ejecución. Vuelve a abrirlo para actualizar la lista después de iniciar una app desde otra carpeta. **Bloquear todas las apps excepto estas** convierte la lista en una lista de permitidas. Mac Vault puede bloquear apps Apple normales y navegadores completos; Mac Vault y cualquier app con el mismo bundle ID están protegidas. Se pide a una app bloqueada que se cierre; **Volver a pedir el cierre de una app bloqueada cada (minutos)** controla los reintentos. La extensión del navegador aplica redirecciones web, pausas de páginas y ocultación de feeds; no son acciones de apps nativas.

## Etiquetado de contenido

Un grupo Etiquetado de contenido etiqueta contenido de sus plataformas asignadas con su árbol de tags y modelos. Cada plataforma pertenece a un grupo; elígelas al crearlo, pues no se cambian después. Los horarios y filtros de bloqueo no controlan el etiquetado. Actívalo en Ajustes y pausa/reanuda cada grupo por separado. Desactivar el registro de un feed en **Actividad → Grabación** también detiene su etiquetado.

### Tags y ajustes del modelo

Crea tags, describe su significado y define o quita sus padres. Arrastrar mueve la rama. **Confianza mínima de la etiqueta** fija el grado de evidencia de 1 a 5; los grupos nuevos empiezan en 4 (apoyo sólido). No hay cantidad objetivo; un elemento puede no recibir tags. **Instrucciones de etiquetado** guarda las preferencias. Los cambios se guardan automáticamente; cada grupo usa una conexión, modelo y esfuerzo de razonamiento elegidos expresamente.

### Conexiones de IA

En **Conexiones de IA** hay ChatGPT subscription, OpenAI API, Gemini API y Grok API. La suscripción usa el inicio de sesión de Vault y un plan válido; las claves API siguen la facturación y límites del proveedor. Elige proveedor e introduce la clave debajo del menú compartido; se guarda automáticamente y borrarla elimina la clave. **Obtener lista de modelos** obtiene modelos pero no selecciona uno. **Nivel de razonamiento** ofrece predeterminado, Low, Medium o High según compatibilidad; nuevas opciones comienzan en Medium y se conservan las existentes. Más esfuerzo puede tardar y usar tokens. La búsqueda web siempre está habilitada para etiquetar; el modelo decide cuándo usarla. Si falla, se conservan resultados válidos en caché; nuevos elementos quedan pendientes hasta **Reintentar clasificación en la nube**. No hay cambio automático de proveedor; cada conexión tiene intervalo y límite de intentos propios. En la extensión corrige con **+ tag**; usa el control de quitar o Delete una vez. **Sin etiqueta** significa terminado sin tags; **Etiquetando**, pendiente. Tu corrección prevalece.

## Actividad

Actividad registra localmente el uso de apps habilitadas, visitas web y **Contenido visto** compatible. Los gráficos reflejan datos registrados; un área vacía no demuestra que el Mac estuviera inactivo. Elige un intervalo de fechas. **Cronología** muestra el uso por hora del día; **Totales** suma duración; **Intervalo de tiempo** agrupa el uso de cada intervalo en bloques verticales. **Colores** es una leyenda interactiva: selecciona una fuente para enfocar los gráficos. Elige un día para ver el uso desde esa fecha.

### Grupos de Actividad

Crea un grupo para mostrar juntas en Usage las apps y sitios seleccionados. **Merge** usa un nombre y color para sus miembros en todo Actividad. El grupo organiza el uso registrado y es distinto de los grupos de bloqueo y Etiquetado de contenido. Guarda el editor explícitamente con **Save**.

### Grabación y retención

En **Grabación**, activa o desactiva la grabación por categoría o fuente individual. **Conservar** determina cuánto se conserva el historial; **Siempre** evita el vencimiento automático. Las opciones individuales pueden seguir el ajuste general. Desactivar la grabación detiene nuevos registros; borrar el historial elimina las entradas registradas. Los feeds de plataforma recopilan contenido mostrado en páginas compatibles, se hayan abierto o no. Un feed **Etiquetado compatible** puede suministrar contenido a Etiquetado de contenido mientras la grabación esté activa. Su retención es independiente del uso de apps y sitios. Pausar un grupo de etiquetado no detiene por sí solo la grabación.

## Ajustes

Elige el idioma de interfaz en Ajustes. Los botones Info muestran explicaciones en el idioma seleccionado.

## Guardado y solución de problemas

Los cambios habituales de Vault y Etiquetado de contenido se guardan automáticamente. El editor de grupos Actividad requiere **Save**. Añadir, eliminar, probar conexiones y obtener modelos son acciones explícitas. Si faltan tags, comprueba la conexión del navegador, la activación global, la pausa del grupo, la grabación de la plataforma, la conexión/modelo seleccionados y las credenciales. Para solicitudes de IA fallidas, revisa también los límites del proveedor y el Log del grupo. Si no puedes editar un grupo vinculado, reconecta sus programas o descongélalo como se indica.
