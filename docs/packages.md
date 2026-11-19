# Программы, драйверы и инструменты

| Раздел | Папка | Форматы |
| --- | --- | --- |
| Программы | `Apps` | EXE, MSI |
| FACEIT | `Apps/FACEIT` | EXE, MSI |
| Драйверы | `Drivers` | INF, EXE, MSI |
| Рабочее окружение | `DevTools/Installers` | EXE, MSI |

1. Получите установщик у производителя. Для EXE задайте документированные параметры тихой установки. MSI получает `/qn /norestart`. Настройте установщик так, чтобы перезапуск контролировало приложение.
2. Укажите уникальный ID, проверяемый файл и минимальную версию. Префиксы `PF/`, `PF86/` и `WIN/` означают Program Files, Program Files (x86) и папку Windows. Пример для драйвера — `WIN/System32/drivers/vendor.sys`.
3. Сохраните профиль. Кнопки «Выше» и «Ниже» меняют очередь внутри группы. Удаление записи из профиля сохраняет файл установщика.
4. Для INF скопируйте полный пакет в отдельную подпапку `Drivers`. Приложение рассчитает хеши INF, CAT, SYS и прочих файлов. Windows проверяет подпись каталога при добавлении через PnPUtil. [PnPUtil](https://learn.microsoft.com/windows-hardware/drivers/devtest/pnputil-command-syntax)

EXE и MSI с неподтверждённой Authenticode-подписью отклоняются. SHA‑256 фиксирует выбранный файл. Агент копирует установщики в защищённую папку, проверяет хеши и сверяет установленную версию. Для FACEIT дополнительно нужны служба `FACEITService`, Secure Boot, готовый TPM и завершённый Windows Update.

Драйверы чипсета и LAN добавляются по модели платы, показанной в интерфейсе. Выберите версию для Windows 11 на официальной странице поддержки. Windows Update ищет применимые стандартные обновления и драйверы через WUA. [Windows Update Agent API](https://learn.microsoft.com/windows/win32/api/_wua/)

## Рабочее окружение

Кнопка системной установки применяет выбранные пакеты WinGet и настройки WSL2. Требуется Microsoft App Installer. Для Ubuntu отметьте WSL2 и после установки впервые откройте Ubuntu, чтобы создать Linux-пользователя. Для Docker Desktop в гостевой VM нужны расширения виртуализации. [WinGet](https://learn.microsoft.com/windows/package-manager/winget/) · [WSL](https://learn.microsoft.com/windows/wsl/install)

После установки Node.js LTS отдельная кнопка устанавливает выбранные Codex CLI, Paperclip и Playwright с правами текущего пользователя. Для Playwright добавляется Chromium. Папка — `%LOCALAPPDATA%\WindowsAutoSetup\DevTools`. Ищите команды в `node_modules\.bin`. Вход в Codex, первый запуск Paperclip и перенос рабочего состояния выполняются отдельно. [Codex CLI](https://github.com/openai/codex) · [Paperclip](https://github.com/paperclipai/paperclip/blob/master/docs/start/quickstart.md) · [Playwright](https://playwright.dev/docs/library)
