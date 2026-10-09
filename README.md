# Teste de CI/CD com deploy sem queda na Azure

> Piloto do plano [`../infra_ci-cd-deploy-continuo-vm-azure.md`](../infra_ci-cd-deploy-continuo-vm-azure.md).
> Repositório: <https://github.com/wfmunizj/cicd-azure>
>
> **Objetivo:** provar que um merge em `main` publica sozinho na VM, **sem derrubar** o sistema, e que um
> deploy quebrado **não** tira a versão anterior do ar.

---

## Arquitetura do teste

```
                      GitHub (wfmunizj/cicd-azure)
   push dev / main ──► Actions: test → build → push imagem (GHCR)
                                              │
              ┌───────────────────────────────┴──────────────────────────┐
              │ job deploy-dev                    job deploy-prod        │
              │ runs-on: vm-dev                   runs-on: vm-prod       │
              ▼                                                          ▼
 ┌──────────────────────────── Azure: rg-teste-cicd ────────────────────────────┐
 │  vnet-teste-cicd 10.10.0.0/16                                                │
 │  └─ snet-app 10.10.1.0/24   ── nsg-app: entrada 22 e 80 só do SEU IP        │
 │      ├─ vm-dev  (B2ats v2)  Nginx :80 → blue :18001 / green :18002          │
 │      └─ vm-prod (B2ats v2)  Nginx :80 → blue :18001 / green :18002          │
 │         cada VM tem um runner do GitHub (só conexão de SAÍDA)                │
 └──────────────────────────────────────────────────────────────────────────────┘
```

- **VNet** é o nome da VPC na Azure. A NSG é o firewall da subnet.
- **Nenhuma porta é aberta para o GitHub.** O runner dentro da VM é quem busca os jobs. Por isso não
  existe chave SSH guardada em secret.
- **As duas VMs são B2ats v2** (x64, mesma arquitetura da produção). A conta gratuita cobre 750 h/mês
  desse tamanho, ou seja, uma VM ligada 24h. A segunda consome alguns dólares do crédito de US$ 200,
  e o limite de gasto da conta gratuita impede cobrança no cartão. Para ficar 100% no gratuito,
  desaloque a `vm-dev` quando não estiver testando: `az vm deallocate -g rg-teste-cicd -n vm-dev`.

### O que tem nesta pasta

| Arquivo | Para quê |
|---------|----------|
| `app/main.py` | App FastAPI mínima: `/health` e `/` (mostra versão e cor ativa) |
| `tests/test_health.py` | Testes que o CI roda |
| `Dockerfile` | Mesma base dos sistemas Lux (Python 3.11 + driver ODBC 18) |
| `.github/workflows/pipeline.yml` | CI/CD: test → build → deploy (dev ou prod) |
| `deploy/deploy.sh` | Deploy blue-green com health check e rollback automático |
| `infra/01-criar-rede-e-vms.sh` | Cria resource group, VNet, subnet, NSG e as 2 VMs |
| `infra/cloud-init.yaml` | Prepara cada VM no 1º boot: swap, Docker, Nginx, usuário `deploy` |
| `infra/99-apagar-tudo.sh` | Apaga tudo no fim do teste |
| `scripts/teste-downtime.ps1` | Mede se houve queda durante o deploy |

---

## Fase 0 — Pré-requisitos (≈ 15 min)

- [ ] **Conta Azure gratuita** criada em <https://azure.microsoft.com/free> (pede cartão, mas não cobra
      enquanto você estiver nos limites gratuitos)
- [ ] **Azure CLI** instalada no Windows (PowerShell):
      ```powershell
      winget install -e --id Microsoft.AzureCLI
      ```
      Feche e reabra o terminal depois.
- [ ] **Git Bash** (já vem com o Git for Windows)
- [ ] **Alerta de orçamento**: Portal Azure → *Cost Management* → *Budgets* → *Add* → valor **US$ 5**,
      alerta em 50% e 100% para o seu e-mail. Assim nenhuma cobrança passa despercebida.

---

## Fase 1 — Rede e VMs na Azure (≈ 15 min)

**1.1 Login** (Git Bash, dentro desta pasta):

