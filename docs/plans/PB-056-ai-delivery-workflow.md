# План: PB-056 — разработка, память и CI/CD

## Результат

Задача → критерии → реализация → проверки → ревью → commit/PR → Checks →
автоматический production CD точного SHA, с ручным redeploy/rollback.
Контекст восстанавливается из короткой передачи и индекса, логи хранятся вне чата.

## Границы и зависимости

Запрос пользователя 2026-11-23: полный workflow в репо, тестируемость,
производительность и экономия токенов без снижения качества. Изменяются инструменты,
CI/CD и процесс; игровые правила не меняются. Аудит GitHub только read-only;
публикация этих изменений и изменение настроек аккаунта в этот срез не входят.

## Шаги

- CI/CD: высокий риск (точный SHA, workflow_run, secrets) → sol/high →
  `.github/workflows`, `deploy/production`, production runbook → тесты выбора
  артефакта, lifecycle и HTTPS smoke.
- Производительность: средняя сложность → sol/medium → benchmark и его тесты,
  `docs/PERFORMANCE.md` → воспроизводимый JSON и проверяемый opt-in budget.
- Интеграция ведущего: runner проверок, Serena, правила памяти, аудит и документация.

- [x] Аудит исходного workflow и первоисточников.
- [x] Квитанции проверок, локальная конфигурация Serena и короткая память.
- [x] Benchmark правил и проекций, автоматический CD.
- [x] Общие проверки и передача с точными ограничениями.

## Проверка

- npm check с PostgreSQL16: 78 тестов (14 tools,37 backend,16 contracts,11 content),
  без пропусков. Повтор финального дерева — через runner, JSON/логи `output/checks/`.
- 13 release/resolve unit и14 ingress unit прошли.
- Production Docker/Caddy smoke с реальным PB-055 bundle прошёл:
  `/tmp/partybox-cd-production-smoke.log`.
- Serena2.1.0 stdio MCP: initial instructions, память, JS find_symbol и Dart
  symbols overview: `/tmp/partybox-serena-smoke.log`.
- Benchmark: p95 четырёх сценариев0,0033–0,0064мс; JSON `output/benchmarks/spy.json`.
- Actionlint1.7.12: новое поле queue:max требует узкого ignore;
  синтаксис сверён с официальным GitHub Docs. Остальные проверки прошли.
- Flutter/полный multi-client HTTPS заново не запускались: игровые исходники
  не менялись; текущие локальные результаты не заменяют будущий GitHub Actions run.

## Передача работы

Текущий срез PB-056; вход — `docs/AI_DEVELOPMENT.md`, затем `docs/WORKFLOW.md`.
На GitHub подтверждены admin/push-права, успешный Checks для `af42a65`, production
environment и семь имён environment secrets. Значения secrets не читались.
Защиты main нет. Настройки GitHub/VPS и публикация не изменялись.

Статистика tokens клиента недоступна; расход/процент экономии не оценивался.
Следующий шаг при поручении публикации: commit/PR, дождаться Checks, merge main,
проверить первый автоматический CD и затем применить подготовленную GitHub policy.
