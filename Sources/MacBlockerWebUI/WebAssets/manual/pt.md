# Manual do usuário do Mac Vault

O Mac Vault tem três páginas: **Vault** bloqueia apps nativos, **Marcação de conteúdo** marca conteúdo compatível do navegador e **Atividade** mostra o uso registrado. A extensão do navegador coleta conteúdo compatível e aplica bloqueios no navegador. Instale-a e conecte-a ao navegador usado.

## Início rápido

1. Em **Vault**, adicione um grupo de blocos e um destino Apps; selecione apps com o seletor +.
2. Escolha o comportamento de bloqueio e ative o grupo.
3. Em **Marcação de conteúdo**, crie um grupo, escolha as plataformas e adicione tags com descrições.
4. Em Configurações → **Conexões de IA**, escolha ChatGPT subscription, OpenAI API, Gemini API ou Grok API. Conecte a conta ou informe a chave e busque modelos; depois escolha conexão/modelo no grupo. Ative a marcação e retome o grupo.
5. Abra conteúdo compatível no navegador conectado. Configure um filtro de tags em um browser grupo de blocos se quiser que as tags controlem o bloqueio.

## Grupos de bloqueio

Um **grupo de blocos** aplica uma política de bloqueio. Um grupo **Marcação de conteúdo** atribui tags ao conteúdo e não bloqueia por si só. Adicione e nomeie o grupo, escolha destinos em **Aplica-se a**, defina quando bloquear e configure agenda ou limite de tempo; depois ative-o. Edições comuns são salvas automaticamente. Um erro significa que a alteração não foi aceita; corrija o campo e tente novamente. Desativar o grupo interrompe a política e mantém sua configuração; **Excluir grupo** o remove. Arraste grupos para reordená-los. Vários grupos podem se aplicar ao mesmo destino; snooze em um não suspende o bloqueio de outro. **Exportar** copia a configuração; **Importar** substitui a do grupo selecionado após confirmação.

### Limite de tempo e agenda

**Block immediately** bloqueia quando o grupo ativado corresponde e a agenda está ativa. **Block when the time allowance is used** permite o uso até o limite acabar. Defina o limite em minutos e o intervalo de reinicialização em horas. O limite móvel conta o uso na janela anterior. Reiniciar à meia-noite inicia um novo período à meia-noite local, inclusive para limite móvel. Escolha dias ativos e janelas opcionais de horário local, uma por linha, como **09:00-12:00**. Sem janelas, vale o dia inteiro selecionado. A janela deve terminar depois de começar no mesmo dia; divida agendas noturnas entre dias.

### Pausa

Configure snooze em cada grupo de blocos. **Pause blocking** suspende a política durante a pausa. **Add to the time allowance** acrescenta minutos utilizáveis a um grupo com limite de tempo. Só o adicional consumido conta como tempo snoozed. O adicional não usado vence na próxima reinicialização; em limite móvel após uma janela ou antes à meia-noite se habilitado. **Activation delay** adia snooze enquanto o bloqueio continua. **Cooldown** é a espera após o snooze antes de outro pedido. **Required confirmations** define quantas confirmações são necessárias. Snooze em grupo congelado só existe se permitido antes do freeze.

### Freeze e PIN

**Freeze** impede edições comuns. Para descongelar são necessárias dez confirmações com intervalo de cinco segundos, a espera configurada e PIN de seis dígitos. **Wait before unfreezing** aceita 0–72 horas; 0 não acrescenta espera. Durante o freeze, a espera pode aumentar e um PIN pode ser adicionado, mas as condições não podem ser enfraquecidas até descongelar. A exclusão também respeita a espera restante e o PIN.

### Grupos vinculados

Use **Vincular** para conectar grupos escolhidos explicitamente em outros programas Vault. Eles compartilham nome, configurações de política compatíveis, destinos, uso e condições de freeze. Cada programa edita e aplica os tipos de destino que suporta; outros destinos permanecem disponíveis aos programas vinculados. **Desvincular** separa sem remover grupos ou configurações. Se um membro estiver offline, abra o Mac Vault e o navegador vinculado para reconectar. Uma política salva localmente pode continuar aplicada offline.

## Ajuda

Clique no pequeno **i** ao lado do campo para ver a explicação; clique fora ou pressione Escape para fechar. Listas ficam em caixas roláveis; a busca filtra o que está visível sem excluir itens. O [Manual de código](../code-manual/pt.md) explica editor de regras personalizadas, ativação, logs, acesso a arquivos e API.

## Apps nativos