```bash
cd "/c/Users/wellington.fernandes/OneDrive - Lux/WatchDog/teste-cicd"
az login
az account show --query "{assinatura:name, id:id}" -o table   # confere se é a assinatura gratuita
```

**1.2 Criar tudo:**

```bash
MEU_IP=$(curl -4 -s https://ifconfig.me) bash infra/01-criar-rede-e-vms.sh
```

Se a criação da VM falhar com `SkuNotAvailable` (B2ats v2 sem capacidade na região), apague o que foi
criado com `bash infra/99-apagar-tudo.sh` e rode de novo em outra região:

```bash
LOC=northcentralus MEU_IP=$(curl -4 -s https://ifconfig.me) bash infra/01-criar-rede-e-vms.sh
```

No fim ele mostra os IPs das duas VMs. **Anote os IPs públicos.**

> ⚠️ **Antes de confirmar**, veja no portal o custo estimado. IP público Standard pode ter custo pequeno
> fora do crédito, e é isso que o alerta de orçamento da Fase 0 vigia.

**1.3 Conferir cada VM** (repita para `vm-dev` e `vm-prod`):

```bash
ssh azureuser@<IP_PUBLICO>
cloud-init status --wait          # espera terminar; tem que dar "status: done"
docker --version && nginx -v      # instalados?
free -h                           # deve aparecer Swap: 2.0Gi
curl -i http://localhost/         # 502 Bad Gateway é o ESPERADO (ainda não há app)
exit
```

> Seu IP mudou (VPN, outra rede) e o SSH parou? Atualize a regra:
> `az network nsg rule update -g rg-teste-cicd --nsg-name nsg-app -n allow-ssh-meu-ip --source-address-prefixes $(curl -4 -s https://ifconfig.me)`
> (e o mesmo para `allow-http-meu-ip`).

---

## Fase 2 — Configurar o GitHub (≈ 20 min)

### 2.1 Proteger o runner contra PR de terceiros

O repositório é **público**. Em *Settings → Actions → General → Fork pull request workflows from outside
collaborators*, marque **"Require approval for all outside collaborators"**.

Como os jobs que rodam nas VMs só disparam em **push** para `dev`/`main`, nunca em PR, esse ajuste é
uma camada extra de segurança.

### 2.2 Instalar o runner nas duas VMs

No GitHub: *Settings → Actions → Runners → New self-hosted runner → **Linux / x64***. A página mostra
os comandos com a **versão** e o **token** corretos (o token vale 1 h). Em cada VM:

```bash
ssh azureuser@<IP_PUBLICO>

sudo -iu deploy                          # o runner roda como "deploy", não como admin
mkdir actions-runner && cd actions-runner
# ↓ cole aqui os comandos da seção "Download" da página do GitHub (curl ... e tar xzf ...)

./config.sh --url https://github.com/wfmunizj/cicd-azure \
            --token <TOKEN_DA_PAGINA> \
            --name vm-dev --labels vm-dev --unattended     # na vm-prod: vm-prod / vm-prod
exit                                     # volta para azureuser

# vira serviço (sobe sozinho se a VM reiniciar). Tudo dentro do sudo: no Ubuntu 24.04 o
# /home/deploy é fechado para o azureuser, então um "cd" fora do sudo falha
sudo bash -c 'cd /home/deploy/actions-runner && ./svc.sh install deploy && ./svc.sh start && ./svc.sh status'
# esperado: active (running)
```

Em *Settings → Actions → Runners*, os dois devem aparecer como **Idle**, com os labels `vm-dev` e `vm-prod`.

### 2.3 Criar os environments

*Settings → Environments*:

| Environment | Configuração |
|-------------|--------------|
| `dev` | Nenhuma |
| `production` | **Required reviewers**: você. **Deployment branches**: *Selected branches* → `main` |

Com isso, todo deploy em produção espera um clique em **"Approve"**. É o gate manual do piloto (decisão 4
do plano).

---

## Fase 3 — Primeiro deploy (≈ 15 min)

### 3.1 Subir o código para a `main`

O agente não faz commit nem push (Regra 2 do `_watchdog`), então estes comandos ficam com você:

