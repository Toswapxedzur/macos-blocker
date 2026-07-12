# Cofre do Mac

Mac Vault é o membro nativo do macOS da família de produtos Vault. Ele combina um mecanismo de política Swift, um editor WebView, inventário de aplicativos nativos e adaptadores de aplicação, suporte a regras personalizadas e um hub de ponte de aplicativo da web local.

O código atual é a fonte da verdade. A referência no aplicativo em inglês é [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## O que é implementado

- Grupos padrão para aplicativos macOS selecionados e grupos personalizados para regras de política avançadas.
- Modos de bloqueio imediato, subsídio e contagem regressiva.
- Programações, modos de congelamento, fluxos de suspensão, importação/exportação e estado persistente do grupo.
- Inventário de aplicativos, estado de permissão de controle de dispositivo, adaptadores de aplicação nativos e uma superfície de status flutuante.
- Um tempo de execução de política JavaScript controlado com registro e verificação de sintaxe.
- Um hub de ponte WebSocket de loopback para grupos compatíveis explicitamente vinculados.
- Um editor WebView com o mesmo modelo de grupo principal da família de produtos Vault.

## Desenvolvimento

Execute os testes do pacote Swift:

```bash
swift test
```

O pacote inclui política principal, cronograma, regra personalizada, ponte, importação e testes de controle do macOS.

## Projeto Xcode

O projeto Xcode opcional é gerado a partir de [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Leia [XcodeProject/README.md](XcodeProject/README.md) antes de configurar destinos de assinatura ou distribuição.

## Política de documentação

Os documentos em inglês permanecem canônicos. A IU do editor possui catálogos de localidade completos, manuais traduzidos ao lado de `WebAssets/manual/en.md` e cópias traduzidas dos documentos mantidos restantes estão em `i18n-docs/<locale>/`.

Os termos legais e os avisos de privacidade permanecem documentos legais separados; este README não os substitui.