Use o seletor + do destino Apps para escolher apps instalados ou em execução. Reabra-o para atualizar a lista após iniciar um app de outra pasta. **Bloquear todos os apps, exceto os listados aqui** transforma a lista em allowlist. O Mac Vault pode bloquear apps Apple comuns e navegadores inteiros; ele próprio e apps com o mesmo bundle identifier permanecem protegidos. Um app bloqueado recebe pedido para sair; **Pedir que um app bloqueado feche novamente a cada (minutos)** define as tentativas. Redirecionamentos de sites, pausas de páginas e ocultação de feeds são aplicados pela extensão, não são ações nativas.

## Marcação de conteúdo

Cada Marcação de conteúdo marca conteúdo das plataformas atribuídas com sua própria árvore de tags e configurações de modelo. Cada plataforma pertence a um grupo; escolha ao criar, pois não poderá mudar depois. Agendas e filtros de bloqueio não controlam tagging. Ative tagging em Configurações e use **Pausar classificação / Retomar classificação** separadamente por grupo. Desligar a gravação de um feed em **Atividade → Gravação** também interrompe seu tagging.

### Tags e configurações do modelo

Crie tags, descreva seus significados e defina/remova pais na árvore. Arrastar move o ramo. Descrições claras ajudam o modelo a distinguir tags parecidas. As configurações são independentes por grupo. **Confiança mínima da tag** define o grau de evidência exigido, de 1 a 5; grupos novos começam em 4 (suporte forte). Não há quantidade-alvo; um item pode ficar sem tags. **Instruções de marcação** guarda preferências do grupo. Edições comuns salvam automaticamente; cada grupo usa conexão, modelo e reasoning effort escolhidos explicitamente.

### Conexões de IA

Configurações oferece ChatGPT subscription, OpenAI API, Gemini API e Grok API. A assinatura usa o login do Vault e um plano elegível. Chaves API seguem a cobrança e os limites do provedor escolhido. Selecione o provedor e digite a chave logo abaixo do menu compartilhado; alterações salvam automaticamente e limpar o campo apaga a chave. **Buscar lista de modelos** busca modelos, mas não escolhe um; selecione-o no grupo Marcação de conteúdo ou custom-rule.

**Nível de raciocínio** controla quanto o modelo pensa: padrão do modelo, Low, Medium ou High quando compatível. Novas escolhas começam em Medium; as existentes permanecem salvas. Mais esforço pode aumentar tempo e tokens. A busca na Web está sempre ativa para tagging; o modelo decide quando usá-la. Escolha modelo compatível com busca e tagging estruturado. Pedidos falhos/indisponíveis preservam resultados válidos em cache; itens novos ficam sem resolução até escolher **Tentar classificação na nuvem novamente**. O Vault não troca de provedor automaticamente; cada conexão tem intervalo e limite de tentativas próprios. Corrija tags na extensão com **+ tag**; use remover ou selecione e pressione Delete uma vez. **Sem tag** significa concluído sem tags; **Classificando…** significa resultado pendente. Sua correção é a referência daquele item.

## Atividade

Atividade registra localmente uso de apps habilitados, visitas a sites e **Conteúdo visualizado** compatível. Os gráficos mostram dados registrados; espaço vazio não prova que o Mac estava ocioso. Escolha um intervalo. **Linha do tempo** mostra horários do dia, **Totais** soma duração e **Intervalo de tempo** agrupa uso em blocos verticais por intervalo. **Cores** é legenda clicável para focar uma fonte. Escolha um dia para ver uso a partir dele.

### Grupos Atividade

Crie um grupo para exibir apps e sites selecionados juntos em Usage. **Merge** usa um nome e cor únicos para os membros em Atividade. Um grupo Atividade organiza uso registrado e é separado de grupos de bloqueio e tagging. Salve o editor explicitamente com **Save**.

### Gravação e retenção

Em **Gravação**, ligue/desligue a gravação por categoria ou fonte. **Manter** define quanto tempo o histórico fica guardado; **Sempre** não expira automaticamente. Escolhas individuais podem seguir a configuração mais ampla. Desligar a gravação impede novos registros; apagar o histórico remove entradas gravadas. Feeds de plataforma coletam conteúdo exibido em páginas compatíveis, abertas ou não. Um feed **Marcação compatível** pode alimentar Marcação de conteúdo enquanto gravado. A retenção é separada do uso de apps e sites. Pausar um grupo de tagging não desliga a gravação.

## Configurações

Escolha o idioma da interface em Configurações. Explicações dos campos aparecem nos botões Info no idioma selecionado.

## Salvamento e solução de problemas

Edições comuns de Vault e Marcação de conteúdo salvam automaticamente; o editor Atividade exige **Save**. Adicionar, excluir, testar conexão e buscar modelos são ações explícitas. Se faltarem tags, verifique conexão do navegador, controle global de tagging, pausa do grupo, gravação da plataforma, conexão/modelo e credenciais. Em falhas de IA, verifique também limites do provedor e Log do grupo. Se não conseguir editar grupo vinculado, reconecte programas ou descongele conforme indicado.
