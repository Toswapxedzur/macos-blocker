# Referencia funcional de la aplicación de escritorio Vault

## Propósito y límite

Esta es la referencia autorizada para la interfaz de la aplicación de escritorio Vault. Está intencionalmente separado del manual de extensión del navegador Vault.

La aplicación de escritorio administra **aplicaciones nativas y ventanas de aplicaciones**. La extensión del navegador administra sitios web, pestañas del navegador y feeds de plataformas web compatibles. Comparten las mismas ideas (grupos, horarios, temporizadores, congelaciones, posposiciones, reglas personalizadas y el puente opcional) pero no tienen la misma superficie de aplicación.

Utilice este documento para configurar, auditar, reproducir o mantener el comportamiento de la aplicación de escritorio. El código es canónico si una implementación y este manual difieren.

## 1. Qué puede y qué no puede controlar la aplicación de escritorio

Vault evalúa la política de enfoque para aplicaciones nativas seleccionadas. Cuando su capacidad de aplicación nativa está disponible, puede aplicar el plan actual para coincidir con los objetivos de la aplicación e informar un resultado de escudo/estado a la interfaz de usuario del host.

Puede:

- crear, habilitar, deshabilitar, reordenar, importar, exportar, congelar, posponer y eliminar grupos;
- apuntar a aplicaciones nativas seleccionadas a través del selector de aplicaciones;
- aplicar un bloqueo inmediato, una concesión cronometrada o un cronómetro de cuenta atrás únicamente;
- restringir los grupos normales a los días laborables y a las franjas horarias locales;
- ejecutar reglas de política de JavaScript personalizadas para eventos del ciclo de vida de la aplicación;
- mostrar información del panel/estado nativo creado por reglas a través del host;
- administrar una carpeta local opcional para solicitudes de archivos de reglas personalizadas admitidas;
- Únase a grupos compatibles vinculados explícitamente a través del puente Vault local.

No puede:

- actuar como una extensión del navegador, inspeccionar el DOM de un sitio web o manipular las tarjetas de alimentación del navegador;
- garantizar que un sistema operativo permitirá controlar cada aplicación, proceso, ventana o servicio del sistema;
- convertir la selección de aplicaciones en administración remota, vigilancia de dispositivos o firewall;
- hacer que los asistentes personalizados exclusivos del navegador, como DOM, navegación, redirección o control de pestañas, funcionen en el tiempo de ejecución nativo;
- sincronizar cada grupo automáticamente simplemente porque el puente local está funcionando.

## 2. Vocabulario

| Término | Significado |
| --- | --- |
| Grupo | Un objeto de política de enfoque con nombre. Los nombres de los grupos deben ser únicos dentro del punto final de Vault actual. |
| Objetivo | Una identidad de aplicación nativa seleccionada para un grupo. |
| Grupo de aplicaciones predeterminado | Un grupo normal cuyos objetivos son aplicaciones nativas del selector de aplicaciones. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Partido | La aplicación actual en primer plano/en ejecución coincide con un objetivo de grupo habilitado y activo o una condición de regla personalizada. |
| Activo | Habilitado, dentro del horario normal y no pospuesto activamente. |
| Plan de aplicación | La decisión resultante de permitir/proteger/estado del host nativo después de evaluar los grupos aplicables. |
| Congelar | Protección contra la modificación ordinaria de un grupo. |
| Posponer | Una excepción temporal de una política de grupo normal. |

## 3. Identidad de destino y selector de aplicaciones

Seleccione aplicaciones a través del selector **+** en un grupo de aplicaciones predeterminado. Vault almacena una identidad normalizada, así como un nombre para mostrar.

| Anfitrión | Identidad de destino utilizada para hacer coincidir |
| --- | --- |
| MacOS | Identificador del paquete de aplicaciones cuando esté disponible. |
| Ventanas | Ruta ejecutable normalizada o nombre de proceso proporcionado por el selector de aplicaciones. |

El nombre para mostrar es para el editor. El valor normalizado es la identidad utilizada por la capa de aplicación nativa. Cambiar el nombre de una aplicación en la interfaz de usuario no cambia la identidad. Un objetivo también puede llevar etiquetas para el uso de políticas de reglas personalizadas.

