# Kamal — локальный deploy / operations

## Цель

Документ объясняет как запускать `kamal` команды (`deploy`, `accessory reboot`,
`app exec`, и т.д.) с локальной машины против staging/production — корректно и
безопасно, без смешивания личных dev credentials и service credentials.

## Почему dedicated PAT (а не `gh auth token`)

**Anti-pattern (раньше было так):**

```bash
# .kamal/secrets-common (старая версия)
KAMAL_REGISTRY_PASSWORD=${KAMAL_REGISTRY_PASSWORD:-$(gh auth token)}
```

Проблемы этого подхода:

- **Scope creep:** personal CLI token получает scopes за пределами dev workflow
  (чтобы работал ghcr pull — нужен `read:packages`, но CLI также имеет `repo`,
  `workflow`, etc.). Kamal server auth должен использовать credential с
  минимальным set permissions.
- **No independent rotation:** ротация личного CLI токена затрагивает deploys;
  ротация deploy token не должна затрагивать dev workflow.
- **Attribution:** все server-side auth events в GitHub audit log attributed к
  личному user — невозможно отделить "я коммичу" от "я деплою".
- **Team onboarding:** новый разработчик получит copy личного fallback — или
  свой personal gh token станет deploy credential "случайно".

**Correct pattern (сейчас):**

```bash
# .kamal/secrets-common
KAMAL_REGISTRY_PASSWORD=${KAMAL_REGISTRY_PASSWORD:?must be exported...}
```

Fail-fast если env var не установлен. Dedicated fine-grained PAT с минимальным
scope required exported в shell перед kamal командой.

## Генерация PAT (один раз, затем ротация каждые 90 дней)

### Шаги в GitHub UI

1. Открой [Fine-grained PAT settings](https://github.com/settings/personal-access-tokens/new).
2. Заполни форму:
   - **Token name:** `kamal-registry-pull-<destination>` (пример:
     `kamal-registry-pull-staging`). Одиночное назначение = легче audit.
   - **Expiration:** 90 days (рекомендация: 90 дней — баланс rotation overhead
     vs security. Максимум 1 год GitHub позволяет для fine-grained PAT).
   - **Resource owner:** `himratesdev`.
   - **Repository access:** *Only select repositories* → `himrate-platform`.
     ВАЖНО: не давать All repositories — PAT только для одного репо.
   - **Repository permissions:** оставь все по умолчанию (No access). Pure
     packages pull не требует repo contents permissions.
   - **Account permissions → Packages:** `Read-only`.
     (При необходимости push images локально — добавь `Read and write`, но
     обычно push делает CI, не разработчик.)
3. Нажми **Generate token** → скопируй value немедленно (отображается один раз).

### Сохранение локально (выбери один вариант)

**Вариант A: macOS Keychain (рекомендация для Mac)**

```bash
# Сохранить
security add-generic-password -a "$USER" -s "kamal-registry-pull" -w "<PAT_VALUE>"

# Извлечь в переменную окружения
export KAMAL_REGISTRY_PASSWORD="$(security find-generic-password -a "$USER" -s "kamal-registry-pull" -w)"
```

Можно добавить функцию-helper в `~/.zshrc`:

```bash
kamal() {
  export KAMAL_REGISTRY_PASSWORD="$(security find-generic-password -a "$USER" -s "kamal-registry-pull" -w 2>/dev/null)"
  command kamal "$@"
}
```

**Вариант B: direnv (если уже используешь)**

`.envrc.local` (gitignored):

```bash
export KAMAL_REGISTRY_PASSWORD="<PAT_VALUE>"
```

**Вариант C: однократный export перед командой (самый безопасный, но неудобный)**

```bash
export KAMAL_REGISTRY_PASSWORD="<PAT_VALUE>"
kamal accessory reboot db -d staging
unset KAMAL_REGISTRY_PASSWORD
```

### Проверка работоспособности

```bash
export KAMAL_REGISTRY_PASSWORD="<PAT_VALUE>"
echo "$KAMAL_REGISTRY_PASSWORD" | docker login ghcr.io -u himratesdev --password-stdin
# Expected: Login Succeeded
docker logout ghcr.io
```

## Ротация (каждые 90 дней)

1. За неделю до expiration GitHub пришлёт email.
2. Повторить шаги "Генерация PAT" → создать новый PAT, старое имя оставить до
   cleanup.
3. Обновить значение в storage (Keychain/direnv).
4. Обновить repo secret `KAMAL_REGISTRY_PASSWORD` в
   [repo settings → secrets](https://github.com/himratesdev/himrate-platform/settings/secrets/actions)
   (используется deploy-production job в `ci.yml:165`).
5. Удалить старый PAT из GitHub settings после успешного теста.

## CI/CD: где какой credential используется

| Job                        | Registry credential                 | Rationale                                         |
|----------------------------|-------------------------------------|---------------------------------------------------|
| `deploy-staging`           | `secrets.GITHUB_TOKEN` (ephemeral)  | Automatic workflow service credential, auto-rotated per run. Permissions declared в workflow (`packages: write`). |
| `deploy-production`        | `secrets.KAMAL_REGISTRY_PASSWORD`   | Dedicated PAT required для explicit control на tagged release.  |
| `build-db-image`           | `secrets.GITHUB_TOKEN` (automatic)  | Package publish — встроенный scope.               |
| Local `kamal *` команды    | `$KAMAL_REGISTRY_PASSWORD` (env)    | Dedicated fine-grained PAT из Keychain/direnv.    |

Этот split не случаен:
- Для CI — `GITHUB_TOKEN` automatically scoped к workflow и auto-expired после
  run → нет persistent secret для утечки.
- Для production — explicit PAT в Environments secret + environment protection
  rules → audit trail + manual approval possible.
- Для local — explicit credential = developer осведомлён что делает deploy.

## Troubleshooting

**Error: `denied: denied` на `docker login ghcr.io`**

Проверь:

1. `echo $KAMAL_REGISTRY_PASSWORD | head -c 5` → должно начинаться с `github_pat_`.
2. PAT не expired (settings → Personal access tokens → check expiration).
3. PAT scope includes Packages: Read (settings → PAT → edit).
4. Resource owner = `himratesdev` (a не твой personal account).

**Error: `KAMAL_REGISTRY_PASSWORD must be exported...`**

Env var не установлен. Export через один из вариантов A/B/C выше.

**Error: `denied` только на pull конкретного package**

Package permissions переопределены на package level:

1. https://github.com/orgs/himratesdev/packages
2. Кликни package → Package settings → Manage actions access
3. Убедись что repo `himrate-platform` в allowed list.
