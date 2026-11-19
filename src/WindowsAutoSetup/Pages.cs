using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace WindowsAutoSetup;

internal sealed partial class MainForm
{
    private static readonly (string Id, string Name)[] DevTools =
    [
        ("Git.Git", "Git"),
        ("WSL", "WSL2"),
        ("Canonical.Ubuntu.2404", "Ubuntu 24.04"),
        ("OpenJS.NodeJS.LTS", "Node.js LTS и npm"),
        ("Python.Python.3.13", "Python 3.13 и pip"),
        ("Docker.DockerDesktop", "Docker Desktop"),
        ("Gyan.FFmpeg", "FFmpeg"),
        ("yt-dlp.yt-dlp", "yt-dlp")
    ];

    private void DevPage()
    {
        Copy(machine?.Lab == true
            ? "Обнаружена виртуальная машина Hyper-V."
            : "Виртуальная машина Hyper-V не обнаружена. Установите только инструменты, нужные на этом компьютере.");
        foreach (var tool in DevTools)
            Check(tool.Name, profile.Dev.Contains(tool.Id), enabled =>
            {
                profile.Dev.Remove(tool.Id);
                if (enabled) profile.Dev.Add(tool.Id);
                profile = profile with { Dev = DevTools.Select(x => x.Id).Where(profile.Dev.Contains).ToList() };
            });
        PackagePage("Dev");
        Action("Установить рабочее окружение", async () => await Work(async () =>
        {
            if (profile.Dev.Count == 0 && !profile.Packages.Any(x => x.Area == "Dev"))
                throw new InvalidOperationException("Выберите инструменты или добавьте локальный установщик.");
            if (profile.Dev.Contains("Canonical.Ubuntu.2404") && !profile.Dev.Contains("WSL"))
                throw new InvalidOperationException("Для Ubuntu выберите WSL2.");
            var description = string.Join(", ", DevTools.Where(x => profile.Dev.Contains(x.Id)).Select(x => x.Name)
                .Concat(profile.Packages.Where(x => x.Area == "Dev").Select(x => x.Id)));
            var reboot = profile.Reboot ? " Разрешена автоматическая перезагрузка." : "";
            if (MessageBox.Show(this, $"Установить {description}? Будут приняты соглашения выбранных пакетов.{reboot}",
                    Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                return;
            var profileHash = SaveProfile();
            var exe = Environment.ProcessPath!;
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            await Program.Elevated(new { Action = "Start", Source = data, Mode = "Dev",
                ProfileHash = profileHash, Exe = exe, ExeHash = Storage.Hash(exe), Sid = identity.User!.Value },
                install: true, onStart: () => Navigate("Журнал установки"));
        }), primary: true);
        Copy("Пользовательские инструменты Node.js", prominent: true);
        foreach (var (id, label) in new[] { ("@openai/codex", "OpenAI Codex CLI"), ("paperclipai", "Paperclip"),
                     ("playwright", "Playwright и Chromium") })
            Check(label, profile.NodeTools?.Contains(id) == true, enabled =>
            {
                var selected = profile.NodeTools ?? [];
                selected.Remove(id);
                if (enabled) selected.Add(id);
                profile = profile with { NodeTools = selected };
            });
        Action("Установить выбранные инструменты Node.js", async () => await Work(async () =>
        {
            var selected = profile.NodeTools;
            if (selected is null || selected.Count == 0)
                throw new InvalidOperationException("Выберите инструменты Node.js.");
            if (MessageBox.Show(this, "Установить выбранные пакеты из официального реестра npm в папку текущего пользователя?",
                    Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            var serialized = Convert.ToBase64String(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(selected));
            var input = "$selected= @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + serialized +
                        "')) | ConvertFrom-Json); " + Program.Resource("UserTools");
            await Program.Shell(input);
            ShowNotice("Инструменты Node.js установлены и проверены. Инструкции первого запуска доступны в документации проекта.");
        }));
        Action("Папка инструментов Node.js", () =>
        {
            var target = Path.Combine(Storage.Local, "DevTools");
            if (Directory.Exists(target)) Open(target);
            else ShowNotice("Папка появится при установке инструментов Node.js.");
        });
    }

    private void PackagePage(params string[] areas)
    {
        foreach (var area in areas)
        {
            var title = area switch { "App" => "Программы", "Faceit" => "FACEIT Anti-Cheat",
                "Driver" => "Драйверы", _ => "Локальные инструменты" };
            Copy(title, prominent: true);
            var packages = profile.Packages.Where(x => x.Area == area).ToList();
            if (packages.Count == 0) Copy("Установщики не добавлены.");
            else
            {
                var list = new ListBox { Width = 620, Height = Math.Min(200, 31 + packages.Count * 23),
                    BackColor = PanelColor, ForeColor = ForeColor, IntegralHeight = false };
                list.Items.AddRange(packages.Select(x => $"{x.Id}  ·  {x.Kind}  ·  {x.File}").Cast<object>().ToArray());
                list.SelectedIndex = 0;
                body.Controls.Add(list);
                var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 7, 0, 7) };
                body.Controls.Add(row);
                foreach (var (label, offset) in new[] { ("Выше", -1), ("Ниже", 1), ("Удалить", 0) })
                {
                    var button = ButtonFor(label, () =>
                    {
                        var selected = list.SelectedIndex;
                        if (selected < 0) return;
                        var index = profile.Packages.IndexOf(packages[selected]);
                        if (offset == 0) profile.Packages.RemoveAt(index);
                        else
                        {
                            if (selected + offset < 0 || selected + offset >= packages.Count) return;
                            var other = profile.Packages.IndexOf(packages[selected + offset]);
                            (profile.Packages[index], profile.Packages[other]) = (profile.Packages[other], profile.Packages[index]);
                        }
                        Navigate(section);
                    });
                    button.Width = 96;
                    button.Margin = new Padding(0, 0, 7, 0);
                    row.Controls.Add(button);
                }
            }
            Action("Добавить установщик · " + title, async () => await Work(() => AddPackage(area)));
        }
        Action("Сохранить профиль", async () => await Work(() => { SaveProfile(); return Task.CompletedTask; }));
    }

    private async Task AddPackage(string area)
    {
        var areaPath = area switch
        {
            "App" => "Apps", "Driver" => "Drivers", "Faceit" => "Apps/FACEIT", _ => "DevTools/Installers"
        };
        Media.MakeLayout(data);
        var folder = Media.SafePath(data, areaPath);
        using var picker = new OpenFileDialog { InitialDirectory = folder, Filter = area == "Driver"
            ? "Установщики и драйверы|*.exe;*.msi;*.inf" : "Установщики|*.exe;*.msi" };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        var source = picker.FileName;
        var kind = Path.GetExtension(source).TrimStart('.').ToUpperInvariant();
        if (kind is not ("EXE" or "MSI" or "INF") || (area != "Driver" && kind == "INF"))
            throw new InvalidDataException("Неподдерживаемый тип файла.");
        var inside = source.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase);
        if (kind == "INF" && !inside)
            throw new InvalidDataException("Поместите INF и файлы драйвера в отдельную подпапку Drivers перед добавлением.");
        var relative = inside ? Path.GetRelativePath(folder, source) : Path.GetFileName(source);
        if (area == "App" && relative.StartsWith("FACEIT\\", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Добавьте этот установщик в раздел FACEIT Anti-Cheat.");
        var destination = Media.SafePath(folder, relative);
        using var modal = Dialog("Профиль установщика");
        var grid = DialogGrid(modal);
        TextBox Field(string label, string value)
        {
            grid.Controls.Add(new Label { Text = label, AutoSize = true });
            var box = Entry(value);
            grid.Controls.Add(box);
            return box;
        }
        var id = Field("ID пакета", Regex.Replace(Path.GetFileNameWithoutExtension(source), "[^a-zA-Z0-9_-]", "-"));
        var args = Field("Параметры тихой установки из документации производителя", "");
        var detect = Field("Файл для проверки версии · PF/, PF86/ или WIN/", "");
        var version = Field("Минимальная версия файла", "1.0.0.0");
        AddOk(modal, grid, "Добавить");
        if (modal.ShowDialog(this) != DialogResult.OK) return;
        if (!Regex.IsMatch(id.Text, @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}\z") ||
            profile.Packages.Any(p => p.Id.Equals(id.Text, StringComparison.OrdinalIgnoreCase)) ||
            (kind == "EXE" && string.IsNullOrWhiteSpace(args.Text)) ||
            !Regex.IsMatch(detect.Text, @"\A(PF|PF86|WIN)/.+\z") || !Version.TryParse(version.Text, out _))
            throw new InvalidDataException("Проверьте ID, параметры, путь и версию.");
        var sidecars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var hash = await Task.Run(() =>
        {
            var digest = Storage.Hash(source);
            if (!inside)
            {
                if (!File.Exists(destination))
                    File.Copy(source, destination);
                if (Storage.Hash(destination) != digest)
                    throw new InvalidDataException("Файл с таким именем уже существует и отличается.");
            }
            if (kind == "INF")
            {
                var directory = Path.GetDirectoryName(source)!;
                if (directory.Equals(folder, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Поместите каждый INF-пакет в отдельную подпапку Drivers.");
                foreach (var file in Directory.EnumerateFiles(directory, "*", new EnumerationOptions {
                             RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }))
                {
                    if (!file.Equals(source, StringComparison.OrdinalIgnoreCase))
                        sidecars.Add(Path.GetRelativePath(folder, file), Storage.Hash(file));
                    if (sidecars.Count > 250)
                        throw new InvalidDataException("В папке драйвера слишком много файлов.");
                }
            }
            return digest;
        });
        profile.Packages.Add(new Package(id.Text, kind, area, relative, hash, args.Text, detect.Text,
            version.Text, area == "Faceit" ? "FACEITService" : null, sidecars));
        Navigate(section);
    }

    private static string? OfficialLogin(string service) => service.ToUpperInvariant() switch
    {
        "STEAM" => "https://store.steampowered.com/login/",
        "DISCORD" => "https://discord.com/login",
        "GOOGLE" => "https://accounts.google.com/",
        "TELEGRAM" => "https://web.telegram.org/",
        "FACEIT" => "https://www.faceit.com/",
        "HAPP" => "https://www.happ.su/",
        _ => null
    };

    private void AccountsPage()
    {
        var file = Media.SafePath(data, "Private/accounts.vault");
        Copy("Хранилище аккаунтов", prominent: true);
        Copy("Выберите папку AutoSetup на USB в настройках программы. Для открытия хранилища после переустановки понадобится мастер-пароль.");
        if (accounts is null)
        {
            Action(File.Exists(file) ? "Открыть хранилище" : "Создать хранилище", async () => await Work(async () =>
            {
                var password = Prompt("Хранилище", "Мастер-пароль", "", secret: true);
                if (password is null) return;
                try
                {
                    if (File.Exists(file))
                        accounts = await Task.Run(() => Vault.Open(file, password));
                    else
                    {
                        if (Prompt("Хранилище", "Повторите мастер-пароль", "", secret: true) != password) return;
                        await Task.Run(() => Vault.Save(file, password, []));
                        accounts = [];
                    }
                }
                catch (CryptographicException) { throw new InvalidDataException("Пароль неверен или хранилище повреждено."); }
                accountIndex = 0;
                Navigate(section);
            }), primary: true);
            return;
        }
        var unlocked = accounts;
        Action("Добавить аккаунт или профиль Happ", async () => await Work(async () =>
        {
            var service = Prompt("Добавить запись", "Сервис, например Steam, Discord, Google, Telegram или Happ", "");
            if (string.IsNullOrWhiteSpace(service) || service.Length > 48) return;
            var login = Prompt("Добавить запись", "Логин или название профиля", "");
            if (login is null) return;
            var secret = Prompt("Добавить запись", "Пароль или ссылка VLESS", "", secret: true);
            if (secret is null) return;
            if (service.Equals("Happ", StringComparison.OrdinalIgnoreCase) && !secret.StartsWith("vless://", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Для Happ введите ссылку VLESS.");
            await SaveAccount(file, [.. unlocked, new Account(service, login, secret)]);
        }));
        Action("Заблокировать хранилище", () => { accounts = null; accountIndex = 0; Navigate(section); });
        if (accountIndex >= unlocked.Count)
        {
            Copy(unlocked.Count == 0 ? "Добавьте первую запись." : "Последовательный вход завершён.");
            if (unlocked.Count > 0) Action("Начать вход сначала", () => { accountIndex = 0; Navigate(section); });
            return;
        }
        var account = unlocked[accountIndex];
        Copy($"{accountIndex + 1} из {unlocked.Count} · {account.Service}", prominent: true);
        var url = OfficialLogin(account.Service);
        if (url is not null)
            Action("Открыть страницу сервиса", () => Open(url));
        Action("Показать логин", () => Prompt("Логин", "Используйте на странице сервиса", account.Login, readOnly: true));
        Action("Показать пароль или ссылку", () => Prompt("Секрет", "Используйте только в приложении или на странице сервиса", account.Secret, readOnly: true));
        Action("Вход выполнен — далее", () => { accountIndex++; Navigate(section); }, primary: true);
        Action("Пропустить аккаунт", () => { accountIndex++; Navigate(section); });
        Action("Удалить текущую запись", async () => await Work(async () =>
        {
            if (MessageBox.Show(this, "Удалить запись из зашифрованного хранилища?", Text, MessageBoxButtons.OKCancel) != DialogResult.OK) return;
            var next = unlocked.ToList();
            next.RemoveAt(accountIndex);
            await SaveAccount(file, next);
        }));
    }

    private async Task SaveAccount(string file, List<Account> next)
    {
        var password = Prompt("Сохранить хранилище", "Введите мастер-пароль", "", secret: true);
        if (password is null) return;
        try
        {
            await Task.Run(() => { Vault.Open(file, password); Vault.Save(file, password, next); });
            accounts = next;
            Navigate(section);
        }
        catch (CryptographicException) { throw new InvalidDataException("Пароль неверен или хранилище повреждено."); }
    }
}