No ingrese la URL de un sitio web en un campo de destino de la aplicación y espere la aplicación de la aplicación nativa. Utilice el grupo de sitios de la extensión para bloquear sitios web.

## 4. Ciclo de vida del grupo y precedencia

Un nuevo grupo está habilitado de forma predeterminada. La lista de grupos admite selección, habilitar/deshabilitar, orden de arrastre, Agregar, Borrar, importar, exportar y eliminar. El grupo seleccionado se abre en el editor.

Las ediciones de campos normales se guardan mediante la política de guardado automático del editor. Un grupo congelado desactiva los controles de edición ordinarios. Una fuente personalizada es diferente: guardar texto no la activa; **Ejecutar** es la operación que carga la fuente actual en el tiempo de ejecución de la política.

Varios grupos pueden coincidir con la misma aplicación. Vault evalúa la política de grupo en el orden almacenado y crea un plan de aplicación nativo. Mantenga las superposiciones intencionales, especialmente cuando los grupos usan diferentes políticas cronometradas o reglas personalizadas emiten decisiones de permiso/protección. Reordenar los grupos para dejar clara la prioridad prevista; no confíe en que una configuración conflictiva se resuelva de una manera particularmente fácil de usar.

## 5. Grupos de aplicaciones normales

### 5.1 Estado del grupo

| Campo | Contrato funcional |
| --- | --- |
| Nombre | No vacío, recortado y único que no distingue entre mayúsculas y minúsculas dentro de este punto final. |
| Habilitado | Los grupos discapacitados se mantienen pero no participan en la aplicación normal de la ley. |
| Objetivos | Una o más identidades de aplicación seleccionadas del selector. |
| Comportamiento | Bloqueo inmediato, bloqueo después de una asignación o cronómetro/cuenta atrás. |
| Horario | Días laborables seleccionados y ventanas de hora local opcionales. |
| Congelar | Ninguno, Congelado, Congelado estricto o Congelado parental. |
| Posponer | Política de excepción temporal por grupo. |
| Mensaje de reserva/estado | Mensaje que el host nativo puede mostrar cuando aplica una respuesta de escudo/estado. |

Un grupo predeterminado vacío no tiene ningún destino de aplicación seleccionado y, por lo tanto, no coincide con una aplicación simplemente por existir.

### 5.2 Comportamientos de bloqueo

| Comportamiento | Resultado |
| --- | --- |
| Bloquear inmediatamente | Un objetivo activo coincidente produce una decisión nativa inmediata de bloqueo/protección. |
| Bloquear después de varios minutos | El uso equivalente se acumula contra la asignación grupal. Cuando se agota la asignación, el grupo produce una decisión de bloqueo/protección nativa hasta que su período de uso se reinicia u otro estado inactiva al grupo. |
| Temporizador (cuenta atrás, sin bloqueo) | El uso coincidente se mide y puede mostrarse, pero ese temporizador por sí solo nunca produce un bloqueo. |

Los grupos nuevos utilizan un permiso de 15 minutos y un intervalo de reinicio de 24 horas a menos que se modifique. El uso cronometrado pertenece al grupo, por lo que todos los objetivos coincidentes comparten esa política de grupo. La respuesta exacta a un bloqueo la implementa el host nativo y está restringida por los permisos del sistema operativo y el mecanismo de aplicación admitido.

### 5.3 Horarios

Horarios aplican para grupos normales. Un grupo personalizado toma sus propias decisiones de tiempo en JavaScript.

Seleccione cualquier combinación de lunes a domingo. Cada ventana de tiempo es una línea en la hora local:

```text
0900-1200
1330-1730
```

El formato exacto aceptado es HHMM-HHMM. El horario debe ser de 00 a 23, minutos de 00 a 59 y el inicio debe ser más temprano que el final del mismo día. Una ventana incluye su inicio y excluye su final. No se aceptan ventanas que crucen la medianoche. Las ventanas vacías significan todo el día seleccionado.

El grupo normal está activo sólo cuando:

