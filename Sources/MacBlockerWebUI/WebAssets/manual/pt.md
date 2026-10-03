# Manual do usuário Mac Vault

Mac Vault tem três páginas: **Vault** bloqueia aplicativos native, **Classifier** marca conteúdo compatível do navegador e **Activity** mostra o uso registrado. A extensão coleta conteúdo compatível e aplica bloqueio no navegador. Instale e conecte-a no navegador que você usa.

## Início rápido

1. Em **Vault**, adicione um grupo de bloqueio e um alvo Apps; depois selecione aplicativos com o seletor +.
2. Escolha o comportamento de bloqueio do grupo e ative-o.
3. Em **Classifier**, crie um grupo, escolha as plataformas e adicione tags com descrições.
4. Escolha um nível de modelo local e baixe-o se necessário. Ative a marcação nas configurações do Classifier e retome o grupo.
5. Abra conteúdo compatível no navegador conectado. Configure um filtro de tags em um grupo de bloqueio do navegador se quiser que as tags controlem o bloqueio.

## Grupos de bloqueio

Um **grupo de bloqueio** aplica uma política de bloqueio. Um **grupo Classifier** atribui tags ao conteúdo; ele não bloqueia nada por conta própria.

1. Adicione um grupo de bloqueio e dê um nome a ele.
2. Escolha alvos em **Aplicar a**.
3. Escolha quando o bloqueio se aplica e defina um cronograma ou tempo permitido, se quiser.
4. Ative o grupo. Os alvos compartilham a política do grupo.

As edições comuns são salvas automaticamente. Um erro significa que a edição não foi aceita; corrija o campo e tente novamente. Desative um grupo para suspender sua política sem perder a configuração. **Excluir grupo** o remove. Arraste os grupos para reordená-los. Mais de um grupo pode se aplicar ao mesmo alvo; adiar um não remove o bloqueio de outro.

**Exportar** copia a configuração de um grupo. **Importar** substitui a configuração do grupo selecionado após a confirmação.

### Tempo permitido e cronograma

**Bloquear imediatamente** aplica-se sempre que o grupo ativo corresponder e seu cronograma estiver em vigor. **Bloquear quando o tempo permitido for usado** permite o uso correspondente até o tempo acabar.

Defina o tempo permitido em minutos e o intervalo de redefinição em horas. Um limite móvel conta o uso na janela anterior. A redefinição à meia-noite inicia um novo período à meia-noite local, inclusive para um limite móvel.

Escolha os dias da semana ativos e intervalos opcionais do horário local, um por linha, como **09:00-12:00**. Sem intervalos, aplica-se durante todos os dias selecionados. Um intervalo deve terminar depois de começar no mesmo dia; divida um cronograma noturno em dias separados.

### Adiar

Configure o adiamento em cada grupo de bloqueio. **Pausar bloqueio** suspende a política do grupo durante o período definido. **Adicionar ao tempo permitido** acrescenta minutos utilizáveis a um grupo limitado por tempo. Só o tempo adicional consumido conta como tempo adiado. O tempo adicional não usado expira na próxima redefinição; em um limite móvel, expira após uma janela ou antes, à meia-noite, se a opção estiver ativada.

**Atraso de ativação** adia o pedido de adiamento enquanto o bloqueio continua. **Intervalo de espera** é o tempo após o fim do adiamento até que outro pedido possa ser feito. **Confirmações necessárias** define o número de etapas de confirmação. O adiamento fica disponível para um grupo congelado somente se permitido antes do congelamento.

### Congelar e PIN

**Congelar** impede edições comuns. Para descongelar, são necessárias dez confirmações com cinco segundos de intervalo, além da espera configurada e de um PIN de seis dígitos. **Aguardar antes de descongelar** aceita 0–72 horas; 0 não acrescenta espera.

Enquanto estiver congelado, é possível prolongar a espera e adicionar um PIN se ainda não houver um. Essas condições não podem ser flexibilizadas até o grupo ser descongelado. A exclusão também respeita a espera restante e o PIN.

### Grupos vinculados

Use **Vincular** para conectar grupos explicitamente selecionados em outros programas Vault. Grupos vinculados compartilham o nome, as configurações de política compatíveis, os alvos, o uso e as condições de congelamento. Cada programa edita e aplica os tipos de alvo compatíveis; outras entradas de alvo continuam disponíveis aos programas vinculados. Desvincular mantém cada grupo e suas configurações.

