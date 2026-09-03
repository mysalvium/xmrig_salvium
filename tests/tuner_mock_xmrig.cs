using System;
using System.Threading;

public static class TunerMockXmrig
{
    public static int Main()
    {
        string mode = Environment.GetEnvironmentVariable("XMRIG_TUNER_MOCK_MODE") ?? "success";
        Console.WriteLine("[mock] randomx dataset ready");
        Console.Out.Flush();

        if (mode == "no-result")
        {
            return 7;
        }

        Thread.Sleep(250);
        Console.WriteLine("[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = ABCDEF12");
        Console.Out.Flush();

        if (mode == "exit-after-result")
        {
            return 0;
        }

        Thread.Sleep(Timeout.Infinite);
        return 0;
    }
}
