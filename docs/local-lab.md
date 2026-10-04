# Изолированный стенд на Mac с Apple Silicon

Проверка выполнялась на новой VM через portable Lima 2.2.1 (Apple Virtualization framework), с LIMA_HOME внутри каталога этой задачи. Существующая VM пользователя в UTM не использовалась. Хостовые каталоги не смонтированы, SSH agent и ключи из домашнего каталога не передаются. Внешние порты открыты только на 127.0.0.1.

Переносимый шаблон VM: `lab/ubuntu-arm64.yaml`. Зафиксирован официальный Ubuntu cloud image release-20260926 и SHA256. Для Linux/SSH сценария Lima не требуется: достаточно отдельной Ubuntu 24.04 и обычных команд Makefile.

Установите Lima из [официального релиза 2.2.1](https://github.com/lima-vm/lima/releases/tag/v2.2.1) и сверяйте checksums. Не запускайте шаблон в чужой существующей VM. Сначала задайте новый LIMA_HOME в отдельном каталоге и создайте новую машину:

```bash
export LIMA_HOME="$PWD/.local/lima"
limactl start --name=mtc --tty=false lab/ubuntu-arm64.yaml
limactl shell --workdir=/home/devops mtc -- mkdir -p mtc-devops
# Передавайте только публичные исходники; не копируйте .local, .git или VM.
limactl copy -r config scripts charts manifests values dashboards images Makefile mtc:/home/devops/mtc-devops/
limactl shell --workdir=/home/devops/mtc-devops mtc -- sudo bash scripts/bootstrap.sh --dedicated-host
limactl shell --workdir=/home/devops/mtc-devops mtc -- make deploy
limactl shell --workdir=/home/devops/mtc-devops mtc -- make verify
```

Запрос с Mac: `curl -H 'Host: demo.mtc.test' http://127.0.0.1:18080/`. Для HTTPS копируйте только публичный сертификат `server.crt` (не private key) и используйте `--resolve demo.mtc.test:18443:127.0.0.1 --cacert server.crt`.

Ресурсы VM: 4 CPU, 8 GiB RAM, диск 24 GiB; фактический файл диска растёт по мере записи. Для остановки созданного стенда: `limactl stop mtc`. Остановка сохраняет данные; удаление VM не требуется. Перед проверкой второго стенда на 16 GiB Mac первый был остановлен, чтобы одновременно работала только одна VM.