1. está habilitado;
2. se selecciona el día de la semana actual;
3. la hora local está dentro de una ventana configurada, o el grupo no tiene ventanas;
4. no está en modo de repetición activa.

### 5.4 Posponer

Posponer elimina temporalmente a un grupo normal de la aplicación activa. Sus fases son:

| Fase | Resultado |
| --- | --- |
| Pendiente | La solicitud existe pero el retraso de activación no ha transcurrido; el grupo permanece activo. |
| Activo | El grupo está temporalmente inactivo durante el tiempo de repetición. |
| Enfriamiento | La repetición ha finalizado y el grupo está activo nuevamente, pero aún no hay una nueva repetición disponible. |

| Configuración | Regla |
| --- | --- |
| Permitir posponer | Cuando está apagado, el grupo normalmente no se puede posponer. |
| Duración de la repetición | Número positivo de minutos. El valor predeterminado para un grupo nuevo es 30 minutos. |
| Retraso de activación | Cero o más minutos antes de que se active la repetición de alarma. |
| Enfriamiento | De cero a cinco minutos después de que finalice la repetición activa. |
| Confirmaciones | Número entero no negativo de interacciones de confirmación requeridas. |

Una repetición activa es una excepción temporal de la política, no una eliminación ni un descongelamiento. La configuración del grupo permanece intacta.

### 5.5 Congelar

La congelación es una barrera de modificación deliberada.

| Modo | Contrato |
| --- | --- |
| Congelado | Las ediciones ordinarias y los cambios de estado ordinarios permanecen bloqueados hasta que el flujo de confirmación de descongelación del producto se realice correctamente. |
| Congelado estricto | El grupo no se puede descongelar antes de que finalice su duración de congelación estricta. La duración es positiva y está limitada a 72 horas. |
| Congelado parental | Se requiere administración de contraseña de guardián para acciones de congelación/descongelación. |

Elegir un modo en el editor no congela el grupo por sí solo; Utilice la acción de congelación para aplicarlo. Un grupo vinculado por puente también puede bloquear controles de congelación coordinados mientras un miembro requerido está desconectado.

## 6. Aplicación nativa y control de dispositivos

El editor puede guardar con precisión un grupo incluso cuando el sistema operativo no ha otorgado la capacidad de aplicarlo. Verifique siempre **Configuración → Control de dispositivos** y el estado nativo en vivo después de cambiar los permisos.

El host nativo decide qué acciones son posibles para el sistema operativo, la aplicación, la ventana y el estado de permisos actuales. Una regla puede configurarse correctamente pero no tener ningún efecto visible cuando:

- El Control del Dispositivo no se otorga o ha sido revocado;
- el grupo está desactivado, programado o pospuesto activamente;
- el proceso enfocado no coincide con un objetivo normalizado seleccionado;
- el sistema operativo rechaza una acción para ese objetivo;
- una dependencia de puente está fuera de línea para una acción que requiere un estado coordinado.

No trate un brindis guardado exitoso como prueba de que la aplicación activa está disponible. Pruebe el objetivo seleccionado mientras el grupo está activo e inspeccione el estado del host.

## 7. Grupos personalizados y reglas de políticas nativas

Los grupos personalizados se ejecutan en el tiempo de ejecución de la política de JavaScript nativo. No son reglas personalizadas del navegador. El DOM del navegador, las pestañas, la navegación, la redirección de URL y el comportamiento de control de feeds no están disponibles intencionalmente.

### 7.1 Ciclo de vida de la fuente

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Eventos nativos integrados

| Evento | Significado |
| --- | --- |
| tickEvento | Garrapata periódica del huésped. Una opción de registro de intervalo puede limitar la velocidad de un controlador. |
| temporizadorfinalizado | Una cuenta regresiva controlada por reglas llega a cero. |
| posponerPresionar | El usuario presiona Iniciar repetición para un grupo personalizado. |
| panelEvento | Se utiliza un control de panel personalizado. |
| evento de archivo local | Se completa una acción de carpeta local solicitada. |
| openAppEvent | Se abre una aplicación rastreada. |
| cerrarAppEvent | Se cierra una aplicación rastreada. |
| evento de enfoque | La aplicación en primer plano cambia a una aplicación. |
| desenfocarEvento | La aplicación en primer plano se aleja de una aplicación. |
| minimizarEvento / unminimizeEvent | El host informa una transición de minimización de ventana compatible. |
| cambiarAppEvent | La aplicación en primer plano cambia de una aplicación a otra. |
| aplicaciónChangedEvent | Ciclo de vida general de la aplicación/evento de cambio. |