Se um membro vinculado estiver offline, talvez não seja possível editá-lo. Abra Mac Vault e o navegador vinculado para reconectar. Uma política salva localmente pode continuar ativa enquanto o membro estiver offline.

## Ajuda

Clique no pequeno **i** ao lado de um campo para ver a explicação. Clique fora dele ou pressione Escape para fechar. As listas ficam em caixas roláveis; role a caixa para ver mais itens. A pesquisa filtra a lista visível sem excluir itens.

As regras personalizadas têm um [Manual de código](../code-manual/pt.md) próprio. Ele explica o editor, a ativação, os registros, o acesso a arquivos e a API compatível.

## Aplicativos native

Use o seletor + de um alvo Apps para escolher aplicativos instalados. **Bloquear todos os aplicativos, exceto estes** transforma a lista em uma allowlist. Aplicativos de sistema, navegadores e o próprio Vault são excluídos do bloqueio native de aplicativos.

Um aplicativo bloqueado recebe um pedido para encerrar. **Pedir que o aplicativo bloqueado encerre novamente a cada (minutos)** controla as tentativas. Redirecionamentos de sites, pausas de páginas e ocultação de feeds são aplicados pela extensão do navegador; não se tornam ações de aplicativos native.

## Classifier

Um grupo Classifier marca conteúdo das plataformas atribuídas, usando sua própria árvore de tags e configurações do modelo. Cada plataforma pertence a um grupo. Escolha as plataformas ao criar o grupo; não poderão ser alteradas depois. Cronogramas e filtros de grupos de bloqueio não controlam a marcação.

Ative a marcação nas configurações do Classifier. Use **Pausar marcação / Retomar marcação** separadamente para cada grupo. Desativar o registro do feed da plataforma em **Activity → Registro** também interrompe a marcação desse feed.

### Tags e configurações do modelo

Crie tags, descreva seus significados e defina ou remova seus pais na árvore de tags. Arraste uma tag para mover seu ramo. Descrições claras ajudam o modelo a distinguir tags semelhantes. As configurações de cada grupo são independentes.

- **Velocidade ↔ Qualidade** seleciona um nível de modelo local. Modelos maiores usam mais memória; velocidade e resultados dependem do Mac e da carga de trabalho. Os downloads são compartilhados entre grupos.
- **Rigoroso ↔ Abrangente** define os requisitos de confiança e as quantidades padrão de tags.
- **Tags mínimas / Tags máximas** em Mais substituem essas quantidades padrão. Rigoroso ↔ Abrangente ainda controla a confiança das tags adicionais. Deixe um campo vazio para usar seu padrão.
- **Instruções de marcação** adiciona instruções opcionais para este grupo.

Edições comuns do Classifier são salvas automaticamente. O nível selecionado precisa ser baixado antes de marcar conteúdo. Grupos no mesmo nível compartilham um modelo carregado; até dois níveis podem permanecer carregados ao mesmo tempo.

Corrija as tags de um item de conteúdo na extensão do navegador. Clique em **+ tag**, pesquise as tags existentes do Classifier e escolha uma para adicionar. Use o controle de remoção da tag ou selecione-a e pressione Delete uma vez para removê-la. **Sem tag** significa que a marcação terminou sem tags; **Marcando** significa que o resultado está pendente. As correções ajudam futuras marcações.

## Knowledge e pesquisa na web

Knowledge armazena descrições curtas neste Mac para o modelo local de marcação. **Fontes de conteúdo** incluem criadores, contas, canais e comunidades. Descrições da fonte acompanham seu conteúdo. **Termos conhecidos** se aplicam quando um termo aparece no título.

Adicione uma fonte ou termo com descrição, ou deixe a descrição vazia para solicitar pesquisa quando habilitada. Sugestões de criadores ajudam a encontrar uma fonte já coletada pelo Classifier. Listas com seis ou mais entradas têm busca logo acima: Terms e Content sources de cada plataforma têm buscas separadas por nome, identificador ou descrição. Editar uma descrição afeta futuras marcações; excluir o conhecimento da fonte não impede que a pesquisa o recrie depois.

### Configurar provedor de pesquisa

