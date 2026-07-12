#Política de privacidade do Adamancia Vault

Última atualização: 7 de julho de 2026

Adamancia Vault é um aplicativo de foco e bloqueio. Esta política descreve o lançamento do aplicativo macOS.

## Resumo

O Adamancia Vault foi projetado para manter as regras de bloqueio e o estado de uso local do seu Mac por padrão. O aplicativo não vende dados pessoais, não exibe anúncios e não compartilha dados pessoais com corretores de dados.

## Dados armazenados localmente

O aplicativo pode armazenar os seguintes dados locais no seu Mac:

- Bloqueio de grupos, programações, temporizadores, estado de congelamento/soneca e configurações de aplicativos.
- Armazenamento local do editor da web espelhado da interface da web incluída.
- Estado da ponte/link local quando você conecta o aplicativo macOS às extensões do navegador.
- Arquivos de política de aplicação de aplicativos usados pelo mecanismo de bloqueio do macOS.
- Dados de contêiner do Grupo de Aplicativos quando uma versão da App Store ou uma versão de extensão usa um Grupo de Aplicativos.

Os caminhos locais conhecidos estão documentados em `RELEASE.md` e no script de desinstalação.

## Uso de rede

O aplicativo pode abrir um ouvinte de rede local para sua ponte de aplicativo da web para que as extensões do navegador possam se conectar ao aplicativo Mac. O aplicativo também pode fazer solicitações de rede se um recurso incluído precisar se comunicar com os serviços Adamancia, por exemplo, conta opcional ou recursos relacionados à sincronização.

## Análise e anúncios

O aplicativo macOS não inclui SDKs de publicidade de terceiros. Ele não deve enviar análises, a menos que um recurso diga explicitamente que está usando um serviço online.

## Contas opcionais e sincronização

Se os recursos de conta ou sincronização estiverem habilitados em uma versão, esses recursos poderão enviar os dados mínimos necessários para fornecer esse recurso, como identidade da conta e cargas de sincronização. Os downloads e o bloqueio local não devem exigir uma conta.

## Permissões

Dependendo do canal e dos recursos habilitados, o Adamancia Vault pode solicitar permissões ao macOS, como acessibilidade, acesso à rede, registro de item de login ou acesso ao grupo de aplicativos. Essas permissões são usadas para fornecer recursos de bloqueio, inicialização de aplicativos, ponte e persistência.

## Desinstalando

O DMG inclui `uninstall.command`. Ele pede confirmação, fecha o aplicativo se estiver em execução, cancela o registro do item de login do aplicativo quando possível, remove `/Applications/AdamanciaVault.app` e, opcionalmente, remove apenas arquivos conhecidos criados por este aplicativo.

## Contato

Para questões de privacidade, abra um problema no repositório público GitHub ou use o canal de contato publicado no site Adamancia Vault.
