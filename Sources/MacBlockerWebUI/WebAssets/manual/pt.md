# Referência funcional do aplicativo de desktop Vault

## Objetivo e limite

Esta é a referência oficial para a interface do aplicativo de desktop Vault. Ele é intencionalmente separado do manual de extensão do navegador Vault.

O aplicativo de desktop gerencia **aplicativos nativos e janelas de aplicativos**. A extensão do navegador gerencia sites, guias do navegador e feeds de plataformas da web compatíveis. Eles compartilham as mesmas ideias (grupos, programações, cronômetros, congelamentos, sonecas, regras personalizadas e ponte opcional), mas não têm a mesma superfície de aplicação.

Use este documento para configurar, auditar, reproduzir ou manter o comportamento do aplicativo de desktop. O código é canônico se uma implementação e este manual forem diferentes.

## 1. O que o aplicativo de desktop pode ou não controlar

O Vault avalia a política de foco para aplicativos nativos selecionados. Quando seu recurso de imposição nativo estiver disponível, ele poderá aplicar o plano atual aos destinos de aplicativos correspondentes e relatar um resultado de proteção/status à interface do usuário do host.

Pode:

- criar, ativar, desativar, reordenar, importar, exportar, congelar, suspender e remover grupos;
- direcionar aplicativos nativos selecionados por meio do seletor de aplicativos;
- aplicar um bloqueio imediato, uma permissão cronometrada ou um cronômetro somente de contagem progressiva;
- restringir grupos normais aos dias da semana e janelas de horário local;
- executar regras de política JavaScript personalizadas para eventos do ciclo de vida do aplicativo;
- mostrar informações de status/painel nativo criado por regra através do host;
- gerenciar uma pasta local opcional para solicitações de arquivos de regras personalizadas suportadas;
- junte-se a grupos explicitamente vinculados compatíveis por meio da ponte local do Vault.

Não pode:

- atuar como uma extensão do navegador, inspecionar o DOM de um site ou manipular cartões de feed do navegador;
- garantir que um sistema operacional permitirá que cada aplicativo, processo, janela ou serviço do sistema seja controlado;
- transformar a seleção de aplicativos em administração remota, vigilância de dispositivos ou firewall;
- fazer com que ajudantes personalizados somente do navegador, como DOM, navegação, redirecionamento ou controle de guias, funcionem no tempo de execução nativo;
- sincronize cada grupo automaticamente apenas porque a ponte local está em execução.

## 2. Vocabulário

| Prazo | Significado |
| --- | --- |
| Grupo | Um objeto de política de foco nomeado. Os nomes dos grupos devem ser exclusivos no endpoint atual do Vault. |
| Alvo | Uma identidade de aplicativo nativa selecionada para um grupo. |
| Grupo de aplicativos padrão | Um grupo normal cujos alvos são aplicativos nativos do seletor de aplicativos. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Partida | O aplicativo atual em primeiro plano/em execução corresponde a um destino de grupo habilitado e ativo ou a uma condição de regra personalizada. |
| Ativo | Ativado, dentro da programação normal e não adiado ativamente. |
| Plano de execução | A decisão de permissão/proteção/status resultante do host nativo após avaliar os grupos aplicáveis. |
| Congelar | Proteção contra modificação ordinária de um grupo. |
| Adiar | Uma exceção temporária de uma política de grupo normal. |

## 3. Identidade de destino e seletor de aplicativos

Selecione aplicativos por meio do seletor **+** em um grupo de aplicativos padrão. O Vault armazena uma identidade normalizada, bem como um nome de exibição.

| Anfitrião | Identidade alvo utilizada para correspondência |
| --- | --- |
| macOS | Identificador do pacote de aplicativos, quando disponível. |
| Janelas | Caminho executável normalizado ou nome do processo fornecido pelo seletor de aplicativos. |

O nome de exibição é para o editor. O valor normalizado é a identidade usada pela camada de aplicação nativa. Renomear um aplicativo na UI não altera a identidade. Um destino também pode conter tags para uso de políticas de regras personalizadas.

