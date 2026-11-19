using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace WindowsAutoSetup;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--verify-portable"])
        {
            try { return string.IsNullOrWhiteSpace(Media.Inventory().GetAwaiter().GetResult().Model) ? 1 : 0; }
            catch { return 1; }
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
        return 0;
    }

    internal static string Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
            ?? throw new InvalidOperationException("В сборке отсутствует компонент " + name);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static string PowerShell => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
        "WindowsPowerShell", "v1.0", "powershell.exe");

    private static string PsString(string value) => "'" + value.Replace("'", "''") + "'";

    internal static async Task Elevated(object request, bool install = false, Action? onStart = null)
    {
        Directory.CreateDirectory(Storage.Local);
        var worker = install ? Path.Combine(Storage.Local, Guid.NewGuid().ToString("N") + ".ps1")
            : Media.SafePath(Storage.Installed, "Worker.ps1");
        try
        {
            string hash;
            if (install)
            {
                var bytes = Encoding.UTF8.GetBytes(Resource("Worker"));
                Storage.Replace(worker, bytes);
                hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
            }
            else { hash = Storage.Hash(worker); }
            var input = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, Storage.Json));
            var invocation = "$ErrorActionPreference='Stop'; " +
                $"$workerBytes=[IO.File]::ReadAllBytes({PsString(worker)}); " +
                "$sha=[Security.Cryptography.SHA256]::Create(); " +
                "$actual=[BitConverter]::ToString($sha.ComputeHash($workerBytes)).Replace('-',''); $sha.Dispose(); " +
                $"if($actual -ne '{hash}'){{exit 5}}; " +
                $"$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{input}'))|ConvertFrom-Json; " +
                "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($workerBytes))); exit $LASTEXITCODE";
            var start = new ProcessStartInfo(PowerShell)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = Environment.SystemDirectory
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand",
                         Convert.ToBase64String(Encoding.Unicode.GetBytes(invocation)) })
                start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Агент недоступен.");
            onStart?.Invoke();
            await process.WaitForExitAsync();
            if (process.ExitCode != 0)
                throw new InvalidOperationException($"Операция остановлена ({process.ExitCode}). Проверьте журнал установки и профиль.");
        }
        finally { if (install && File.Exists(worker)) File.Delete(worker); }
    }

    internal static async Task<string> Shell(string script)
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var start = new ProcessStartInfo(PowerShell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = system
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                     "[Console]::InputEncoding=[Console]::OutputEncoding=[Text.Encoding]::UTF8; Invoke-Expression ([Console]::In.ReadToEnd())" })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("PowerShell недоступен.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.StandardInput.WriteAsync(script);
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        var result = await output;
        await error;
        if (process.ExitCode != 0)
            throw new InvalidOperationException("Не удалось получить сведения через PowerShell.");
        return result.Trim();
    }
}
