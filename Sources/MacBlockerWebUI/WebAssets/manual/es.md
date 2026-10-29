# Manual de usuario de Mac Vault

Mac Vault tiene tres páginas: **Vault** bloquea apps nativas, **Content tagging** etiqueta contenido compatible del navegador y **Activity** muestra el uso registrado. La extensión del navegador recopila contenido compatible y aplica el bloqueo del navegador. Instálala y conéctala en el navegador que uses.

## Inicio rápido

1. En **Vault**, añade un grupo de bloqueo y un destino Apps; selecciona apps con el selector +.
2. Elige el comportamiento de bloqueo y activa el grupo.
3. En **Content tagging**, crea un grupo, elige sus plataformas y añade etiquetas con descripciones.
4. En Ajustes → ### AI connections

**AI connections**, elige ChatGPT subscription, OpenAI API, Gemini API o Grok API. Conecta la cuenta o introduce su clave y obtén los modelos; después elige conexión/modelo en el grupo. Activa el etiquetado y reanuda el grupo.
5. Abre contenido compatible en el navegador conectado. Añade un filtro de etiquetas a un grupo de bloqueo del navegador si quieres que las etiquetas controlen el bloqueo.

## Grupos de bloqueo

Un **blocking group** aplica una política de bloqueo. Un grupo de **Content tagging** asigna etiquetas y no bloquea por sí solo. Añade el grupo y un nombre, elige destinos en **Applies to**, define cuándo se bloquea y configura horario o límite de tiempo; después actívalo. Los cambios habituales se guardan automáticamente. Un error significa que el cambio no se aceptó; corrige el campo y vuelve a intentarlo. Desactivar detiene la política y conserva su configuración; **Delete group** la elimina. Arrastra los grupos para ordenarlos. Varios grupos pueden aplicarse al mismo destino; posponer uno no levanta el bloqueo de otro. **Export** copia una configuración; **Import** reemplaza la del grupo seleccionado tras confirmarlo.

### Límite de tiempo y horario

**Block immediately** bloquea cuando coinciden el grupo activo y su horario. **Block when the time allowance is used** permite el uso hasta agotar el límite. Define el límite en minutos y el intervalo de reinicio en horas. El límite móvil cuenta el uso de la ventana anterior. Elige días laborables y ventanas opcionales de hora local, una por línea, como **09:00-12:00**. Sin ventanas, se aplica durante todos los días seleccionados; divide los horarios nocturnos entre días.

### Snooze

Configura snooze para cada grupo. **Pause blocking** suspende la política durante la pausa; **Add to the time allowance** añade minutos utilizables a un grupo limitado por tiempo. Solo cuenta el tiempo adicional consumido; el no usado caduca al reinicio (o tras una ventana para un límite móvil, antes si se activa el reinicio de medianoche). **Activation delay**, **Cooldown** y **Required confirmations** definen demora, espera entre solicitudes y pasos de confirmación. ### Freeze y PIN

**Freeze** impide las ediciones habituales. Para descongelar hacen falta diez confirmaciones separadas por cinco segundos, la espera configurada y un PIN de seis dígitos. **Wait before unfreezing** admite 0–72 horas; 0 no añade espera. Mientras está congelado se puede alargar la espera y añadir un PIN, pero no reducir las condiciones; la eliminación también las respeta.

### Freeze y PIN

**Freeze** impide ediciones habituales. Para descongelar se necesitan diez confirmaciones separadas por cinco segundos, la espera configurada y un PIN de seis dígitos. **Wait before unfreezing** admite 0–72 horas; 0 no añade espera. Congelado, se puede alargar la espera y añadir PIN, pero no relajar las condiciones hasta descongelar. El borrado también respeta la espera restante y el PIN.

### Grupos vinculados

**Link** conecta grupos seleccionados expresamente de otros programas Vault. Comparten nombre, ajustes compatibles, destinos, uso y condiciones de congelación. Cada programa edita y aplica los tipos de destino que admite. **Unlink** separa los grupos y conserva su configuración. Si un miembro está desconectado, abre Mac Vault y el navegador vinculado para reconectar.

## Ayuda

Pulsa la pequeña **i** junto a un campo para ver la explicación; haz clic fuera o pulsa Escape para cerrarla. Las listas se muestran en cajas desplazables; la búsqueda filtra lo visible sin borrar entradas. Las reglas personalizadas tienen su propio [Manual de código](../code-manual/es.md), con editor, activación, registros, archivos y API.

## Apps nativas

Pulsa la pequeña **i** junto a un campo para ver su explicación; haz clic fuera o pulsa Escape para cerrarla. Las listas están en paneles desplazables; la búsqueda filtra lo visible sin borrar entradas. Consulta el [Manual de código](../code-manual/es.md) para reglas personalizadas, editor, activación, registros, archivos y API.

