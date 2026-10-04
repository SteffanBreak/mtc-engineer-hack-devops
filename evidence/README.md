# Проверки на реальном стенде

Дата: 4 октября 2026, UTC. ОС: Ubuntu 24.04.5 arm64, 4 CPU, 8 GiB RAM. Kubernetes установлен kubeadm, v1.35.9. Это реальные интеграционные проверки, а не результаты lint или mock-тестов.

- `verification-arm64.json`: первый успешный сквозной прогон, включая TLS, маршруты, рост HTTP counter, access/error в Loki и weighted backends 180/20.
- `verification-complete-arm64.json`: полный прогон с проверкой реальных PromQL-данных всех панелей Grafana, источников данных и исполнения NetworkPolicy.
- `resilience-arm64.json`: 55 HTTP-запросов во время rolling update, 0 ошибок; сохранение исходной записи Loki и исторического sample Prometheus после перезапуска.
- `verification-fresh-arm64.json`: полный прогон на второй чистой Ubuntu, без переноса кэша образов, секретов, kubeconfig или данных первой VM.
- `idempotence-fresh-arm64.json`: повтор bootstrap/deploy сохранил UID кластера и PVC, секреты и все рабочие Pod; после повтора verify также прошёл.
- `verification-audit-arm64.json`: повторный аудит после усиления проверок — точный HTTPS-ответ, второй TLS hostname, оба Envoy targets, 20 успешных HTTP-ответов, конечные числовые значения восьми панелей и завершённые ревизии Deployment.
- `idempotence-audit-arm64.json`: повтор bootstrap/deploy после добавления предварительных защит снова сохранил кластер, PVC, секреты и все 14 рабочих Pod.

Отчёты не содержат ключей, kubeconfig или паролей. Число ответов canary статистическое: следующий прогон не обязан дать ровно 20 из 200. `make verify`, `make demo`, `make resilience` заново создают отчёты в приватном `.local/`; публикация отчёта не является частью установки.

Проверка на второй чистой Ubuntu успешно выполнена отдельно. Исправленный установщик запускается напрямую через bash, поскольку Make в исходном cloud image отсутствует; Prometheus verification ждёт регистрации и первого успешного scrape новых targets. AMD64 поддержан скриптом установки и multiarch образами, но не заявляется как отдельно проверенный стенд.
