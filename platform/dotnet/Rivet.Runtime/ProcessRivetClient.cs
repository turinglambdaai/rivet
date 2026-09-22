using System.Diagnostics;

namespace Rivet.Runtime;

public sealed class ProcessRivetClient : IRivetClient
{
    private readonly Process _process;
    private readonly StreamRivetClient _client;
    private readonly Task<string> _stderr;
    private int _disposed;

    private ProcessRivetClient(Process process, StreamRivetClient client)
    {
        _process = process;
        _client = client;
        _stderr = process.StandardError.ReadToEndAsync();
    }

    public event EventHandler<RivetEventArgs>? EventReceived
    {
        add => _client.EventReceived += value;
        remove => _client.EventReceived -= value;
    }

    public static async Task<ProcessRivetClient> StartAsync(
        ProcessStartInfo startInfo,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardInput = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true,
        };
        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("Failed to start the Rivet backend process.");
        }

        var client = new StreamRivetClient(
            process.StandardOutput.BaseStream,
            process.StandardInput.BaseStream,
            leaveOpen: true);
        var result = new ProcessRivetClient(process, client);
        try
        {
            await client.StartAsync(cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch
        {
            await result.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public Task<RivetValue> CallAsync(
        string rpcName,
        IReadOnlyList<RivetValue>? arguments = null,
        CancellationToken cancellationToken = default) =>
        _client.CallAsync(rpcName, arguments, cancellationToken);

    public Task<RivetValue> GetStateAsync(
        string name,
        CancellationToken cancellationToken = default) =>
        _client.GetStateAsync(name, cancellationToken);

    public Task<RivetValue> SetStateAsync(
        string name,
        RivetValue value,
        CancellationToken cancellationToken = default) =>
        _client.SetStateAsync(name, value, cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await _client.DisposeAsync().ConfigureAwait(false);

        if (!_process.HasExited)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            try
            {
                await _process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                _process.Kill(entireProcessTree: true);
                await _process.WaitForExitAsync().ConfigureAwait(false);
            }
        }

        var exitCode = _process.ExitCode;
        var stderr = await _stderr.ConfigureAwait(false);
        if (exitCode != 0 && !string.IsNullOrWhiteSpace(stderr))
        {
            Debug.WriteLine($"Rivet backend stderr: {stderr}");
        }
        _process.Dispose();
    }
}
