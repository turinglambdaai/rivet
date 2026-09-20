using System.Collections.Concurrent;

namespace Rivet.Runtime;

public sealed class StreamRivetClient : IRivetClient
{
    private readonly Stream _input;
    private readonly Stream _output;
    private readonly bool _leaveOpen;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly ConcurrentDictionary<ulong, TaskCompletionSource<RivetValue>> _pending = new();
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _readerTask;
    private long _nextId;
    private int _started;
    private int _disposed;

    public StreamRivetClient(Stream input, Stream output, bool leaveOpen = false)
    {
        _input = input ?? throw new ArgumentNullException(nameof(input));
        _output = output ?? throw new ArgumentNullException(nameof(output));
        _leaveOpen = leaveOpen;
    }

    public event EventHandler<RivetEventArgs>? EventReceived;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (Interlocked.Exchange(ref _started, 1) != 0)
        {
            throw new InvalidOperationException("The Rivet client has already been started.");
        }

        try
        {
            var hello = await RivetProtocol.ReadFrameAsync(_input, cancellationToken).ConfigureAwait(false)
                ?? throw new EndOfStreamException("Rivet backend closed before the hello frame.");
            ValidateHello(hello.Value);
            _readerTask = Task.Run(ReadLoopAsync);
        }
        catch
        {
            Interlocked.Exchange(ref _started, 0);
            throw;
        }
    }

    public Task<RivetValue> GetStateAsync(
        string name,
        CancellationToken cancellationToken = default) =>
        CallAsync("$state/get", [RivetValue.From(name)], cancellationToken);

    public Task<RivetValue> SetStateAsync(
        string name,
        RivetValue value,
        CancellationToken cancellationToken = default) =>
        CallAsync("$state/set", [RivetValue.From(name), value], cancellationToken);

    public async Task<RivetValue> CallAsync(
        string rpcName,
        IReadOnlyList<RivetValue>? arguments = null,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (Volatile.Read(ref _started) == 0)
        {
            throw new InvalidOperationException("Call StartAsync before using the Rivet client.");
        }
        ArgumentException.ThrowIfNullOrWhiteSpace(rpcName);

        cancellationToken.ThrowIfCancellationRequested();
        var id = checked((ulong)Interlocked.Increment(ref _nextId));
        var completion = new TaskCompletionSource<RivetValue>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(id, completion))
        {
            throw new InvalidOperationException($"Duplicate Rivet request id: {id}.");
        }

        using var registration = cancellationToken.Register(
            static state =>
            {
                var pair = ((StreamRivetClient Client, ulong Id))state!;
                _ = pair.Client.CancelAsync(pair.Id);
            },
            (this, id));

        try
        {
            var values = new List<RivetValue>(1 + (arguments?.Count ?? 0))
            {
                RivetValue.From(rpcName),
            };
            if (arguments is not null)
            {
                values.AddRange(arguments);
            }

            await SendAsync(
                new RivetFrame(
                    RivetMessageType.Request,
                    id,
                    RivetProtocol.EncodeValue(RivetValue.From(values))),
                cancellationToken).ConfigureAwait(false);

            return await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            _pending.TryRemove(id, out _);
            throw;
        }
    }

    private async Task CancelAsync(ulong id)
    {
        if (_pending.TryRemove(id, out var completion))
        {
            completion.TrySetCanceled();
            try
            {
                await SendAsync(
                    new RivetFrame(RivetMessageType.Cancel, id, []),
                    _lifetime.Token).ConfigureAwait(false);
            }
            catch when (_lifetime.IsCancellationRequested)
            {
                // Shutdown won the race with cancellation.
            }
        }
    }

    private async Task SendAsync(RivetFrame frame, CancellationToken cancellationToken)
    {
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await RivetProtocol.WriteFrameAsync(_output, frame, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task ReadLoopAsync()
    {
        Exception? failure = null;
        try
        {
            while (!_lifetime.IsCancellationRequested)
            {
                var frame = await RivetProtocol.ReadFrameAsync(_input, _lifetime.Token).ConfigureAwait(false);
                if (frame is null)
                {
                    failure = new EndOfStreamException("Rivet backend closed its output stream.");
                    break;
                }

                Dispatch(frame.Value);
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            // Normal shutdown.
        }
        catch (Exception ex)
        {
            failure = ex;
        }
        finally
        {
            var terminal = failure ?? new ObjectDisposedException(nameof(StreamRivetClient));
            foreach (var pair in _pending)
            {
                if (_pending.TryRemove(pair.Key, out var completion))
                {
                    completion.TrySetException(terminal);
                }
            }
        }
    }

    private void Dispatch(RivetFrame frame)
    {
        switch (frame.Type)
        {
            case RivetMessageType.Response:
                Complete(frame.Id, RivetProtocol.DecodeValue(frame.Payload), error: null);
                break;
            case RivetMessageType.Error:
            {
                var error = RivetProtocol.DecodeValue(frame.Payload);
                var message = error is RivetValue.StringValue text
                    ? text.Value
                    : "Rivet backend returned an invalid error payload.";
                Complete(frame.Id, value: null, new RivetRemoteException(message));
                break;
            }
            case RivetMessageType.Event:
                DispatchEvent(RivetProtocol.DecodeValue(frame.Payload));
                break;
            default:
                throw new InvalidDataException(
                    $"Unexpected Rivet message type after handshake: {frame.Type}.");
        }
    }

    private void Complete(ulong id, RivetValue? value, Exception? error)
    {
        if (!_pending.TryRemove(id, out var completion))
        {
            return;
        }

        if (error is not null)
        {
            completion.TrySetException(error);
        }
        else
        {
            completion.TrySetResult(value!);
        }
    }

    private void DispatchEvent(RivetValue payload)
    {
        var values = payload.AsList();
        if (values.Count != 2 || values[0] is not RivetValue.StringValue name)
        {
            throw new InvalidDataException("Invalid Rivet event payload.");
        }

        EventReceived?.Invoke(this, new RivetEventArgs(name.Value, values[1]));
    }

    private static void ValidateHello(RivetFrame frame)
    {
        if (frame.Type != RivetMessageType.Hello)
        {
            throw new InvalidDataException(
                $"Expected Rivet hello frame, received {frame.Type}.");
        }

        var values = RivetProtocol.DecodeValue(frame.Payload).AsList();
        if (values.Count != 2 ||
            values[0] is not RivetValue.StringValue { Value: "rivet" } ||
            values[1] is not RivetValue.Int64Value version ||
            version.Value != RivetProtocol.Version)
        {
            throw new InvalidDataException("Invalid Rivet hello payload.");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        if (Volatile.Read(ref _started) != 0)
        {
            try
            {
                await SendAsync(
                    new RivetFrame(RivetMessageType.Shutdown, 0, []),
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch
            {
                // The backend may already be gone. Shutdown must remain idempotent.
            }
        }

        _lifetime.Cancel();
        if (_readerTask is not null)
        {
            try
            {
                await _readerTask.ConfigureAwait(false);
            }
            catch
            {
                // Reader failures have already been propagated to pending calls.
            }
        }

        if (!_leaveOpen)
        {
            await _input.DisposeAsync().ConfigureAwait(false);
            await _output.DisposeAsync().ConfigureAwait(false);
        }
        _writeGate.Dispose();
        _lifetime.Dispose();
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }
}
