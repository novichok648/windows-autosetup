using System.Text.Json;
using System.Security.Cryptography;

namespace WindowsAutoSetup;

internal sealed record Package(
    string Id, string Kind, string Area, string File, string Sha256, string Arguments,
    string DetectPath, string MinVersion, string? Service = null, Dictionary<string, string>? Files = null);

internal sealed record Profile(
    string User, string TimeZone, bool Reboot, bool Startup, List<string> Dev, List<Package> Packages,
    List<string>? NodeTools = null);

internal static class Storage
{
    internal static readonly JsonSerializerOptions Json = new() { WriteIndented = true, MaxDepth = 24 };
    internal static readonly string Local = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WindowsAutoSetup");
    internal static readonly string Installed = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Windows AutoSetup");

    internal static string Hash(string file)
    {
        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    internal static T Read<T>(string path)
    {
        if (new FileInfo(path).Length > 2_000_000)
            throw new InvalidDataException("Файл превышает допустимый размер.");
        return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), Json) ?? throw new InvalidDataException();
    }

    internal static void Write<T>(string path, T data) => Replace(path, JsonSerializer.SerializeToUtf8Bytes(data, Json));

    internal static void Replace(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp))
                File.Delete(temp);
        }
    }
}