Não insira o URL de um site em um campo de destino do aplicativo e espere a aplicação nativa do aplicativo. Use o grupo Site da extensão para bloquear sites.

## 4. Ciclo de vida e precedência do grupo

Um novo grupo é habilitado por padrão. A lista de grupos suporta seleção, ativação/desativação, ordem de arrastar, adicionar, limpar, importar, exportar e excluir. O grupo selecionado é aberto no editor.

As edições normais dos campos são salvas por meio da política de salvamento automático do editor. Um grupo congelado desativa os controles de edição comuns. Uma fonte personalizada é diferente: salvar texto não a torna ativa; **Executar** é a operação que carrega a fonte atual no tempo de execução da política.

Vários grupos podem corresponder ao mesmo aplicativo. O Vault avalia a política de grupo na ordem armazenada e cria um plano de aplicação nativo. Mantenha as sobreposições intencionais, especialmente quando os grupos usam políticas cronometradas diferentes ou regras personalizadas emitem decisões de permissão/proteção. Reordene os grupos para deixar clara a precedência pretendida; não confie na resolução de uma configuração conflitante de uma maneira específica e amigável.

## 5. Grupos normais de aplicativos

### 5.1 Estado do grupo

| Campo | Contrato funcional |
| --- | --- |
| Nome | Não vazio, aparado e exclusivo, sem distinção entre maiúsculas e minúsculas neste endpoint. |
| Habilitado | Os grupos de deficientes são mantidos, mas não participam na aplicação normal. |
| Alvos | Uma ou mais identidades de aplicativo selecionadas no seletor. |
| Comportamento | Bloqueio imediato, bloqueio após uma permissão ou cronômetro/contagem progressiva. |
| Cronograma | Dias da semana selecionados e janelas de horário local opcionais. |
| Congelar | Nenhum, Congelado, Congelado estrito ou Congelado parental. |
| Adiar | Política de exceção temporária por grupo. |
| Mensagem de reserva/status | Mensagem que o host nativo pode mostrar quando aplica uma resposta de escudo/status. |

Um grupo Padrão vazio não possui nenhum destino de aplicativo selecionado e, portanto, não corresponde a um aplicativo apenas por existir.

### 5.2 Comportamentos de bloqueio

| Comportamento | Resultado |
| --- | --- |
| Bloquear imediatamente | Um alvo ativo correspondente produz uma decisão imediata de bloqueio/escudo nativo. |
| Bloquear após alguns minutos | O uso correspondente é acumulado contra o subsídio de grupo. Quando a permissão se esgota, o grupo produz uma decisão de bloqueio/proteção nativa até que seu período de uso seja redefinido ou outro estado torne o grupo inativo. |
| Temporizador (contagem progressiva, sem bloqueio) | O uso correspondente é medido e pode ser exibido, mas esse cronômetro sozinho nunca produz um bloco. |

Novos grupos usam um limite de 15 minutos e um intervalo de reinicialização de 24 horas, a menos que sejam alterados. O uso cronometrado pertence ao grupo, portanto, todos os destinos correspondentes compartilham essa política de grupo. A resposta exata a um bloco é implementada pelo host nativo e é limitada pelas permissões do sistema operacional e pelo mecanismo de aplicação suportado.

### 5.3 Cronogramas

Os horários aplicam-se a grupos normais. Um grupo personalizado toma suas próprias decisões de tempo em JavaScript.

Selecione qualquer combinação de segunda a domingo. Cada janela de tempo é uma linha na hora local:

```text
0900-1200
1330-1730
```

O formato exato aceito é HHMM-HHMM. O horário deve ser de 00 a 23, o minuto de 00 a 59, e o início deve ser anterior ao término do mesmo dia. Uma janela inclui o seu início e exclui o seu fim. As janelas da meia-noite não são aceitas. Janelas vazias significam todo o dia selecionado.