El objeto de evento contiene tipo, ID de grupo/ID de grupo, nombre de grupo, equivalentes de URL/nombre de host, hora, datos y destino. Para una aplicación nativa, el objetivo expone una identificación, un tipo, un nombre para mostrar, un valor normalizado y etiquetas cuando el objetivo de enfoque coincide con un objetivo configurado.

Los datos del evento del ciclo de vida de la aplicación incluyen el ID/nombre de la aplicación actual, el nombre del grupo, una instantánea serializada de la aplicación en ejecución y valores específicos del evento, como BundleId, PreviousAppId, CurrentAppId o el motivo del cambio.

### 7.3 API de eventos y decisiones

El registro proporciona activación/registro, desactivación/anulación del registro, anulación del registro de todos, recuento de registros, getEvent y getEvents. La prioridad más alta se ejecuta primero; La misma prioridad preserva el orden de registro. El registro tiene un límite de controlador por grupo.

El objeto de evento admite:

| Método | Resultado |
| --- | --- |
| establecerResultado(-1) | Produzca una decisión de escudo/bloqueo nativa. Un resultado de cadena también se convierte en un bloque nativo porque las reglas de escritorio no tienen un destino de redireccionamiento del navegador. |
| permitir(motivo) o setResult(1) | Produzca una decisión de permiso para el evento. |
| setShieldMessage(mensaje) | Establezca el escudo/mensaje de estado de cara humana para un bloque nativo. |
| detenerPropagación() | Detenga los controladores posteriores para el evento actual. |
| bloquear (appId), desbloquear (appId) | Agregar/eliminar un bloque de aplicación nativa dinámica. |
| cerrar (id de aplicación), abrir (id de aplicación) | Solicite una acción de cierre/apertura nativa compatible. |
| publicación (tipo, datos) | Distribuya un evento personalizado anidado dentro del tiempo de ejecución nativo. |

El tiempo de ejecución de la aplicación permite temporizadores, persistencia, paneles, registros, operaciones de carpetas locales, ayudas de ventanas de aplicaciones y utilidades de clasificación de URL. Trata deliberadamente el DOM, la navegación, la redirección y los asistentes de pestañas del navegador como no disponibles o inertes.

### 7.4 Ayudantes nativos

| Ayudante | Comportamiento nativo |
| --- | --- |
| obtenerLogHelper | Emite decisiones de registro de aplicaciones/ventanas emergentes/pantallas. |
| obtenerTimerHelper | Crea temporizadores de avance/retroceso con límites, pasos, predicados de alcance/dominio, pausa/reanudación, inspección de estado y transiciones con temporizador finalizado. Los temporizadores no se protegen por sí solos. |
| getPersistenceHelper | Estado JSON por grupo: obtener, configurar, eliminar, tiene, claves, entradas, borrar, tamaño. |
| getStorageHelper | Persistencia más marcadores de posición de solicitud asincrónica del host; no asuma una respuesta externa sincrónica. |
| getWindowHelper | Lee aplicaciones actuales/en ejecución y solicita acciones de cerrar/abrir/bloquear/desbloquear aplicaciones. |
| getPanelHelper | Crea instantáneas de paneles nativos validados, controles, controladores en línea y reacciones panelEvent. |
| getLocalFolderHelper | Las colas permitían operaciones relativas .txt, .csv y .json bajo la raíz otorgada por el usuario. La finalización es localFileEvent. |
| getDomainHelper / getDomainUtility | Clasificadores de URL y plataforma para reglas que también analizan valores similares a URL. |
| getPlatformHelper / plataforma | Los clasificadores de URL siguen estando disponibles; Las llamadas de control nativo de feed/DOM son inertes porque el host de escritorio no tiene DOM de sitio web. |