1. Abra **Configurações do Classifier → API keys & providers**.
2. Escolha um tipo de provedor e **Adicionar provedor**. Isso cria uma configuração, não emite uma API key.
3. Obtenha as credenciais do provedor e insira-as. Para um endpoint personalizado compatível, configure também os campos endpoint e protocol.
4. Em **Pesquisa na web**, escolha um provedor com web search integrada. Busque a lista de modelos e selecione um modelo de pesquisa. Use a busca do seletor para filtrar; atualize a lista para buscá-la novamente.
5. Leia a divulgação de consentimento e habilite o consentimento. Em cada grupo, escolha **Ativado**, **Desativado** ou **Seguir configurações do Classifier**.

**Configurar pesquisa na web…** abre as configurações quando falta configuração. Um grupo não pode ignorar o consentimento de pesquisa. **Testar conexão** confirma que a solicitação de teste funcionou, não que todos os modelos aceitem pesquisa. O modelo de teste do provedor é separado do modelo de pesquisa selecionado.

Keys são armazenadas na pasta support do app neste Mac, não no system Keychain. Elas autenticam solicitações ao provedor configurado; o Vault não as envia ao próprio servidor. A pesquisa envia assuntos públicos higienizados ao provedor selecionado, não corpos de conteúdo privado nem resumos. Leia a divulgação de consentimento para ver os fields exatos enviados. O uso do provedor inclui testes de conexão e solicitações de lista de modelos, além da pesquisa.

O status da pesquisa mostra solicitações em fila, períodos de espera para tentar novamente, falhas e uso diário de tokens. **Tentar novamente agora assuntos com falha** tenta de novo as falhas elegíveis; não ignora a cota diária nem o consentimento.

## Activity

Activity registra localmente o uso de aplicativos habilitados, visitas a sites e **Conteúdo visualizado** compatível. Os gráficos refletem os dados registrados; uma área vazia não prova que o Mac esteve ocioso.

Escolha um intervalo de datas. **Linha do tempo** mostra o uso no horário do dia; **Totais** soma a duração. **Intervalo de tempo** agrupa o uso de cada intervalo em blocos verticais. **Cores** é uma legenda clicável: selecione uma fonte para destacar seus dados nos gráficos. Selecione um dia para ver o uso desde esse dia.

### Grupos Activity

Crie um grupo para mostrar juntos em Usage os aplicativos e sites selecionados. **Mesclar** usa um único nome e cor para os membros em todo o Activity. Um grupo Activity organiza o uso registrado; é separado de um grupo de bloqueio ou Classifier. Salve explicitamente o editor do grupo Activity com **Salvar**.

### Registro e retenção

Em **Registro**, ative ou desative o registro por categoria ou por fonte individual. **Manter** controla por quanto tempo o histórico é retido; **Para sempre** mantém sem expiração automática. Opções individuais podem seguir a configuração geral. Desativar o registro interrompe novos registros; excluir o histórico remove os dados registrados.

Feeds de plataforma coletam conteúdo exibido em páginas compatíveis, abertas ou não. Um feed com **Marcação compatível** pode fornecer dados ao Classifier enquanto o registro estiver ligado. A retenção desse feed controla o conteúdo coletado separadamente do uso de aplicativos e sites. Pausar um grupo Classifier não desativa o registro.

## Configurações do Classifier

**Atualizações de pacotes de tags** escolhe quando atualizações verificadas de pacotes entram em vigor: **Automático**, **Perguntar antes** ou **Manual**. É separado do download do modelo local escolhido no grupo. Arquivos de modelo vêm do Hugging Face quando você seleciona **Baixar**; durante o download, use o progresso/status do grupo e os controles **Cancelar**.

Escolha o idioma da interface em Settings. Explicações dos campos estão disponíveis nos pequenos botões Info no idioma selecionado.

## Salvamento e solução de problemas

Edições comuns do Vault e Classifier são salvas automaticamente. A edição de grupo Activity usa **Salvar**. Adicionar, excluir, baixar um modelo, testar uma conexão e buscar a lista de modelos continuam sendo ações explícitas.

Se faltarem tags, confira a conexão do navegador, o controle global de marcação, o estado de pausa do grupo, o registro da plataforma e o download do modelo. Se a pesquisa não funcionar, confira o consentimento, a escolha do grupo, as credenciais do provedor, o modelo de pesquisa e o status. Se não for possível editar um grupo vinculado, reconecte os programas ou descongele-o conforme indicado.
