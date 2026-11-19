# Сборка и архитектура

Нужны Windows 11 x64, .NET SDK версии из `global.json` и Windows PowerShell 5.1. ADK и Hyper-V нужны для лабораторной сборки WinPE и сквозных тестов.

```powershell
.\scripts\Build-Release.ps1
.\scripts\Test-ReleaseContent.ps1
```

Для распакованного SDK передайте `-Dotnet C:\path\to\dotnet.exe`. Сборка проверяет версию SDK, запускает тесты, публикует self-contained EXE, копирует лицензии и создаёт ZIP и SHA‑256. EXE не подписан Authenticode. SDK и целевая архитектура закреплены. ZIP содержит метки времени файлов.

| Модуль | Ответственность |
| --- | --- |
| `src/WindowsAutoSetup` | WinForms, профиль, каталог, USB, план установки, AES-GCM, диагностика |
| `deployment/DiskSafety.psm1` | Инвентаризация и сопоставление дисков |
| `deployment/WinPE.ps1` | ISO, план, лабораторная разметка, DISM, WinRE, загрузчик и файл ответов |
| `deployment/Worker.ps1` | Хеши, подписи, очередь, обновления, настройки, планировщик и журнал |
| `deployment/UserTools.ps1` | Пользовательские пакеты npm |
| `tests` | Проверки WinForms/.NET, синтетических дисков и ответов WUA в Windows PowerShell |

Порядок постустановки задан в агенте. Редактирование профиля позволяет переставлять пакеты внутри группы. Агент выполняет один этап за раз.
