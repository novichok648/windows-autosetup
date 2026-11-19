using System.Text.Json;
using System.Text.RegularExpressions;

namespace WindowsAutoSetup;

internal sealed record Disk(int Number, string Guid, string Serial, string Model, ulong Size, string Bus,
    string UniqueId, string Style, string Layout);
internal sealed record Usb(string Letter, ulong Free, string VolumeId);
internal sealed record Gpu(string Name, string Version, int? Hz);
internal sealed record Machine(string Board, string Model, bool Lab, Disk? Target, bool StorageError, string TimeZone,
    string Firmware, Gpu[] GPU, Usb[] Usb);
internal sealed record Plan(int Schema, Disk Target, string User, string TimeZone, string BootSha256,
    Dictionary<string, string> Files);

internal static class Media
{
    internal static readonly string[] Layout = ["Apps", "Apps/FACEIT", "Drivers/INF", "Drivers/EXE", "NVIDIA",
        "Config", "DevTools/Installers", "DevTools/Scripts", "Private", "Logs", "Recovery"];

    internal static async Task<Machine> Inventory()
    {
        var module = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(Program.Resource("DiskSafety")));
        var script = "$code=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + module +
                     "')); New-Module -ScriptBlock ([scriptblock]::Create($code)) | Import-Module; " +
                     Program.Resource("Inventory");
        return JsonSerializer.Deserialize<Machine>(await Program.Shell(script)) ??
               throw new InvalidOperationException("Сведения об оборудовании недоступны.");
    }

    internal static void MakeLayout(string data)
    {
        foreach (var area in Layout)
            Directory.CreateDirectory(SafePath(data, area));
    }

    internal static string SafePath(string root, string relative)
    {
        var parts = relative.Split(['/', '\\']);
        if (parts.Any(p => p.Length == 0 || p is "." or ".." || p.EndsWith(' ') || p.EndsWith('.') ||
                           p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
            throw new InvalidDataException("Недопустимый путь.");
        var path = Path.GetFullPath(Path.Combine(root, Path.Combine(parts)));
        for (var item = path; item is not null; item = Path.GetDirectoryName(item))
        {
            if ((File.Exists(item) || Directory.Exists(item)) && File.GetAttributes(item).HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidDataException("Точки повторной обработки запрещены.");
        }
        return path;
    }

    internal static string TargetText(Disk disk) =>
        $"{disk.Model} · {disk.Size / 1073741824d:N1} ГиБ · {disk.Bus}\r\nСерийный номер {disk.Serial}\r\n" +
        $"GPT GUID {disk.Guid}\r\nИдентификатор {disk.UniqueId}\r\nРазделы (смещение:размер:тип)\r\n{disk.Layout.Replace(";", "\r\n")}";

    internal static void AssertLab(Machine machine)
    {
        var disk = machine.Target;
        if (!machine.Lab || machine.StorageError || disk is null ||
            !string.Equals(machine.Firmware, "Uefi", StringComparison.OrdinalIgnoreCase) ||
            disk.Model != "MICROSOFT VIRTUAL DISK" || disk.Bus != "SCSI" || disk.Style != "GPT" ||
            !Guid.TryParse(disk.Guid, out var guid) || guid == Guid.Empty || disk.Size < 64UL * 1024 * 1024 * 1024 ||
            !Regex.IsMatch(disk.Serial, "[A-Z0-9]{3,}") || string.IsNullOrWhiteSpace(disk.UniqueId) ||
            string.IsNullOrWhiteSpace(disk.Layout))
            throw new InvalidOperationException("Для плана нужна отдельная UEFI-VM Hyper-V с однозначным системным диском SCSI/GPT от 64 ГиБ.");
    }

    private static IEnumerable<string> FilesIn(string root) => Directory.EnumerateFiles(root, "*",
        new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint });

    internal static async Task PrepareUsb(string bundle, string letter)
    {
        var info = await Inventory();
        var usb = info.Usb.SingleOrDefault(x => x.Letter == letter) ??
                  throw new InvalidOperationException("Выберите подключённый USB-раздел FAT32.");
        if (!Regex.IsMatch(usb.VolumeId ?? "", @"^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$"))
            throw new InvalidOperationException("USB-том не имеет устойчивого идентификатора.");
        var root = letter + @":\";
        if (string.Equals(Path.GetPathRoot(bundle), root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Выберите исходную папку на другом томе.");
        var manifest = SafePath(bundle, "bundle.json");
        var hashes = Storage.Read<Dictionary<string, string>>(manifest);
        string[] required = ["EFI/Boot/bootx64.efi", "sources/boot.wim", "Images/install.swm"];
        if (hashes.Count > 10000 || required.Any(x => !hashes.Keys.Contains(x, StringComparer.OrdinalIgnoreCase)))
            throw new InvalidDataException("Некорректный манифест носителя.");
        var items = hashes.Concat(new[] { KeyValuePair.Create("bundle.json", Storage.Hash(manifest)) })
            .Select(pair => (Source: SafePath(bundle, pair.Key), Destination: SafePath(usb.VolumeId!, pair.Key), pair.Value))
            .ToArray();
        await Task.Run(() =>
        {
            ulong space = 0;
            foreach (var item in items)
            {
                var bytes = new FileInfo(item.Source).Length;
                if (bytes >= 4L * 1024 * 1024 * 1024 || Storage.Hash(item.Source) != item.Value)
                    throw new InvalidDataException("Файл не прошёл проверку размера или SHA-256.");
                if (File.Exists(item.Destination))
                {
                    if (Storage.Hash(item.Destination) != item.Value)
                        throw new InvalidOperationException("На USB уже есть файл с другим содержимым.");
                }
                else { space += (ulong)bytes + 65536; }
            }
            if (space > usb.Free)
                throw new InvalidOperationException("Недостаточно свободного места.");
            foreach (var item in items)
                CopyVerified(item.Source, item.Destination, item.Value);
            MakeLayout(SafePath(usb.VolumeId!, "AutoSetup"));
        });
    }

    private static void CopyVerified(string source, string destination, string digest)
    {
        if (!File.Exists(destination))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.Copy(source, temporary);
                if (Storage.Hash(temporary) != digest)
                    throw new InvalidDataException("Копия не прошла проверку SHA-256.");
                File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        if (Storage.Hash(destination) != digest)
            throw new InvalidDataException("Копия не прошла проверку SHA-256.");
    }

    internal static string Stage(string workingData, string bundle, Machine machine, Profile profile)
    {
        AssertLab(machine);
        if (!Regex.IsMatch(profile.User, @"\A[a-zA-Z][a-zA-Z0-9_-]{0,18}\z") ||
            Regex.IsMatch(profile.User, @"\A(Administrator|Guest|DefaultAccount|WDAGUtilityAccount)\z", RegexOptions.IgnoreCase))
            throw new InvalidDataException("Недопустимое имя локального пользователя.");
        _ = TimeZoneInfo.FindSystemTimeZoneById(profile.TimeZone);
        var boot = SafePath(bundle, "sources/boot.wim");
        var images = SafePath(bundle, "Images");
        var planPath = SafePath(bundle, "deployment-plan.json");
        if (File.Exists(planPath))
            throw new InvalidOperationException("В папке уже есть план. Используйте свежий комплект WinPE.");
        var manifest = Storage.Read<Dictionary<string, string>>(SafePath(bundle, "bundle.json"));
        if (!manifest.TryGetValue("sources/boot.wim", out var bootHash) || Storage.Hash(boot) != bootHash)
            throw new InvalidDataException("Загрузочный образ WinPE изменён или отсутствует.");
        var files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var image in FilesIn(images))
        {
            var relative = "Images/" + Path.GetRelativePath(images, image).Replace('\\', '/');
            if (!manifest.TryGetValue(relative, out var hash) || Storage.Hash(image) != hash)
                throw new InvalidDataException("Образ изменён после сборки комплекта.");
            files.Add(relative, hash);
        }
        if (!files.ContainsKey("Images/install.swm") || files.Keys.Any(x => !Regex.IsMatch(x, @"\AImages/install\d*\.swm\z")))
            throw new InvalidDataException("Нет ожидаемого набора SWM.");
        var seed = SafePath(bundle, "AutoSetup/Seed");
        var exe = Environment.ProcessPath!;
        CopyVerified(exe, SafePath(seed, "WindowsAutoSetup.exe"), Storage.Hash(exe));
        Storage.Write(SafePath(seed, "Config/profile.json"), profile);
        foreach (var pkg in profile.Packages.Where(x => x.Area is "App" or "Driver" or "Faceit"))
        {
            var area = pkg.Area switch { "App" => "Apps", "Driver" => "Drivers", _ => "Apps/FACEIT" };
            var source = SafePath(workingData, area);
            var target = SafePath(seed, area);
            CopyVerified(SafePath(source, pkg.File), SafePath(target, pkg.File), pkg.Sha256.ToUpperInvariant());
            foreach (var file in pkg.Files ?? [])
                CopyVerified(SafePath(source, file.Key), SafePath(target, file.Key), file.Value.ToUpperInvariant());
        }
        foreach (var item in FilesIn(seed))
        {
            var relative = Path.GetRelativePath(seed, item).Replace('\\', '/');
            if (relative != "WindowsAutoSetup.exe" && relative != "Config/profile.json" &&
                !relative.StartsWith("Apps/", StringComparison.OrdinalIgnoreCase) &&
                !relative.StartsWith("Drivers/", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("В Seed находятся непредусмотренные файлы. Используйте свежий комплект.");
            files.Add("AutoSetup/Seed/" + relative, Storage.Hash(item));
        }
        Storage.Write(planPath, new Plan(1, machine.Target!, profile.User, profile.TimeZone, bootHash, files));
        return Storage.Hash(planPath)[..20];
    }
}