Los paneles personalizados utilizan el mismo vocabulario de control declarativo que el tiempo de ejecución del navegador: texto, casilla de verificación, selección, entrada de texto, área de texto, botón, sección, temporizador, entrada numérica, rango, alternancia, radio, fecha, hora, color, pin y html desinfectado. El host nativo decide qué parte de un panel se puede mostrar en la plataforma actual.

## 8. Carpeta de archivos locales

La carpeta de archivos local es un límite opcional otorgado por el usuario para las reglas personalizadas. Las reglas pueden solicitar lecturas, escrituras, anexos, listas, pruebas de existencia y operaciones JSON de texto/CSV/JSON. Las rutas siempre son relativas a la raíz seleccionada. Se rechazan las rutas absolutas, los segmentos transversales, los componentes de ruta ocultos, las extensiones no admitidas y las operaciones fuera de la raíz.

Revocar la carpeta cuando una regla ya no la necesite. Una regla debe controlar los permisos no disponibles y los resultados fallidos de localFileEvent; no debe asumir que una carpeta seleccionada permanece autorizada después de un reinicio.

## 9. Puente de aplicación web

El puente es una sincronización local opcional entre programas de Vault compatibles. Una aplicación de escritorio nativa puede alojar el centro local; los clientes se conectan en la dirección local admitida.

Los estados de conexión son Apagado, Conectando, Desconectado, Conectado/En ejecución y Error. Al conectar un programa no se fusionan todos los grupos. El usuario debe vincular explícitamente grupos coincidentes elegibles.

Para un enlace de grupo:

1. Inicie el centro nativo en Configuración.
2. Conecte el otro punto final de Vault compatible.
3. Cree grupos coincidentes y no congelados con el mismo nombre y tipo.
4. En la sección puente de grupo, elija el programa y conecte el grupo.

Un grupo vinculado forma un cluster. Los valores de política común admitidos, el uso y el estado de repetición se pueden sincronizar mientras los miembros están conectados. La desconexión detiene la sincronización y preserva los grupos locales. No se garantiza la transferencia de objetivos exclusivos del navegador, acciones personalizadas no admitidas y campos específicos de la plataforma.

## 10. Importar, exportar, restablecer y auditar

La exportación guarda una representación de grupo compatible. La importación valida/normaliza los datos del grupo compatible y aún aplica la unicidad del nombre local. Eliminar grupo elimina el grupo seleccionado y su estado asociado. Borrar elimina todos los grupos después de la confirmación. Restablecer los valores predeterminados afecta la configuración global del editor; exportar todo lo que deba conservarse primero.

Antes de confiar en una regla de escritorio:

1. Verifique que se haya otorgado el control del dispositivo.
2. Verifique la identidad normalizada del objetivo seleccionado.
3. Verifique el estado habilitado, la programación, el estado de congelación y la fase de repetición.
4. Pruebe el comportamiento inmediato, cronometrado y de conteo por separado.
5. Para un grupo personalizado, ejecute la fuente exacta y pruebe cada evento de aplicación registrado.
6. Verifique las fallas de la carpeta local y las operaciones exitosas.
7. Verifique el comportamiento del puente conectado/fuera de línea si el grupo está vinculado.

## 11. Notas específicas de la plataforma

Los conceptos básicos de las políticas se comparten, pero la aplicación nativa es específica del host:

| MacOS | Ventanas |
| --- | --- |
| Los destinos normalmente se resuelven en identificadores de paquetes de aplicaciones. Control de dispositivos y aplicación actual de la puerta de estado de permisos de macOS. | Los destinos normalmente se resuelven en una ruta ejecutable normalizada o un nombre de proceso. La capa de aplicación de Windows decide qué ventanas/procesos actuales se pueden administrar. |

Esta referencia de escritorio no describe deliberadamente las listas de bloqueo de sitios web, los selectores de feeds, la clasificación de creadores de YouTube, las redirecciones del navegador ni las acciones de las pestañas del navegador. Pertenecen al manual de extensión de Vault.
