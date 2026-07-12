# Política de privacidad de Adamancia Vault

Última actualización: 7 de julio de 2026

Adamancia Vault es una aplicación de enfoque y bloqueo. Esta política describe la versión de la aplicación macOS.

## Resumen

Adamancia Vault está diseñado para mantener las reglas de bloqueo y el estado de uso local en su Mac de forma predeterminada. La aplicación no vende datos personales, no muestra anuncios y no comparte datos personales con intermediarios de datos.

## Datos almacenados localmente

La aplicación puede almacenar los siguientes datos locales en su Mac:

- Bloqueo de grupos, horarios, temporizadores, estado de congelación/posposición y configuración de aplicaciones.
- Almacenamiento del editor web local reflejado desde la interfaz web incluida.
- Estado del puente/enlace local cuando conectas la aplicación macOS a las extensiones del navegador.
- Archivos de políticas de aplicación de aplicaciones utilizados por el motor de bloqueo de macOS.
- Datos del contenedor del grupo de aplicaciones cuando una compilación o extensión de la App Store utiliza un grupo de aplicaciones.

Las rutas locales conocidas están documentadas en `RELEASE.md` y en el script de desinstalación.

## Uso de la red

La aplicación puede abrir un escucha de red local para su puente de aplicación web para que las extensiones del navegador puedan conectarse a la aplicación de Mac. La aplicación también puede realizar solicitudes de red si una función incluida necesita comunicarse con los servicios de Adamancia, por ejemplo, cuenta opcional o funciones relacionadas con la sincronización.

## Análisis y anuncios

La aplicación macOS no incluye SDK de publicidad de terceros. No debe enviar análisis a menos que una función indique explícitamente que está utilizando un servicio en línea.

## Cuentas opcionales y sincronización

Si las funciones de cuenta o sincronización están habilitadas en una versión, esas funciones pueden enviar los datos mínimos necesarios para proporcionar esa función, como la identidad de la cuenta y las cargas útiles de sincronización. Las descargas y el bloqueo local no deben requerir una cuenta.

## Permisos

Dependiendo del canal y las funciones habilitadas, Adamancia Vault puede solicitar permisos a macOS como Accesibilidad, acceso a la red, registro de elementos de inicio de sesión o acceso al grupo de aplicaciones. Estos permisos se utilizan para proporcionar funciones de bloqueo, inicio de aplicaciones, puente y persistencia.

## Desinstalar

El DMG incluye `uninstall.command`. Solicita confirmación, cierra la aplicación si se está ejecutando, cancela el registro del elemento de inicio de sesión de la aplicación cuando es posible, elimina `/Applications/AdamanciaVault.app` y, opcionalmente, elimina solo los archivos conocidos creados por esta aplicación.

## Contacto

Para preguntas sobre privacidad, abra una incidencia en el repositorio público de GitHub o utilice el canal de contacto publicado en el sitio web de Adamancia Vault.