O grupo normal está ativo somente quando:

1. está habilitado;
2. o dia da semana atual é selecionado;
3. o horário local está dentro de uma janela configurada ou o grupo não possui janelas;
4. não está em soneca ativa.

### 5.4 Soneca

A suspensão remove temporariamente um grupo normal da aplicação ativa. Suas fases são:

| Fase | Resultado |
| --- | --- |
| Pendente | A solicitação existe, mas o atraso de ativação não expirou; o grupo permanece ativo. |
| Ativo | O grupo fica temporariamente inativo durante a soneca. |
| Recarga | A soneca terminou e o grupo está ativo novamente, mas uma nova soneca ainda não está disponível. |

| Configuração | Regra |
| --- | --- |
| Permitir soneca | Quando desativado, o grupo não pode ser adiado normalmente. |
| Duração da soneca | Número positivo de minutos. O padrão para um novo grupo é 30 minutos. |
| Atraso de ativação | Zero ou mais minutos antes que a soneca seja ativada. |
| Recarga | Zere até cinco minutos após o término da soneca ativa. |
| Confirmações | Número inteiro não negativo de interações de confirmação necessárias. |

Uma soneca ativa é uma exceção de política temporária, não uma exclusão ou descongelamento. A configuração do grupo permanece intacta.

### 5.5 Congelar

O congelamento é uma barreira de modificação deliberada.

| Modo | Contrato |
| --- | --- |
| Congelado | As edições comuns e as alterações de estado comuns permanecem bloqueadas até que o fluxo de confirmação de descongelamento do produto seja bem-sucedido. |
| Estrito congelado | O grupo não pode ser descongelado antes do término da duração do congelamento estrito. A duração é positiva e limitada a 72 horas. |
| Parental congelado | O gerenciamento de senha do responsável é necessário para ações de congelamento/descongelamento. |

A escolha de um modo no editor não congela o grupo por si só; use a ação de congelamento para aplicá-lo. Um grupo vinculado por ponte também pode bloquear controles de congelamento coordenados enquanto um membro necessário estiver offline.

## 6. Aplicação nativa e controle de dispositivo

O editor pode salvar um grupo com precisão, mesmo quando o sistema operacional não concedeu a capacidade de aplicá-lo. Sempre verifique **Configurações → Controle de dispositivos** e o status nativo ativo após alterar as permissões.

O host nativo decide quais ações são possíveis para o sistema operacional, aplicativo, janela e estado de permissão atuais. Uma regra pode ser configurada corretamente, mas não ter efeito visível quando:

- O Controle do Dispositivo não foi concedido ou foi revogado;
- o grupo está desativado, agendado ou suspenso ativamente;
- o processo em foco não corresponde a um alvo normalizado selecionado;
- o sistema operacional rejeita uma ação para esse alvo;
- uma dependência de ponte está offline para uma ação que requer estado coordenado.

Não trate um brinde bem-sucedido como prova de que a aplicação ativa está disponível. Teste o destino selecionado enquanto o grupo está ativo e inspecione o status do host.

## 7. Grupos personalizados e regras de política nativa

Grupos customizados são executados no tempo de execução da política JavaScript nativa. Elas não são regras personalizadas do navegador. O DOM do navegador, a guia, a navegação, o redirecionamento de URL e o comportamento de controle de feed estão intencionalmente indisponíveis.

### 7.1 Ciclo de vida da fonte

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Eventos integrados nativos

