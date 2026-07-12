# Guia de lançamento do Mac Vault

Este guia segue os scripts de construção com check-in. Ele intencionalmente não contém identidade de assinatura pessoal, perfil de reconhecimento de firma, senha ou dados de conta.

## Antes de um lançamento

1. Execute `swift test` na raiz do repositório.
2. Defina a versão de lançamento e o número da compilação na configuração controlada do projeto/compilação.
3. Revise o manual em inglês, os manuais localizados e a auditoria de tradução do editor.
4. Verifique a política de branch, tag e marco de lançamento antes de publicar um artefato.

## Pipeline DMG do site

Os scripts ficam em `scripts/release/`. Seus padrões podem ser substituídos por variáveis ​​de ambiente, incluindo `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` e `BUILD_NUMBER`.

Execute o pipeline completo somente em uma máquina de assinatura configurada:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

O pipeline compõe os scripts existentes de construção, assinatura, DMG, reconhecimento de firma e verificação. Trate sua saída como uma candidata a lançamento até que a etapa de verificação seja bem-sucedida.

## Alvos de distribuição do Xcode

Gere o projeto Xcode de `XcodeProject/project.yml`, configure a equipe de assinatura e os recursos apropriados no ambiente aprovado e, em seguida, arquive o destino relevante. Não confirme credenciais geradas, arquivos de provisionamento ou perfis de reconhecimento de firma.

## Depois de um lançamento

1. Crie a tag de versão imutável e o branch de lançamento permanente de acordo com a política de gerenciamento de lançamento.
2. Publique o artefato de lançamento e a soma de verificação.
3. Atualize o registro de liberação pública somente depois que a URL do artefato for final.
4. Mantenha as notas de lançamento em inglês, a menos que seja fornecida uma nota de lançamento localizada revisada.
