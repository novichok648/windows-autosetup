# Подготовка носителя и установка в лаборатории

## Комплект WinPE

Нужны Windows ADK с Deployment Tools и совместимое дополнение WinPE, официальный русский ISO Windows 11 x64, опубликованный SHA‑256 и отдельная папка NTFS с 20 ГиБ свободного места. Используйте актуальный ADK и доверенный загрузчик. Secure Boot и TPM остаются включёнными. [Microsoft ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) · [Официальный ISO](https://www.microsoft.com/software-download/windows11)

В повышенном Windows PowerShell определите индекс `Professional` командой DISM `/Get-WimInfo` на `sources\install.wim` или `sources\install.esd`. Отсоедините ISO после просмотра и выполните команду из корня проекта. Скрипт сверит исходный SHA‑256, экспортирует редакцию, разобьёт WIM, добавит компоненты в копию WinPE и создаст манифест. [DISM](https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14?view=windows-11)

```powershell
.\scripts\Build-WinPE.ps1 -WindowsIso C:\Lab\Windows11-ru-x64.iso -IsoSha256 $MicrosoftPublishedSha256 -ProIndex $ProIndex -Destination C:\Lab\AutoSetupMedia
```

## Флешка

Используйте выделенную флешку с существующим разделом FAT32. В «Установка Windows» выберите «Скопировать WinPE на USB», укажите папку `Media` и букву флешки. Копировщик проверяет тип шины, GUID тома, свободное место, лимит FAT32 и SHA‑256. При конфликте он останавливается. Приложение сохраняет существующую разметку.

Положите `WindowsAutoSetup.exe` в корень флешки. Рядом будет папка `AutoSetup` с `Apps`, `Apps/FACEIT`, `Drivers/INF`, `Drivers/EXE`, `NVIDIA`, `Config`, `DevTools`, `Private`, `Logs` и `Recovery`. Установщики добавляются в интерфейсе или через профиль JSON. Большие образы разделены на SWM. Для лабораторной очистки версия требует отдельный ISO виртуального DVD. [WinPE и FAT32](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe--use-a-single-usb-key-for-winpe-and-a-wim-file---wim?view=windows-11)

## Отдельная Hyper-V VM

В повышенном Windows PowerShell вызовите `scripts/New-TestVm.ps1 -OfficialIso ... -LabDirectory ...`. Скрипт создаёт новую Gen2 VM с уникальным именем, новым VHDX на 96 ГиБ, Secure Boot и виртуальным TPM. Установите исходную Windows с официального ISO. Для проверки сохранности второго диска добавьте отдельный VHDX с контрольным файлом. Используйте только виртуальные диски.

1. Передайте папку `Media` и портативный EXE в лабораторию. Для обмена планом подойдёт отдельная сетевая папка, доступная гостю и хосту. Храните `Media` вне целевого тома.
2. В госте настройте профиль и нажмите «Подготовить план тестовой установки». Сверьте модель, серийный номер, GUID, размер и разделы. Подтвердите серийным номером. Запишите появившийся код отдельно от носителя.
3. На хосте выполните `scripts/New-LabIso.ps1 -Bundle ... -Destination ... -ApprovalCode ...`. В ISO попадут файлы, перечисленные в манифестах. Хранилище `Private` остаётся на флешке.
4. Подключите ISO к виртуальному DVD именно этой VM и загрузитесь через UEFI. В WinPE введите код плана, проверьте реквизиты и введите `ERASE <GPT GUID>` для лабораторного диска.
5. WinPE повторно сопоставит диск, сверит образ, разметит EFI, MSR, Windows и Recovery, установит образ и зарегистрирует WinRE. Файлы загрузчика записываются на ESP целевого диска. [Разметка UEFI/GPT](https://learn.microsoft.com/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions?view=windows-11) · [BCDBoot](https://learn.microsoft.com/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di?view=windows-11)
6. При сообщении об успехе извлеките ISO и перезапустите VM. При необходимости выберите виртуальный диск в UEFI. Завершите оставшиеся экраны OOBE и войдите в локальную учётную запись. Файл ответов задаёт русский интерфейс, английскую и русскую раскладки, часовой пояс и локального администратора `a` без пароля. [Автоматизация OOBE](https://learn.microsoft.com/windows-hardware/manufacture/desktop/automate-oobe?view=windows-11)

Номер диска используется после повторного сопоставления, непосредственно перед DiskPart. Загружайте только WinPE, собранный вами из доверенного ADK и исходников. Для экспериментов используйте копию выключенного лабораторного VHDX или контрольную точку VM.