| Evento | Significado |
| --- | --- |
| tickEvento | Carrapato periódico do hospedeiro. Uma opção de registro intervalMs pode limitar a taxa de um manipulador. |
| temporizador finalizado | Uma contagem regressiva de propriedade da regra chega a zero. |
| sonecaPressione | O usuário pressiona Iniciar soneca para um grupo personalizado. |
| painelEvento | Um controle de painel personalizado é usado. |
| localFileEvent | Uma ação de pasta local solicitada é concluída. |
| openAppEvent | Um aplicativo rastreado é aberto. |
| fecharAppEvent | Um aplicativo rastreado é fechado. |
| focoEvento | O aplicativo em primeiro plano muda para um aplicativo. |
| evento desfocado | O aplicativo em primeiro plano muda de um aplicativo. |
| minimizeEvent / desminimizeEvent | O host relata uma transição de minimização de janela suportada. |
| switchAppEvent | O aplicativo em primeiro plano muda de um aplicativo para outro. |
| appChangedEvent | Evento geral de mudança/ciclo de vida do aplicativo. |

O objeto de evento contém tipo, groupId/groupID, groupName, URL/hostname equivalentes, hora, dados e destino. Para um aplicativo nativo, o destino expõe um ID, tipo, displayName, valor normalizado e tags quando o destino em foco corresponde a um destino configurado.

Os dados de eventos do ciclo de vida do aplicativo incluem o ID/nome do aplicativo atual, o nome do grupo, um instantâneo serializado do aplicativo em execução e valores específicos do evento, como bundleId, previousAppId, currentAppId ou motivo da alteração.

### 7.3 API de eventos e decisões

O registro fornece on/register, off/unregister, unregisterAll, countRegistered, getEvent e getEvents. A prioridade mais alta é executada primeiro; prioridade igual preserva a ordem de registro. O registro tem um limite de manipulador por grupo.

O objeto de evento suporta:

| Método | Resultado |
| --- | --- |
| setResult(-1) | Produza uma decisão nativa de escudo/bloqueio. Um resultado de string também se torna um bloco nativo porque as regras da área de trabalho não têm destino de redirecionamento do navegador. |
| permitir(motivo) ou setResult(1) | Produza uma decisão de permissão para o evento. |
| setShieldMessage(mensagem) | Defina a mensagem de status/escudo voltada para humanos para um bloco nativo. |
| pararPropagação() | Pare os manipuladores posteriores para o evento atual. |
| bloquear(appId), desbloquear(appId) | Adicione/remova um bloco de aplicativo nativo dinâmico. |
| fechar(appId), abrir(appId) | Solicite uma ação nativa de fechamento/abertura suportada. |
| post(tipo, dados) | Despache um evento personalizado aninhado no tempo de execução nativo. |

O tempo de execução do aplicativo permite temporizadores, persistência, painéis, logs, operações de pasta local, auxiliares de janela de aplicativo e utilitários de classificação de URL. Ele trata deliberadamente os auxiliares de DOM, navegação, redirecionamento e guias do navegador como indisponíveis/inertes.

### 7.4 Ajudantes nativos

| Ajudante | Comportamento nativo |
| --- | --- |
| getLogHelper | Emite decisões de registro de aplicativo/popup/tela. |
| getTimerHelper | Cria temporizadores de avanço/retrocesso com limites, etapas, predicados de escopo/domínio, pausa/retomada, inspeção de estado e transições timerEnded. Os temporizadores não protegem sozinhos. |
| getPersistenceHelper | Estado JSON por grupo: obter, definir, excluir, possuir, chaves, entradas, limpar, tamanho. |
| getStorageHelper | Persistência mais espaços reservados para solicitação assíncrona de host; não assuma uma resposta externa síncrona. |
| getWindowHelper | Lê aplicativos atuais/em execução e solicita ações de fechamento/abertura/bloqueio/desbloqueio de aplicativos. |
| getPanelHelper | Cria instantâneos de painel nativos validados, controles, manipuladores in-line e reações de panelEvent. |
| getLocalFolderHelper | As filas permitiam operações relativas .txt, .csv e .json na raiz concedida pelo usuário. A conclusão é localFileEvent. |
| getDomainHelper/getDomainUtility | Classificadores de URL e plataforma para regras que também raciocinam sobre valores semelhantes a URL. |
| getPlatformHelper/plataforma | Os classificadores de URL permanecem disponíveis; as chamadas de controle de feed/DOM nativo são inertes porque o host da área de trabalho não possui DOM de site. |