Usa el selector + de un destino Apps para escoger apps instaladas o en ejecución; vuelve a abrirlo para actualizar la lista tras iniciar una app desde otra carpeta. **Block every app except these** convierte la lista en permitidos. Mac Vault puede bloquear apps Apple normales y navegadores completos; Mac Vault y apps con el mismo bundle ID están protegidas. Se solicita salir a una app bloqueada; **Ask a blocked app to quit again every (minutes)** define los reintentos. Las redirecciones web, pausas de página y ocultación de feeds corresponden a la extensión.

## Content tagging

Un grupo Content tagging etiqueta contenido de sus plataformas asignadas con su árbol de tags y modelos. Cada plataforma pertenece a un grupo; elígelas al crearlo, pues no se cambian después. Los horarios y filtros de bloqueo no controlan el etiquetado. Actívalo en Ajustes y pausa/reanuda cada grupo por separado. Desactivar el registro de un feed en **Activity → Recording** también detiene su etiquetado.

### Tags y ajustes del modelo

Crea tags, describe su significado y define o quita sus padres. Arrastrar mueve la rama. **Minimum confidence** fija el grado de evidencia de 1 a 5; los grupos nuevos empiezan en 4 (apoyo sólido). No hay cantidad objetivo; un elemento puede no recibir tags. **Tagging instructions** guarda las preferencias. Los cambios se guardan automáticamente; cada grupo usa una conexión, modelo y esfuerzo de razonamiento elegidos expresamente.

### AI connections

En **AI connections** hay ChatGPT subscription, OpenAI API, Gemini API y Grok API. La suscripción usa el inicio de sesión de Vault y un plan válido; las claves API siguen la facturación y límites del proveedor. Elige proveedor e introduce la clave debajo del menú compartido; se guarda automáticamente y borrarla elimina la clave. **Fetch model list** obtiene modelos pero no selecciona uno. **Reasoning effort** ofrece predeterminado, Low, Medium o High según compatibilidad; nuevas opciones comienzan en Medium y se conservan las existentes. Más esfuerzo puede tardar y usar tokens. La búsqueda web siempre está habilitada para etiquetar; el modelo decide cuándo usarla. Si falla, se conservan resultados válidos en caché; nuevos elementos quedan pendientes hasta **Retry cloud classification**. No hay cambio automático de proveedor; cada conexión tiene intervalo y límite de intentos propios. En la extensión corrige con **+ tag**; usa el control de quitar o Delete una vez. **Untagged** significa terminado sin tags; **Tagging**, pendiente. Tu corrección prevalece.

## Activity

### Activity groups

Crea un grupo para mostrar sus apps y sitios seleccionados juntos en Usage. **Merge** usa un nombre y color para sus miembros en Activity. El grupo organiza el uso registrado y es distinto de los grupos de bloqueo y etiquetado. Guarda explícitamente el editor con **Save**.

### Recording and retention

En **Recording**, activa o desactiva cada categoría o fuente. **Keep** determina la retención; **Forever** no caduca automáticamente. Desactivar detiene registros nuevos; borrar historial elimina entradas. Los feeds de plataforma recogen contenido mostrado en páginas compatibles, aunque no se hayan abierto. Un feed **Tagging supported** puede suministrar contenido al etiquetado mientras se graba; su retención es independiente del uso de apps y sitios. Pausar un grupo de etiquetado no detiene por sí solo la grabación.


Crea un grupo para mostrar sus apps y sitios juntos en Usage. **Merge** les da nombre y color comunes en Activity. Es distinto de grupos de bloqueo/etiquetado. Guarda el editor con **Save**.


En **Recording**, activa o desactiva cada categoría/fuente. **Keep** determina la retención; **Forever** no caduca automáticamente. Desactivar detiene nuevos registros; borrar historial elimina entradas. Los feeds recogen contenido mostrado en páginas compatibles, se abran o no. **Tagging supported** puede alimentar Content tagging mientras se graba; la retención es independiente de uso de apps y sitios. Pausar el grupo no detiene la grabación.

## Settings

Elige el idioma en Ajustes; Info muestra explicaciones en ese idioma.

## Saving and troubleshooting

Los cambios habituales de Vault y etiquetado se guardan automáticamente; los grupos de Activity requieren **Save**. Añadir, borrar, probar conexiones y obtener modelos son acciones explícitas. Si faltan etiquetas, comprueba navegador, activación global, pausa, grabación de la plataforma, conexión/modelo y credenciales. Para fallos de IA, revisa límites del proveedor y registro del grupo. Reconecta los programas de un grupo vinculado o descongélalo según indique la app.
