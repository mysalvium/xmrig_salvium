using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

public static class TunerMockXmrig
{
    public static int Main(string[] args)
    {
        string mode = Environment.GetEnvironmentVariable("XMRIG_TUNER_MOCK_MODE") ?? "success";
        string configPath = "";
        foreach (string argument in args)
        {
            if (argument.StartsWith("--config=", StringComparison.OrdinalIgnoreCase))
            {
                configPath = argument.Substring("--config=".Length).Trim('"');
            }
        }

        string configuration = File.Exists(configPath) ? File.ReadAllText(configPath) : "";
        Match affinity = Regex.Match(
            configuration,
            "\"rx\"\\s*:\\s*\\[(.*?)\\]",
            RegexOptions.Singleline | RegexOptions.IgnoreCase);
        int threads = affinity.Success
            ? Regex.Matches(affinity.Groups[1].Value, "-?[0-9]+").Count
            : 1;
        Match sizeMatch = Regex.Match(
            configuration,
            "\"size\"\\s*:\\s*\"([^\"]+)\"",
            RegexOptions.IgnoreCase);
        string size = sizeMatch.Success ? sizeMatch.Groups[1].Value : "250K";
        string hashSum;
        switch (size)
        {
            case "500K": hashSum = "ABCDEF13"; break;
            case "1M": hashSum = "ABCDEF14"; break;
            case "2M": hashSum = "ABCDEF15"; break;
            case "5M": hashSum = "ABCDEF16"; break;
            default: hashSum = "ABCDEF12"; break;
        }
        if (mode == "wrong-threads")
        {
            threads++;
        }

        Console.WriteLine("[mock] bench start benchmark hashes {0} algo rx/0", size);
        Console.WriteLine("[mock] randomx allocated 2336 MB huge pages 100%");
        Console.WriteLine("[mock] randomx dataset ready");
        Console.WriteLine(
            "[mock] cpu READY threads {0}/{0} ({0}) huge pages 100% {0}/{0}",
            threads);
        Console.Out.Flush();

        if (mode == "no-result")
        {
            return 7;
        }

        Thread.Sleep(250);
        Console.WriteLine("[mock] miner speed 10s/60s/15m 1000.0 1000.0 n/a H/s max 1000.0 H/s");
        Console.WriteLine(
            "[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = {0}",
            hashSum);
        Console.Out.Flush();

        if (mode == "exit-after-result")
        {
            return 0;
        }

        Thread.Sleep(Timeout.Infinite);
        return 0;
    }
}
