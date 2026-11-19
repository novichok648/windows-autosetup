using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace WindowsAutoSetup;

internal sealed record Account(string Service, string Login, string Secret);

internal static class Vault
{
    private static readonly byte[] Header = Encoding.ASCII.GetBytes("WAULT001");
    private const int SaltSize = 16;
    private const int NonceSize = 12;
    private const int TagSize = 16;
    private const int PrefixSize = 8 + SaltSize + NonceSize;
    private const int Limit = 1024 * 1024;

    internal static void Save(string path, string password, List<Account> accounts)
    {
        if (password.Length < 12)
            throw new ArgumentException("Мастер-пароль должен содержать не менее 12 символов.");
        var plain = JsonSerializer.SerializeToUtf8Bytes(accounts);
        try
        {
            if (plain.Length > Limit)
                throw new InvalidDataException("Хранилище слишком велико.");
            var file = new byte[PrefixSize + plain.Length + TagSize];
            Header.CopyTo(file, 0);
            RandomNumberGenerator.Fill(file.AsSpan(8, SaltSize + NonceSize));
            Transform(file, plain, password, encrypt: true);
            Storage.Replace(path, file);
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    internal static List<Account> Open(string path, string password)
    {
        if (new FileInfo(path).Length > Limit + PrefixSize + TagSize)
            throw new InvalidDataException("Хранилище слишком велико.");
        var file = File.ReadAllBytes(path);
        if (file.Length <= PrefixSize + TagSize || !file.AsSpan().StartsWith(Header))
            throw new InvalidDataException("Неизвестный формат хранилища.");
        var plain = new byte[file.Length - PrefixSize - TagSize];
        try
        {
            Transform(file, plain, password, encrypt: false);
            return JsonSerializer.Deserialize<List<Account>>(plain) ?? throw new InvalidDataException();
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    private static void Transform(byte[] file, byte[] plain, string password, bool encrypt)
    {
        var key = Rfc2898DeriveBytes.Pbkdf2(password, file.AsSpan(8, SaltSize), 600_000,
            HashAlgorithmName.SHA256, 32);
        try
        {
            using var aes = new AesGcm(key, TagSize);
            var prefix = file.AsSpan(0, PrefixSize);
            var nonce = prefix.Slice(8 + SaltSize, NonceSize);
            var ciphertext = file.AsSpan(PrefixSize, plain.Length);
            var tag = file.AsSpan(PrefixSize + plain.Length, TagSize);
            if (encrypt)
                aes.Encrypt(nonce, plain, ciphertext, tag, prefix);
            else
                aes.Decrypt(nonce, ciphertext, tag, plain, prefix);
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }
}