Os painéis personalizados usam o mesmo vocabulário de controle declarativo do tempo de execução do navegador: texto, caixa de seleção, seleção, textInput, área de texto, botão, seção, temporizador, numberInput, intervalo, alternância, rádio, data, hora, cor, pino e HTML higienizado. O host nativo decide quanto de um painel pode ser exibido na plataforma atual.

## 8. Pasta de arquivo local

A Pasta de Arquivos Local é um limite opcional concedido pelo usuário para regras personalizadas. As regras podem solicitar leituras, gravações, acréscimos, listas, testes de existência e operações JSON de texto/CSV/JSON. Os caminhos são sempre relativos à raiz selecionada. Caminhos absolutos, segmentos de passagem, componentes de caminho ocultos, extensões não suportadas e operações fora da raiz são rejeitados.

Revogue a pasta quando uma regra não precisar mais dela. Uma regra deve lidar com permissões indisponíveis e resultados de localFileEvent com falha; ele não deve presumir que uma pasta selecionada permanece autorizada após uma reinicialização.

## 9. Ponte de aplicativo da Web

A ponte é uma sincronização local opcional entre programas Vault compatíveis. Um aplicativo de desktop nativo pode hospedar o hub local; os clientes se conectam no endereço local suportado.

Os estados de conexão são Desligado, Conectando, Desconectado, Conectado/Em execução e Erro. Conectar um programa não mescla todos os grupos. O usuário deve vincular explicitamente os grupos correspondentes qualificados.

Para um link de grupo:

1. Inicie o hub nativo em Configurações.
2. Conecte o outro endpoint compatível do Vault.
3. Crie grupos descongelados correspondentes com o mesmo nome e tipo.
4. Na seção de ponte de grupo, escolha o programa e conecte o grupo.

Um grupo vinculado forma um cluster. Os valores de política comum suportados, o uso e o estado de suspensão podem ser sincronizados enquanto os membros estão conectados. A desconexão pausa a sincronização e preserva os grupos locais. Não há garantia de transferência de destinos somente de navegador, ações personalizadas não suportadas e campos específicos da plataforma.

## 10. Importar, exportar, redefinir e auditar

A exportação salva uma representação de grupo compatível. A importação valida/normaliza dados de grupo compatíveis e ainda impõe a exclusividade do nome local. Excluir grupo remove o grupo selecionado e seu estado associado. Limpar remove todos os grupos após a confirmação. A redefinição para os padrões afeta as configurações globais do editor; exporte tudo o que deve ser retido primeiro.

Antes de confiar em uma regra de desktop:

1. Verifique se o controle do dispositivo foi concedido.
2. Verifique a identidade normalizada do alvo selecionado.
3. Verifique o estado ativado, programação, estado de congelamento e fase de soneca.
4. Teste o comportamento imediato, cronometrado e de contagem separadamente.
5. Para um grupo personalizado, execute a origem exata e teste cada evento de aplicativo registrado.
6. Verifique as falhas da pasta local, bem como as operações bem-sucedidas.
7. Verifique o comportamento da ponte offline/conectada se o grupo estiver vinculado.

## 11. Notas específicas da plataforma

Os principais conceitos de política são compartilhados, mas a aplicação nativa é específica do host:

| macOS | Janelas |
| --- | --- |
| Os destinos normalmente são resolvidos para identificadores de pacotes de aplicativos. Controle de dispositivos e a atual aplicação do portão de estado de permissão do macOS. | Os destinos normalmente são resolvidos para um caminho executável normalizado ou nome de processo. A camada de aplicação do Windows decide quais janelas/processos atuais podem ser gerenciados. |

Esta referência para desktop deliberadamente não descreve listas de bloqueio de sites, seletores de feed, classificação de criadores do YouTube, redirecionamentos de navegador ou ações nas guias do navegador. Eles pertencem ao manual de extensão do Vault.
