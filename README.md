# jboss-eap-discovery

[![ShellCheck](https://github.com/darioajr/jboss-eap-discovery/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/darioajr/jboss-eap-discovery/actions/workflows/shellcheck.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Script Bash de inventário de instalações **JBoss EAP 6/7/8** (e WildFly) em servidores Linux. Descobre instalações, identifica modo de operação (standalone/domain), papel no domain (master/slave) e lista aplicações WAR/EAR declaradas e publicadas — tudo sem dependências externas.

📖 Artigo com contexto e exemplos: [Inventariando JBoss EAP 6, 7 e 8 com Bash](https://openplatformvoices.com/inventariando-jboss-eap-6-7-e-8-com-bash-descobrindo-wars-ears-domain-standalone-master-e-68a5e9056308)

## Características

- **Zero dependências**: não usa `jq`, `xmlstarlet`, `lsof`, `python` nem `perl`. Apenas utilitários POSIX presentes em qualquer RHEL 7/8/9 (`awk`, `sed`, `grep`, `find`, `ps`).
- **Dupla estratégia de descoberta**: processos em execução (`ps`) + varredura de disco (`find`).
- **Saída em texto** (relatório legível) **ou JSON** (integração com CMDB, automação, etc.).
- Detecta:
  - `JBOSS_HOME` de cada instalação;
  - Versão/produto (`version.txt` ou `bin/product.conf`);
  - Modo: `standalone`, `domain` ou `both-installed`;
  - Papel no domain: `master/primary` ou `slave/secondary` (via `host.xml`);
  - Nome do host JBoss no domain (`-Djboss.host.name`, `host.xml` ou hostname do SO);
  - Aplicações WAR/EAR declaradas nos XMLs de configuração (incluindo server-groups);
  - Aplicações WAR/EAR físicas no disco, com status pelos arquivos marcadores (`.deployed`, `.failed`, `.dodeploy`, etc.);
  - Divergências: apps declaradas no XML sem artefato físico visível.

## Uso

```bash
# Relatório em texto
./jboss-eap-discovery.sh

# Saída JSON
./jboss-eap-discovery.sh --json

# Diretórios de busca e profundidade customizados
SEARCH_ROOTS="/opt /jboss /u01 /apps" MAXDEPTH=12 ./jboss-eap-discovery.sh
```

> Execute como `root` (ou usuário com permissão de leitura nos diretórios do JBoss) para resultados completos.

### Opções

| Opção | Descrição |
|---|---|
| `--json` | Saída em JSON em vez de texto. |
| `--help`, `-h` | Mostra ajuda. |

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `SEARCH_ROOTS` | `/opt /jboss /app /apps /srv /usr/local /home /u01` | Diretórios raiz varridos pelo `find`. |
| `MAXDEPTH` | `8` | Profundidade máxima da varredura. |

### Códigos de saída

| Código | Significado |
|---|---|
| `0` | Pelo menos uma instalação encontrada. |
| `1` | Nenhuma instalação encontrada (vale também para `--json`, que retorna `installations: []`). |

## Estrutura da saída JSON

```json
{
  "generated_at": "2026-06-11 12:00:00 -0300",
  "os_hostname": "servidor01",
  "os_fqdn": "servidor01.empresa.com",
  "search_roots": ["/opt", "/jboss"],
  "maxdepth": "8",
  "installations": [
    {
      "jboss_home": "/opt/jboss-eap-7.4",
      "host_os": "servidor01",
      "host_fqdn_os": "servidor01.empresa.com",
      "host_jboss_domain": "host-prod-01",
      "discovered_by": "process",
      "pid_example": "12345",
      "version": "Red Hat JBoss Enterprise Application Platform - Version 7.4.0.GA",
      "mode": "standalone",
      "domain_role": "standalone",
      "host_xml": "",
      "server_config": "standalone-full.xml",
      "host_config": "",
      "processes": [{ "pid": "12345", "args": "..." }],
      "deployment_dirs": ["/opt/jboss-eap-7.4/standalone/deployments"],
      "apps_declared": [
        {
          "status": "DEPLOYED",
          "name": "minha-app.war",
          "runtime_name": "minha-app.war",
          "type": "war",
          "source_type": "xml",
          "source": "/opt/jboss-eap-7.4/standalone/configuration/standalone.xml",
          "scope": "top-level"
        }
      ],
      "apps_physical": [
        {
          "status": "DEPLOYED",
          "marker_status": "DEPLOYED",
          "name": "minha-app.war",
          "type": "war",
          "path": "/opt/jboss-eap-7.4/standalone/deployments/minha-app.war"
        }
      ],
      "apps_declared_without_visible_artifact": []
    }
  ]
}
```

## Status das aplicações

| Status | Significado |
|---|---|
| `DEPLOYED` | Aplicação publicada/deployada. |
| `DECLARED` | Declarada no XML, mas sem confirmação clara de publicação em server-group. |
| `NOT_DEPLOYED` | Arquivo `.war`/`.ear` no disco, mas não declarado/publicado. |
| `PENDING` | Existe marcador `.dodeploy`. |
| `FAILED` | Existe marcador `.failed`. |
| `UNDEPLOYED` | Existe marcador `.undeployed`. |
| `DEPLOYING` | Existe marcador `.isdeploying`. |
| `UNDEPLOYING` | Existe marcador `.isundeploying`. |
| `UNKNOWN` | Encontrado no disco, sem marcador e sem declaração clara. |

Regras de interpretação:

- Em **standalone**, aplicações em `standalone*.xml` são consideradas `DEPLOYED`.
- Em **domain**, aplicações em server-group são `DEPLOYED` quando `enabled="true"` ou sem `enabled="false"`.
- Em **domain**, aplicações apenas no bloco top-level `<deployments>` aparecem como `DECLARED`.
- Em `domain/data/content` o conteúdo é armazenado por hash, sem o nome original do WAR/EAR.

## Limitações conhecidas

- Caminhos (`JBOSS_HOME`, `SEARCH_ROOTS`) com espaços não são suportados.
- O parser de XML é linha a linha: tags `<deployment>` com atributos quebrados em múltiplas linhas não são detectadas.

## Licença

[Apache 2.0](LICENSE)
