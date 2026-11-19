using System.Reflection;
using System.Security.Cryptography;
using WindowsAutoSetup;

internal static class Tests
{
    private const string TestPassword = "synthetic-test-password-only";

    [STAThread]
    private static void Main()
    {
        var root = Path.Combine(Path.GetTempPath(), "AutoSetupTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var vaultPath = Media.SafePath(root, "Private/accounts.vault");
            List<Account> fixture = [new("Demo", "synthetic-user", "synthetic-vault-entry")];
            Vault.Save(vaultPath, TestPassword, fixture);
            Require(Vault.Open(vaultPath, TestPassword).SequenceEqual(fixture), "Vault round-trip");
            var original = File.ReadAllBytes(vaultPath);
            Vault.Save(vaultPath, TestPassword, fixture);
            Require(!File.ReadAllBytes(vaultPath).SequenceEqual(original), "Fresh vault nonce/salt on overwrite");
            Require(!System.Text.Encoding.UTF8.GetString(original).Contains(fixture[0].Secret), "Vault payload encrypted");
            Reject<CryptographicException>(() => Vault.Open(vaultPath, "different-synthetic-password"), "Wrong vault password");
            original[^1] ^= 1;
            Storage.Replace(vaultPath, original);
            Reject<CryptographicException>(() => Vault.Open(vaultPath, TestPassword), "Vault tag tampering");
            Media.MakeLayout(root);
            Require(Media.Layout.All(item => Directory.Exists(Media.SafePath(root, item))), "Portable directory layout");
            Reject<InvalidDataException>(() => Media.SafePath(root, "Apps/../../outside"), "Path traversal");
            Reject<InvalidDataException>(() => Media.SafePath(root, @"C:\Windows"), "Absolute payload path");
            Reject<InvalidDataException>(() => Media.SafePath(root, "Apps/file.exe:other"), "Alternate data stream");
            var disk = new Disk(2, Guid.NewGuid().ToString(), "SER-1234", "MICROSOFT VIRTUAL DISK", 90UL << 30,
                "SCSI", "virtual", "GPT", "1:2:3");
            var pc = new Machine("Board", "Virtual Machine", true, disk, false, "Russian Standard Time", "Uefi", [], []);
            Media.AssertLab(pc);
            Reject<InvalidOperationException>(() => Media.AssertLab(pc with { Lab = false }), "Physical deployment refused");
            Reject<InvalidOperationException>(() => Media.AssertLab(pc with { StorageError = true }), "Uncertain system disk refused");
            Reject<InvalidOperationException>(() => Media.AssertLab(pc with { Target = disk with { Size = 16UL << 30 } }),
                "Undersized disk refused");
            TestPlan(root, pc);
            var actual = Media.Inventory().GetAwaiter().GetResult();
            Require(!string.IsNullOrEmpty(actual.Model) && !string.IsNullOrEmpty(actual.TimeZone), "Live read-only hardware inventory");
            TestUi();
        }
        finally
        {
            var full = Path.GetFullPath(root);
            if (Path.GetDirectoryName(full) == Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\') &&
                Path.GetFileName(full).StartsWith("AutoSetupTests-", StringComparison.Ordinal))
                Directory.Delete(full, recursive: true);
        }
    }

    private static void TestPlan(string root, Machine machine)
    {
        var bundle = Path.Combine(root, "Media");
        var boot = Media.SafePath(bundle, "sources/boot.wim");
        var image = Media.SafePath(bundle, "Images/install.swm");
        Storage.Replace(boot, [0, 1, 2]);
        Storage.Replace(image, [3, 4, 5]);
        var manifest = Media.SafePath(bundle, "bundle.json");
        Storage.Write(manifest, new Dictionary<string, string>
            { ["Images/install.swm"] = Storage.Hash(image), ["sources/boot.wim"] = Storage.Hash(boot) });
        var profile = new Profile("a", "Russian Standard Time", false, true, [], []);
        Storage.Replace(image, [3, 4, 6]);
        Reject<InvalidDataException>(() => Media.Stage(root, bundle, machine, profile), "Changed image refused before staging");
        Storage.Replace(image, [3, 4, 5]);
        var approval = Media.Stage(root, bundle, machine, profile);
        var planPath = Path.Combine(bundle, "deployment-plan.json");
        var plan = Storage.Read<Plan>(planPath);
        Require(Storage.Hash(planPath).StartsWith(approval, StringComparison.Ordinal) && approval.Length == 20,
            "Deployment approval code binds plan bytes");
        Require(plan.Target == machine.Target && plan.Files.TryGetValue("Images/install.swm", out var expected) &&
                expected == Storage.Hash(image) && plan.BootSha256 == Storage.Hash(boot), "Plan binds target, system image, and WinPE digests");
        Require(plan.Files.TryGetValue("AutoSetup/Seed/Config/profile.json", out var seed) &&
                seed == Storage.Hash(Media.SafePath(bundle, "AutoSetup/Seed/Config/profile.json")), "Plan includes pinned local profile");
        Reject<InvalidOperationException>(() => Media.Stage(root, bundle, machine, profile), "Approved plan cannot be overwritten");
    }

    private static void TestUi()
    {
        Application.EnableVisualStyles();
        using var form = new MainForm(inventoryOnShow: false);
        form.ShowInTaskbar = false;
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(Screen.AllScreens.Min(s => s.Bounds.Left) - form.Width - 100, 0);
        form.Show();
        Application.DoEvents();
        var links = typeof(MainForm).GetField("links", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(form) as Dictionary<string, Button>;
        var body = (FlowLayoutPanel)typeof(MainForm).GetField("body", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(form)!;
        var navigate = typeof(MainForm).GetMethod("Navigate", BindingFlags.Instance | BindingFlags.NonPublic)!;
        Require(links?.Count == 11, "Russian navigation entries");
        foreach (var key in links!.Keys)
        {
            navigate.Invoke(form, [key]);
            Require(body.Controls.Count > 0, "Render " + key);
        }
        navigate.Invoke(form, ["Главная"]);
        using var image = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(image, new Rectangle(Point.Empty, form.Size));
        Require(image.GetPixel(45, 180).ToArgb() != image.GetPixel(270, 180).ToArgb(), "Visible navigation panel rendered");
        var output = Environment.GetEnvironmentVariable("AUTOSETUP_TEST_SCREENSHOT");
        if (!string.IsNullOrEmpty(output))
            image.Save(output, System.Drawing.Imaging.ImageFormat.Png);
    }

    private static void Reject<T>(Action operation, string title) where T : Exception
    {
        try { operation(); }
        catch (T) { Console.WriteLine("PASS " + title); return; }
        throw new InvalidOperationException("Expected rejection: " + title);
    }

    private static void Require(bool success, string title)
    {
        if (!success) throw new InvalidOperationException("FAIL " + title);
        Console.WriteLine("PASS " + title);
    }
}
