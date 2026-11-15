using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

// Single-file portable launcher. The app bundle travels inside this executable as
// `sshairy.payload`; the first launch unpacks it under LocalApplicationData and later
// launches reuse that copy, so startup stays fast and the payload is never re-extracted.
internal static class PortableLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var assembly = Assembly.GetExecutingAssembly();
            var attribute = (AssemblyInformationalVersionAttribute)Attribute.GetCustomAttribute(
                assembly,
                typeof(AssemblyInformationalVersionAttribute));
            var version = attribute == null ? "0" : attribute.InformationalVersion;
            var architecture = (Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "unknown").ToLowerInvariant();
            // Repeated builds can share a version, so the payload hash keeps their caches apart.
            var cache = version + "-" + architecture + "-" + BuildInfo.PayloadHash.Substring(0, 12);
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "sshairy",
                "portable",
                cache);
            var executable = Path.Combine(root, "sshairy.exe");
            if (!File.Exists(executable))
            {
                if (Directory.Exists(root)) Directory.Delete(root, true);
                using (var payload = assembly.GetManifestResourceStream("sshairy.payload"))
                {
                    if (payload == null) throw new InvalidOperationException("The portable payload is missing.");
                    Extract(payload, root);
                }
            }
            if (args.Length == 1 && args[0] == "--extract-only") return 0;
            var start = new ProcessStartInfo(executable) { UseShellExecute = true, WorkingDirectory = root };
            if (args.Length > 0)
            {
                var arguments = new StringBuilder();
                foreach (var argument in args)
                {
                    if (arguments.Length > 0) arguments.Append(' ');
                    arguments.Append(Quote(argument));
                }
                start.Arguments = arguments.ToString();
            }
            Process.Start(start);
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Sshairy", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void Extract(Stream payload, string root)
    {
        var parent = Path.GetDirectoryName(root);
        if (parent != null) Directory.CreateDirectory(parent);
        var pending = root + ".new";
        if (Directory.Exists(pending)) Directory.Delete(pending, true);
        using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
        {
            archive.ExtractToDirectory(pending);
        }
        if (Directory.Exists(root))
        {
            // A second launch finished the same extraction first; keep that copy.
            Directory.Delete(pending, true);
        }
        else
        {
            Directory.Move(pending, root);
        }
    }

    // Windows command-line quoting, including trailing backslashes before a quote.
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
        var result = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"') result.Append('\\', backslashes * 2 + 1);
            else result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
