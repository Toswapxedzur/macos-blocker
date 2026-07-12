#Projeto Mac Vault Xcode

`project.yml` é a especificação XcodeGen com check-in para os destinos macOS e iOS que usam o pacote Swift compartilhado.

## Gere o projeto

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Gere novamente após alterar `project.yml`, destinos, direitos ou associação de origem. Não use arquivos de projeto gerados como configuração canônica.

## Famílias-alvo atuais

- `AdamanciaVaultMac` é o destino do aplicativo macOS apoiado por `MacBlockerAppFeature`.
- `macosBlocker` é o destino do aplicativo iOS.
- O projeto iOS inclui extensões de atividade de dispositivo, configuração de escudo e ação de escudo.

Os identificadores atuais, destinos de implantação, campos de versão e recursos são definidos em `project.yml` e nos arquivos de autorização referenciados. Revise-os no ambiente de assinatura antes da distribuição.

## Assinatura e recursos

Use uma equipe e identificadores de pacote que pertençam à conta de distribuição. Confirme os recursos exigidos pelo destino que você está construindo. Nunca adicione segredos de assinatura, perfis de provisionamento ou credenciais de conta a este repositório.

## Teste primeiro

Execute os testes do pacote compartilhado antes de criar um arquivo:

```bash
cd ..
swift test
```
