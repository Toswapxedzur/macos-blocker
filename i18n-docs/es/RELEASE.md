# Guía de lanzamiento de Mac Vault

Esta guía sigue los scripts de compilación registrados. No contiene intencionalmente identidad de firma personal, perfil de notarización, contraseña ni datos de cuenta.

## Antes de un lanzamiento

1. Ejecute `swift test` desde la raíz del repositorio.
2. Establezca la versión de lanzamiento y el número de compilación en la configuración de compilación/proyecto controlado.
3. Revisar el manual en inglés, los manuales localizados y la auditoría de traducción del editor.
4. Verifique la rama de lanzamiento, la etiqueta y la política de hitos antes de publicar un artefacto.

## Tubería de DMG del sitio web

Los guiones viven en `scripts/release/`. Sus valores predeterminados se pueden anular con variables de entorno, incluidas `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` y `BUILD_NUMBER`.

Ejecute la canalización completa solo en una máquina de firma configurada:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

La canalización compone los scripts de compilación, firma, DMG, notarización y verificación existentes. Trate su salida como una versión candidata hasta que el paso de verificación sea exitoso.

## Objetivos de distribución de Xcode

Genere el proyecto Xcode desde `XcodeProject/project.yml`, configure el equipo de firma y las capacidades apropiadas en el entorno aprobado y luego archive el destino relevante. No confirme las credenciales generadas, los archivos de aprovisionamiento ni los perfiles de certificación notarial.

## Después de un lanzamiento

1. Cree la etiqueta de versión inmutable y la rama de versión permanente de acuerdo con la política de gestión de versiones.
2. Publique el artefacto de lanzamiento y la suma de comprobación.
3. Actualice el registro de versiones públicas solo después de que la URL del artefacto sea definitiva.
4. Mantenga las notas de la versión en inglés a menos que se proporcione una nota de la versión traducida y revisada.
