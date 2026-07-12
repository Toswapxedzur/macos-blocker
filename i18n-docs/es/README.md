# Bóveda de Mac

Mac Vault es el miembro nativo de macOS de la familia de productos Vault. Combina un motor de políticas Swift, un editor WebView, inventario de aplicaciones nativas y adaptadores de aplicación, compatibilidad con reglas personalizadas y un centro puente de aplicaciones web local.

El código actual es la fuente de la verdad. La referencia en inglés dentro de la aplicación es [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Qué se implementa

- Grupos predeterminados para aplicaciones macOS seleccionadas y grupos personalizados para reglas de políticas avanzadas.
- Modos de bloqueo inmediato, de asignación y de cuenta regresiva.
- Horarios, modos de congelación, flujos de repetición, importación/exportación y estado de grupo persistente.
- Inventario de aplicaciones, estado de permisos de control de dispositivos, adaptadores de aplicación nativos y una superficie de estado flotante.
- Un tiempo de ejecución de políticas de JavaScript controlado con registro y verificación de sintaxis.
- Un centro de puente WebSocket de bucle invertido para grupos compatibles vinculados explícitamente.
- Un editor WebView con el mismo modelo de grupo principal que la familia de productos Vault.

## Desarrollo

Ejecute las pruebas del paquete Swift:

```bash
swift test
```

El paquete incluye políticas básicas, programación, reglas personalizadas, puentes, importaciones y pruebas de control de macOS.

## Proyecto Xcode

El proyecto Xcode opcional se genera a partir de [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Lea [XcodeProject/README.md](XcodeProject/README.md) antes de configurar los destinos de firma o distribución.

## Política de documentación

Los documentos ingleses siguen siendo canónicos. La interfaz de usuario del editor tiene catálogos locales completos, los manuales traducidos se encuentran junto a `WebAssets/manual/en.md` y las copias traducidas de los documentos mantenidos restantes se encuentran en `i18n-docs/<locale>/`.

Los términos legales y los avisos de privacidad siguen siendo documentos legales separados; este README no los reemplaza.
