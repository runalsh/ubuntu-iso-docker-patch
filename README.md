# Ubuntu ISO Docker Image Patch

Автоматизированная сборка чистых, оптимизированных Docker-образов Ubuntu с полной поддержкой systemd (PID 1) напрямую из официальных установочных ISO-образов.

## Особенности
- **Сборка из оригинальных ISO**: Извлечение чистого окружения без сторонних модификаций.
- **Полноценный systemd (PID 1)**: Контейнеры запускаются через `/sbin/init` с поддержкой сервисов, таймеров и сокетов.
- **Вырезание аппаратного мусора**: Удаление ядер хоста (`/boot/vmlinuz*`), модулей ядра (`/lib/modules/*`), прошивок железа (`/lib/firmware/*`, `linux-firmware`), snapd, лишних локалей и man-страниц.
- **Чистые теги версий**: Теги формируются строго по версии ОС и патч-версии (`24.04.5`, `24.04`, `latest`), без служебных суффиксов.
- **Два пресета**:
  - `server` (по умолчанию): Base tools (mc, vim, bash-completion, p7zip, curl, wget, rsync, sudo, locales, iproute2, net-tools) + OpenSSH-сервер с автозапуском.
  - `minimal`: Ультралегковесная базовая система с systemd (PID 1).
- **Поддержка реестров**: Docker Hub (`runalsh/ubuntu-iso-patch`) и GHCR (`ghcr.io/runalsh/ubuntu-iso-patch`).
- **Авто-скип**: Пропуск скачивания и сборки при наличии тегов в реестрах.

## Быстрый старт

### Сборка через CLI:
```bash
# Сборка server-версии (по умолчанию) для релиза 24.04.5
./build.sh --preset server 24.04.5

# Сборка minimal-версии
./build.sh --preset minimal 24.04.5

# Сборка локального ISO файла
./build.sh /path/to/ubuntu-24.04.5-live-server-amd64.iso

# Принудительная пересборка с пушем в реестры
./build.sh --no-check-exists --push-dockerhub --push-ghcr 24.04.5
```

## Список релизов
Релизы задаются в файле `releases.txt`:
```text
24.04.5 https://releases.ubuntu.com/noble/ubuntu-24.04.5-live-server-amd64.iso
```