```bash
cd "/c/Users/wellington.fernandes/OneDrive - Lux/WatchDog/teste-cicd"
git init -b main
git add .
git commit -m "kit de teste CI/CD"
git remote add origin https://github.com/wfmunizj/cicd-azure.git
git push -u origin main
```

Em *Actions*: `test` → `build` → `deploy-prod` (aguardando aprovação) → **Review deployments → Approve**.

Confira no navegador: `http://<IP_VM_PROD>/` deve responder algo como
`{"app":"app-teste","versao":"main-<sha>","cor":"green"}`.

### 3.2 Criar a branch `dev`

```bash
git checkout -b dev
git push -u origin dev
```

O pipeline roda `deploy-dev`. Confira `http://<IP_VM_DEV>/`.

### 3.3 Proteger a `main` (só agora, senão o push inicial seria bloqueado)

*Settings → Rules → Rulesets → New branch ruleset*:

- **Name:** `protege-main` · **Enforcement:** Active · **Target:** *Include default branch*
- ✅ **Restrict deletions**
- ✅ **Block force pushes**
- ✅ **Require a pull request before merging** (0 aprovações basta, já que você está sozinho no teste)
- ✅ **Require status checks to pass** → adicionar `test` e `build`

---

## Fase 4 — Os testes

Anote os resultados na tabela da [Fase 6](#fase-6--resultado).

### Teste 1 — Fluxo completo dev → main sem queda

1. Mude algo visível em `app/main.py`, por exemplo `"app": "app-teste v2"`
2. `git commit -am "v2" && git push` (na `dev`) → espera o `deploy-dev` terminar
3. Abra um PR `dev → main` no GitHub. O CI roda no PR e o merge só libera com `test` e `build` verdes
4. **Antes de mergear**, em outro terminal (PowerShell):
   ```powershell
   cd "C:\Users\wellington.fernandes\OneDrive - Lux\WatchDog\teste-cicd"
   .\scripts\teste-downtime.ps1 -Url http://<IP_VM_PROD>/ -Segundos 300
   ```
5. Faça o merge → aprove o `production` → acompanhe o script

**Esperado:** a linha muda de `main-<sha_antigo> [green]` para `main-<sha_novo> [blue]` e o final mostra
**`Erros: 0`**.

### Teste 2 — Deploy quebrado não derruba o sistema

Simula o risco mais comum: **variável nova que existe no CI mas não foi criada no `.env` da VM**.

1. Na `dev`, em `app/main.py`, logo abaixo de `COLOR = ...`:
   ```python
   NOVA_VARIAVEL = os.environ["NOVA_VARIAVEL"]  # sem default: sem ela a app não sobe
   ```
2. Crie `tests/conftest.py` (o CI tem a variável, a VM não):
   ```python
   import os

   os.environ.setdefault("NOVA_VARIAVEL", "valor-de-teste")
   ```
3. Commit + push na `dev`, PR para `main`, merge, aprovar, **com o `teste-downtime.ps1` rodando**

**Esperado:**
- O CI passa
- O job `deploy-prod` **falha** com `❌ Health check falhou` e o log do container mostra `KeyError: 'NOVA_VARIAVEL'`
- O script de downtime continua mostrando a **versão anterior**, com **`Erros: 0`**

**Corrigir como seria em produção:**
```bash
ssh azureuser@<IP_VM_PROD>
echo "NOVA_VARIAVEL=valor-real" | sudo -u deploy tee -a /opt/lux/app-teste/.env
```
No GitHub, abra o run que falhou → **Re-run failed jobs** → aprovar. Agora o deploy passa.

> Para a `vm-dev` vale o mesmo: o deploy de `dev` também vai falhar até a variável existir lá. É o
> ambiente de dev avisando antes da produção, que é o papel dele.

### Teste 3 — Rollback manual

```bash
ssh azureuser@<IP_VM_PROD>
sudo -iu deploy
cat /opt/lux/app-teste/current_image /opt/lux/app-teste/previous_image
cd ~/actions-runner/_work/cicd-azure/cicd-azure
bash deploy/deploy.sh app-teste "$(cat /opt/lux/app-teste/previous_image)"
```

**Esperado:** volta a versão anterior, também sem queda (rode o `teste-downtime.ps1` junto).

### Teste 4 — As proteções seguram

| Tentativa | Esperado |
|-----------|----------|
| `git push origin main` direto (estando na `main`) | Rejeitado pelo ruleset |
| PR com teste quebrado (ex: `assert False` em um teste) | Botão de merge bloqueado |
| Aprovação de `production` negada (**Reject**) | Nada é publicado e prod segue como está |

### Teste 5 — Parecer de merge pelo agente (o `_release` do plano)

Com alguma alteração na `dev` que ainda não foi para a `main`, peça ao agente nesta pasta:

> "verifique o que está pendente entre dev e main no cicd-azure e me dê o parecer de merge"

**Esperado:** o agente roda só comandos de leitura, aplica o checklist do plano e emite
APTO / RESSALVAS / NÃO APTO, **sem** abrir PR nem mergear até você pedir explicitamente.
Para ele ler o status do CI, rode antes `gh auth login` (o `gh` já está instalado, mas não está logado).

---

## Fase 5 — Limpeza

Quando terminar (ou se for pausar por muitos dias):

```bash
bash infra/99-apagar-tudo.sh        # pede confirmação digitando o nome do resource group
```

Para só **pausar** sem apagar: `az vm deallocate -g rg-teste-cicd -n vm-prod` (e `vm-dev`). VM
desalocada não consome horas. Para voltar: `az vm start ...`. O IP público Standard é estático e se mantém.

No GitHub, depois de apagar as VMs: *Settings → Actions → Runners* → remover os dois runners offline.

---

## Fase 6 — Resultado

| # | Teste | Resultado | Erros no downtime | Observação |
|---|-------|-----------|-------------------|------------|
| 1 | Fluxo dev → main sem queda | ☐ ok ☐ falhou | | |
| 2 | Deploy quebrado não derruba | ☐ ok ☐ falhou | | |
| 3 | Rollback manual | ☐ ok ☐ falhou | | |
| 4 | Proteções (ruleset, CI, aprovação) | ☐ ok ☐ falhou | — | |
| 5 | Parecer do agente | ☐ ok ☐ falhou | — | |

Também vale anotar, porque alimenta as decisões pendentes do plano:

- Tempo total do pipeline, do push até o deploy concluído: ______
- Tempo do build da imagem com ODBC: ______
- Memória da VM durante a troca, com as duas cores no ar (`free -h`): ______
- 1 GB de RAM + 2 GB de swap aguentou bem a troca? ______

---

## Problemas comuns

| Sintoma | Causa provável | Solução |
|---------|---------------|---------|
| `deploy-*` fica em **Queued** para sempre | Runner offline ou label diferente | `sudo bash -c 'cd /home/deploy/actions-runner && ./svc.sh status'`; label tem que ser exatamente `vm-dev`/`vm-prod` |
| `denied` no `docker pull` | Pacote GHCR sem acesso ao repo | GitHub → *Packages* → `cicd-azure` → *Package settings* → *Manage Actions access* → adicionar o repo com **Read** |
| `permission denied ... docker.sock` | O runner subiu antes de o `deploy` entrar no grupo docker | `sudo bash -c 'cd /home/deploy/actions-runner && ./svc.sh stop && ./svc.sh start'` |
| `sudo: a password is required` no deploy | Sudoers não aplicado | `sudo cat /etc/sudoers.d/deploy`; rever o `cloud-init` (`sudo cat /var/log/cloud-init-output.log`) |
| SSH/HTTP não conecta | Seu IP mudou | Atualizar as regras da NSG (fim da Fase 1) |
| `$'\r': command not found` | Arquivo `.sh` com CRLF | O `.gitattributes` evita isso. Se aparecer, `git add --renormalize . && git commit` |
| VM travando no deploy | Pouca RAM (B2ats v2 tem 1 GB) | `free -h`; o swap de 2 GB deve absorver. Se não absorver, é dado para o plano (tamanho mínimo de VM) |
| `SkuNotAvailable` ao criar a VM | Tamanho bloqueado ou sem capacidade na região (na conta gratuita, `brazilsouth` e `eastus2` bloqueiam B2ats v2) | Apagar o resource group e rodar com `LOC=chilecentral` ou `LOC=northcentralus` |
