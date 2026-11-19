using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsAutoSetup;

internal sealed partial class MainForm : Form
{
    private static readonly Color Background = Color.FromArgb(14, 21, 31);
    private static readonly Color PanelColor = Color.FromArgb(26, 37, 53);
    private static readonly Color Accent = Color.FromArgb(47, 103, 222);
    private static readonly Color Secondary = Color.FromArgb(166, 184, 208);
    private readonly FlowLayoutPanel navigation = new();
    private readonly FlowLayoutPanel body = new();
    private readonly Label heading = new();
    private readonly Label status = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 2500 };
    private readonly Dictionary<string, Button> links = [];
    private string section = "Главная";
    private string data = Path.Combine(AppContext.BaseDirectory, "AutoSetup");
    private Profile profile = new("a", TimeZoneInfo.Local.Id, false, true, [], []);
    private Machine? machine;
    private bool busy;
    private int accountIndex;
    private List<Account>? accounts;
    private TextBox? log;
    private ProgressBar? progress;
    private Label? progressCaption;

    internal MainForm(bool inventoryOnShow = true)
    {
        Text = "Windows AutoSetup";
        Font = new Font("Segoe UI", 11);
        ForeColor = Color.WhiteSmoke;
        BackColor = Background;
        MinimumSize = new Size(960, 675);
        ClientSize = new Size(1180, 780);
        StartPosition = FormStartPosition.CenterScreen;
        if (string.Equals(AppContext.BaseDirectory.TrimEnd('\\'), Storage.Installed, StringComparison.OrdinalIgnoreCase))
            data = Path.Combine(Storage.Local, "AutoSetup");
        try { LoadProfile(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        {
            data = Path.Combine(Storage.Local, "AutoSetup");
        }

        var frame = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, BackColor = Background };
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 242));
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        frame.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        Controls.Add(frame);
        navigation.Dock = DockStyle.Fill;
        navigation.BackColor = Color.FromArgb(19, 28, 40);
        navigation.Padding = new Padding(14, 22, 14, 12);
        navigation.FlowDirection = FlowDirection.TopDown;
        navigation.WrapContents = false;
        navigation.AutoScroll = true;
        frame.Controls.Add(navigation, 0, 0);
        navigation.Controls.Add(new Label {
            Text = "Windows AutoSetup", Font = new Font("Segoe UI Semibold", 16),
            AutoSize = true, Margin = new Padding(3, 0, 0, 21)
        });
        foreach (var name in new[] { "Главная", "Установка Windows", "Программы", "Драйверы", "Настройки Windows",
                     "NVIDIA", "Интернет и сеть", "Аккаунты", "Рабочее окружение", "Журнал установки", "Настройки программы" })
        {
            var link = ButtonFor(name, () => Navigate(name));
            link.TextAlign = ContentAlignment.MiddleLeft;
            link.Width = 207;
            navigation.Controls.Add(link);
            links.Add(name, link);
        }
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Padding = new Padding(28, 20, 24, 0) };
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 55));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        frame.Controls.Add(main, 1, 0);
        heading.Font = new Font("Segoe UI Semibold", 24);
        heading.Dock = DockStyle.Fill;
        main.Controls.Add(heading, 0, 0);
        body.Dock = DockStyle.Fill;
        body.AutoScroll = true;
        body.WrapContents = false;
        body.FlowDirection = FlowDirection.TopDown;
        main.Controls.Add(body, 0, 1);
        status.Dock = DockStyle.Fill;
        status.ForeColor = Secondary;
        status.Padding = new Padding(8, 0, 0, 0);
        status.TextAlign = ContentAlignment.MiddleLeft;
        status.Text = "Версия 1.0 Preview";
        frame.Controls.Add(status, 1, 1);
        timer.Tick += (_, _) => ReadProgress();
        timer.Start();
        FormClosed += (_, _) => timer.Dispose();
        Navigate("Главная");
        if (inventoryOnShow)
            Shown += async (_, _) => await Work(async () => { machine = await Media.Inventory(); Navigate(section); });
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var dark = 1;
        DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    private void LoadProfile()
    {
        var path = Media.SafePath(data, "Config/profile.json");
        if (File.Exists(path))
            profile = ReadProfile(path);
    }

    private static Profile ReadProfile(string file)
    {
        var value = Storage.Read<Profile>(file);
        if (value.Packages is null || value.Dev is null || value.User is null || value.TimeZone is null ||
            value.Packages.Count > 100 || value.Dev.Count > 20 ||
            value.Packages.Any(x => x is null || x.Id is null || x.Kind is null || x.Area is null || x.File is null ||
                x.Sha256 is null || x.Arguments is null || x.DetectPath is null || x.MinVersion is null))
            throw new InvalidDataException("Некорректный профиль.");
        return value;
    }

    private string SaveProfile()
    {
        Media.MakeLayout(data);
        var path = Media.SafePath(data, "Config/profile.json");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(profile, Storage.Json);
        Storage.Replace(path, bytes);
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
    }

    private async Task Work(Func<Task> operation)
    {
        if (busy) return;
        busy = true;
        UseWaitCursor = true;
        status.Text = "Операция выполняется…";
        try
        {
            await operation();
            status.Text = "Готово";
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            status.Text = "Операция остановлена";
            MessageBox.Show(this, ex is InvalidOperationException or InvalidDataException or ArgumentException
                ? ex.Message : "Проверьте права доступа, формат файла и наличие нужных компонентов.",
                Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            UseWaitCursor = false;
            busy = false;
        }
    }

    private void Navigate(string name)
    {
        section = name;
        heading.Text = name;
        foreach (var item in links)
            item.Value.BackColor = item.Key == name ? Accent : PanelColor;
        log = null;
        progress = null;
        progressCaption = null;
        body.SuspendLayout();
        foreach (Control item in body.Controls.Cast<Control>().ToArray())
            item.Dispose();
        switch (name)
        {
            case "Главная":
                Copy("Автоматическая переустановка и настройка Windows 11", prominent: true);
                Copy(machine is null ? "Оборудование пока не определено" : machine.Board + "\r\n" + machine.Model);
                Copy("Предварительная версия. Чистая установка доступна только для испытаний в изолированной Hyper-V VM.");
                Action("Установка Windows", () => Navigate("Установка Windows"), primary: true);
                Action("Рабочее окружение", () => Navigate("Рабочее окружение"));
                AddProgress();
                break;
            case "Установка Windows":
                Copy(machine?.Target is { } target ? Media.TargetText(target) : "Системный диск не определён.");
                Action("Обновить сведения", async () => await Work(async () => { machine = await Media.Inventory(); Navigate(section); }));
                Action("Скопировать WinPE на USB", async () => await Work(PrepareUsb));
                Action("Подготовить план тестовой установки", async () => await Work(Stage), primary: true);
                Copy("Загрузите тестовую VM с подготовленного WinPE через меню UEFI. Введите код плана и подтвердите очистку виртуального диска в WinPE.");
                break;
            case "Программы":
                PackagePage("App", "Faceit");
                break;
            case "Драйверы":
                Copy(machine?.Board ?? "Модель материнской платы пока не определена.");
                Copy("Добавьте локальные драйверы чипсета, LAN и других устройств. Драйверы из каталога Windows Update проверяются следующим этапом.");
                PackagePage("Driver");
                break;
            case "Настройки Windows":
                SettingsPage();
                break;
            case "NVIDIA":
                Copy(machine is null ? "Инвентаризация ещё не выполнена." : string.Join("\r\n",
                    machine.GPU.Select(g => $"{g.Name} · {g.Version} · {g.Hz?.ToString() ?? "?"} Гц")));
                Copy("В панели NVIDIA выберите полноэкранное масштабирование на ГП и разрешите замещение параметров игр. В параметрах дисплея Windows выберите 240 Гц, если режим доступен.");
                Action("Параметры дисплея", () => Open("ms-settings:display-advanced"));
                break;
            case "Интернет и сеть":
                Copy("Проверяйте Ethernet после установки LAN-драйвера. Настройки сетевого адаптера сохраняются. Профиль VLESS можно хранить в разделе «Аккаунты» и импортировать в Happ вручную.");
                Action("Состояние сети", () => Open("ms-settings:network-status"));
                Action("Официальный репозиторий Zapret", () => Open("https://github.com/Flowseal/zapret-discord-youtube"));
                break;
            case "Аккаунты":
                AccountsPage();
                break;
            case "Рабочее окружение":
                DevPage();
                break;
            case "Журнал установки":
                JournalPage();
                break;
            case "Настройки программы":
                Copy(data);
                Action("Выбрать папку AutoSetup", async () => await Work(() =>
                {
                    var path = Folder("Выберите папку AutoSetup");
                    if (path is not null)
                    {
                        var selected = Media.SafePath(path, "Config/profile.json");
                        var next = File.Exists(selected) ? ReadProfile(selected) : new Profile("a", TimeZoneInfo.Local.Id, false, true, [], []);
                        Media.MakeLayout(path);
                        profile = next;
                        data = path;
                        accounts = null;
                        accountIndex = 0;
                        Navigate(section);
                    }
                    return Task.CompletedTask;
                }));
                Action("Загрузить профиль JSON", async () => await Work(() =>
                {
                    using var picker = new OpenFileDialog { Filter = "Профиль JSON|*.json" };
                    if (picker.ShowDialog(this) == DialogResult.OK) profile = ReadProfile(picker.FileName);
                    return Task.CompletedTask;
                }));
                Action("Сохранить профиль", async () => await Work(() => { SaveProfile(); return Task.CompletedTask; }));
                break;
        }
        ReadProgress();
        body.ResumeLayout();
    }

    private async Task PrepareUsb()
    {
        var detected = await Media.Inventory();
        if (detected.Usb.Length == 0) throw new InvalidOperationException("USB-раздел FAT32 не обнаружен.");
        var bundle = Folder("Выберите папку комплекта WinPE");
        if (bundle is null) return;
        var letter = Prompt("Подготовка USB", "Буква USB-раздела FAT32", detected.Usb.First().Letter);
        if (letter is null) return;
        await Media.PrepareUsb(bundle, letter.TrimEnd(':').ToUpperInvariant());
        ShowNotice("Файлы WinPE скопированы и проверены по SHA-256.");
    }

    private async Task Stage()
    {
        var detected = await Media.Inventory();
        Media.AssertLab(detected);
        var bundle = Folder("Выберите папку тестового комплекта WinPE");
        if (bundle is null) return;
        if (string.Equals(Path.GetPathRoot(bundle), Path.GetPathRoot(Environment.SystemDirectory), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Храните комплект на отдельном носителе или сетевой папке вне системного диска VM.");
        var confirmation = Prompt("План полной переустановки", "Будут удалены все разделы целевого виртуального диска.\r\n" +
            Media.TargetText(detected.Target!) + "\r\nДля утверждения введите серийный номер диска.", "");
        if (confirmation != detected.Target!.Serial) return;
        var currentData = data;
        var snapshot = JsonSerializer.Deserialize<Profile>(JsonSerializer.SerializeToUtf8Bytes(profile, Storage.Json), Storage.Json)!;
        var code = await Task.Run(() => Media.Stage(currentData, bundle, detected, snapshot));
        Prompt("План подготовлен", "Запишите этот код отдельно. Он понадобится при запуске WinPE.", code, readOnly: true);
    }

    private void SettingsPage()
    {
        Copy("После чистой установки применяются тёмная тема, выравнивание панели задач слева, настройки мыши, Xbox, конфиденциальности и электропитания.");
        Action("Локальный пользователь · " + profile.User, () =>
        {
            var value = Prompt("Локальная учётная запись", "Имя администратора Windows", profile.User);
            if (value is not null) { profile = profile with { User = value }; Navigate(section); }
        });
        Action("Часовой пояс · " + profile.TimeZone, () =>
        {
            var value = Prompt("Часовой пояс", "Идентификатор Windows. Текущее значение берётся из исходной системы.", profile.TimeZone);
            if (value is not null) { profile = profile with { TimeZone = value }; Navigate(section); }
        });
        Check("Отключать проверенные записи автозапуска Steam, Discord и Telegram", profile.Startup,
            enabled => profile = profile with { Startup = enabled });
        Check("Автоматически перезагружать по требованию", profile.Reboot, enabled => profile = profile with { Reboot = enabled });
        Action("Сохранить профиль", async () => await Work(() => { SaveProfile(); return Task.CompletedTask; }));
    }

    private void AddProgress()
    {
        progressCaption = Copy("Нет активного процесса");
        progress = new ProgressBar { Width = 600, Height = 14, Margin = new Padding(0, 0, 0, 14) };
        body.Controls.Add(progress);
    }

    private void JournalPage()
    {
        AddProgress();
        log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Width = 650,
            Height = 310, Font = new Font("Consolas", 10), BackColor = PanelColor, ForeColor = ForeColor };
        body.Controls.Add(log);
        Action("Повторить остановленный этап", () => RunInstalled("Retry"));
        Action("Восстановить записи автозапуска", () => RunInstalled("Restore"));
        var seed = Path.Combine(Storage.Installed, "Seed");
        var post = Path.Combine(seed, "Config", "profile.json");
        if (File.Exists(post) && !File.Exists(Path.Combine(Storage.Installed, "state.json")))
        {
            Action("Запустить постустановку", async () => await Work(async () =>
            {
                using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                await Program.Elevated(new { Action = "Start", Source = seed, Mode = "Post",
                    ProfileHash = Storage.Hash(post), Sid = identity.User!.Value });
            }));
        }
        Action("Экспорт диагностики", async () => await Work(() =>
        {
            using var save = new SaveFileDialog { Filter = "Текстовый отчёт|*.txt", FileName = "WindowsAutoSetup-report.txt" };
            if (save.ShowDialog(this) == DialogResult.OK)
                Storage.Replace(save.FileName, System.Text.Encoding.UTF8.GetBytes(
                    $"Windows AutoSetup {typeof(Program).Assembly.GetName().Version}\r\n{progressCaption!.Text}\r\n{log!.Text}"));
            return Task.CompletedTask;
        }));
    }

    private async void RunInstalled(string argument) => await Work(async () =>
    {
        if (!File.Exists(Media.SafePath(Storage.Installed, "Worker.ps1")))
            throw new InvalidOperationException("Локальный агент ещё не установлен.");
        await Program.Elevated(new { Action = argument });
    });

    private void ReadProgress()
    {
        if (progress is null) return;
        try
        {
            var file = Path.Combine(Storage.Installed, "state.json");
            if (File.Exists(file))
            {
                using var state = JsonDocument.Parse(File.ReadAllBytes(file));
                var tasks = state.RootElement.GetProperty("Tasks").EnumerateArray().ToArray();
                var completed = tasks.Count(x => x.GetProperty("Status").GetString() is "Completed" or "Skipped");
                progress.Maximum = Math.Max(1, tasks.Length);
                progress.Value = completed;
                progressCaption!.Text = completed == tasks.Length
                    ? $"Завершено этапов {completed} из {tasks.Length}"
                    : $"{completed} из {tasks.Length} · {Describe(tasks.First(x => x.GetProperty("Status").GetString() is not ("Completed" or "Skipped")))}";
            }
            var journal = Path.Combine(Storage.Installed, "installation.log");
            if (log is not null && File.Exists(journal))
            {
                using var stream = new FileStream(journal, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(stream);
                log.Text = reader.ReadToEnd();
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
    }

    private static string Describe(JsonElement task)
    {
        var name = task.GetProperty("Name").GetString();
        var state = task.GetProperty("Status").GetString() switch
        {
            "WaitingForReboot" => "ожидает перезагрузки",
            "Running" => "выполняется",
            "Failed" => "ошибка",
            "Blocked" => "заблокирован",
            _ => "в очереди"
        };
        return name + " · " + state + " " + task.GetProperty("Code").GetString();
    }

    private string? Folder(string label)
    {
        using var picker = new FolderBrowserDialog { Description = label, UseDescriptionForTitle = true };
        return picker.ShowDialog(this) == DialogResult.OK ? picker.SelectedPath : null;
    }

    private void ShowNotice(string message) => MessageBox.Show(this, message, Text);

    private static Button ButtonFor(string text, Action action, bool primary = false)
    {
        var button = new Button { Text = text, Width = 340, Height = 39, FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Accent : PanelColor, ForeColor = Color.White, Cursor = Cursors.Hand,
            Padding = new Padding(8, 0, 8, 0), Margin = new Padding(0, 0, 0, 7) };
        button.FlatAppearance.BorderSize = 0;
        button.SizeChanged += (_, _) => Round(button);
        Round(button);
        button.Click += (_, _) => action();
        return button;
    }

    private static void Round(Control control)
    {
        using var path = new GraphicsPath();
        const int radius = 14;
        path.AddArc(0, 0, radius, radius, 180, 90);
        path.AddArc(control.Width - radius, 0, radius, radius, 270, 90);
        path.AddArc(control.Width - radius, control.Height - radius, radius, radius, 0, 90);
        path.AddArc(0, control.Height - radius, radius, radius, 90, 90);
        path.CloseFigure();
        var old = control.Region;
        control.Region = new Region(path);
        old?.Dispose();
    }

    private void Action(string title, Action action, bool primary = false) => body.Controls.Add(ButtonFor(title, action, primary));

    private Label Copy(string text, bool prominent = false)
    {
        var label = new Label { Text = text, AutoSize = true, MaximumSize = new Size(660, 0),
            Margin = new Padding(0, 0, 0, 14), ForeColor = prominent ? ForeColor : Secondary,
            Font = prominent ? new Font("Segoe UI Semibold", 16) : Font };
        body.Controls.Add(label);
        return label;
    }

    private void Check(string title, bool selected, Action<bool> change)
    {
        var control = new CheckBox { Text = title, AutoSize = true, Checked = selected, Margin = new Padding(0, 0, 0, 9) };
        control.CheckedChanged += (_, _) => change(control.Checked);
        body.Controls.Add(control);
    }

    private string? Prompt(string title, string label, string value, bool secret = false, bool readOnly = false)
    {
        using var dialog = Dialog(title);
        var grid = DialogGrid(dialog);
        grid.Controls.Add(new Label { Text = label, AutoSize = true, MaximumSize = new Size(570, 0) });
        var entry = Entry(value, secret);
        entry.ReadOnly = readOnly;
        grid.Controls.Add(entry);
        AddOk(dialog, grid, readOnly ? "Закрыть" : "Подтвердить");
        return dialog.ShowDialog(this) == DialogResult.OK ? entry.Text : null;
    }

    private static Form Dialog(string title) => new()
    {
        Text = title, StartPosition = FormStartPosition.CenterParent, AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink, BackColor = Background, ForeColor = Color.WhiteSmoke,
        Font = new Font("Segoe UI", 11), FormBorderStyle = FormBorderStyle.FixedDialog,
        MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false
    };

    private static FlowLayoutPanel DialogGrid(Form dialog)
    {
        var grid = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(16),
            FlowDirection = FlowDirection.TopDown, WrapContents = false };
        dialog.Controls.Add(grid);
        return grid;
    }

    private static TextBox Entry(string value, bool secret = false) => new()
    {
        Text = value, UseSystemPasswordChar = secret, Width = 560, BackColor = PanelColor, ForeColor = Color.WhiteSmoke
    };

    private static void AddOk(Form dialog, FlowLayoutPanel grid, string title)
    {
        var ok = ButtonFor(title, () => dialog.DialogResult = DialogResult.OK, primary: true);
        grid.Controls.Add(ok);
        dialog.AcceptButton = ok;
    }

    private static void Open(string value)
    {
        try { using var process = Process.Start(new ProcessStartInfo(value) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { MessageBox.Show("Не удалось открыть страницу или настройки."); }
    }
}
