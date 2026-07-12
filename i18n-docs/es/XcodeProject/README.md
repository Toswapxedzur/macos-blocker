# Proyecto Mac Vault Xcode

`project.yml` es la especificación XcodeGen registrada para los destinos macOS e iOS que usan el paquete Swift compartido.

## Generar el proyecto

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Regenerar después de cambiar `project.yml`, destinos, derechos o membresía de origen. No utilice archivos de proyecto generados como configuración canónica.

## Familias objetivo actuales

- `AdamanciaVaultMac` es el objetivo de la aplicación macOS respaldado por `MacBlockerAppFeature`.
- `macosBlocker` es el destino de la aplicación iOS.
- El proyecto iOS incluye extensiones Actividad del dispositivo, Configuración del escudo y Acción del escudo.

Los identificadores actuales, los objetivos de implementación, los campos de versión y las capacidades se definen en `project.yml` y los archivos de derechos a los que se hace referencia. Revíselos en el entorno de firma antes de su distribución.

## Firma y capacidades

Utilice identificadores de equipo y paquete que pertenezcan a la cuenta de distribución. Confirme las capacidades requeridas por el objetivo que está construyendo. Nunca agregue secretos de firma, perfiles de aprovisionamiento o credenciales de cuenta a este repositorio.

## Prueba primero

Ejecute las pruebas del paquete compartido antes de crear un archivo:

```bash
cd ..
swift test
```
