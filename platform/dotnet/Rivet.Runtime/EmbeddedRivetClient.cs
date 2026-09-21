using System.Runtime.InteropServices;
using System.Text;

namespace Rivet.Runtime;

/// <summary>
/// Paths and entry-point metadata for an in-process Racket CS backend built by
/// <c>raco rivet build-dotnet</c>.
/// </summary>
public sealed record EmbeddedRivetOptions(
    string RuntimeRoot,
    string ModuleName = "backend",
    string EntrySymbol = "start",
    string? ExecutablePath = null)
{
    internal NativeRuntimeConfig ToNativeConfig()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(RuntimeRoot);
        var root = Path.GetFullPath(RuntimeRoot);
        var runtime = Path.Combine(root, "runtime");
        var backendBundle = Path.Combine(root, "res", "core.zo");
        return new NativeRuntimeConfig
        {
            // `raco ctool --runtime-access ../runtime` rewrites define-runtime-path
            // references relative to Racket's logical executable path. Use the
            // compiled backend bundle itself as that stable, existing anchor:
            //   res/core.zo -> ../runtime/...
            // This makes RuntimeRoot a relocatable product component instead of
            // accidentally anchoring resources to the managed host executable.
            ExecutablePath = ExecutablePath ?? backendBundle,
            PetiteBoot = Path.Combine(runtime, "petite.boot"),
            SchemeBoot = Path.Combine(runtime, "scheme.boot"),
            RacketBoot = Path.Combine(runtime, "racket.boot"),
            BackendBundle = backendBundle,
            ModuleName = ModuleName,
            EntrySymbol = EntrySymbol,
            CollectsDir = string.Empty,
            ConfigDir = string.Empty,
            DllDir = runtime,
        };
    }
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
internal struct NativeRuntimeConfig
{
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string ExecutablePath;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string PetiteBoot;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string SchemeBoot;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string RacketBoot;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string BackendBundle;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string ModuleName;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string EntrySymbol;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string CollectsDir;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string ConfigDir;
    [MarshalAs(UnmanagedType.LPUTF8Str)] public string DllDir;
}

/// <summary>
/// IRivetClient implementation backed by the in-process C++/Racket CS runtime.
/// The C ABI carries RVT1 Value payloads, so generated APIs behave identically
/// to StreamRivetClient/ProcessRivetClient while avoiding a child process.
/// </summary>
public sealed class EmbeddedRivetClient : IRivetClient
{
    private readonly object _lifecycle = new();
    private readonly NativeMethods.EventCallback _eventCallback;
    private readonly TaskCompletionSource _drained = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private IntPtr _backend;
    private int _activeCalls;
    private bool _disposing;
    private bool _disposed;

    private EmbeddedRivetClient(IntPtr backend)
    {
        _backend = backend;
        _eventCallback = OnNativeEvent;
        NativeMethods.BackendSetEventCallback(_backend, _eventCallback, IntPtr.Zero);
    }

    public event EventHandler<RivetEventArgs>? EventReceived;

    public bool IsRunning =>
        !_disposed && _backend != IntPtr.Zero && NativeMethods.BackendRunning(_backend) != 0;

    public static async Task<EmbeddedRivetClient> StartAsync(
        EmbeddedRivetOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The first embedded .NET Rivet runtime targets Windows x64.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        var config = options.ToNativeConfig();
        EnsureRuntimeFiles(config);

        NativeBuffer error = default;
        var status = NativeMethods.BackendCreate(ref config, out var backend, out error);
        if (status != 0)
        {
            throw new InvalidOperationException(ConsumeError(ref error, "Failed to create embedded Rivet backend."));
        }

        var client = new EmbeddedRivetClient(backend);
        try
        {
            await Task.Run(
                () =>
                {
                    NativeBuffer startError = default;
                    var startStatus = NativeMethods.BackendStart(backend, out startError);
                    if (startStatus != 0)
                    {
                        throw new InvalidOperationException(
                            ConsumeError(ref startError, "Failed to start embedded Rivet backend."));
                    }
                },
                cancellationToken).ConfigureAwait(false);
            return client;
        }
        catch
        {
            await client.DisposeAsync().ConfigureAwait(false);
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
        ArgumentException.ThrowIfNullOrWhiteSpace(rpcName);
        cancellationToken.ThrowIfCancellationRequested();
        EnterCall();

        IntPtr call = IntPtr.Zero;
        try
        {
            var encoded = RivetProtocol.EncodeValue(
                RivetValue.From(arguments ?? Array.Empty<RivetValue>()));
            NativeBuffer beginError = default;
            var beginStatus = NativeMethods.BackendBeginCall(
                _backend,
                rpcName,
                encoded,
                (nuint)encoded.Length,
                out call,
                out beginError);
            if (beginStatus != 0)
            {
                throw new RivetRemoteException(
                    ConsumeError(ref beginError, $"Failed to start Rivet RPC '{rpcName}'."));
            }

            using var registration = cancellationToken.Register(
                static state => NativeMethods.CallCancel((IntPtr)state!),
                call);

            try
            {
                return await Task.Run(() => WaitForCall(call)).ConfigureAwait(false);
            }
            catch (RivetRemoteException) when (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(cancellationToken);
            }
        }
        finally
        {
            if (call != IntPtr.Zero)
            {
                NativeMethods.CallDestroy(call);
            }
            ExitCall();
        }
    }

    private static RivetValue WaitForCall(IntPtr call)
    {
        NativeBuffer result = default;
        NativeBuffer error = default;
        var status = NativeMethods.CallWait(call, out result, out error);
        if (status != 0)
        {
            throw new RivetRemoteException(
                ConsumeError(ref error, "Embedded Rivet RPC failed."));
        }

        try
        {
            return RivetProtocol.DecodeValue(CopyBuffer(result));
        }
        finally
        {
            NativeMethods.BufferFree(ref result);
        }
    }

    private void OnNativeEvent(
        IntPtr context,
        IntPtr nameUtf8,
        IntPtr valueBytes,
        nuint valueSize)
    {
        _ = context;
        try
        {
            var name = Marshal.PtrToStringUTF8(nameUtf8);
            if (string.IsNullOrEmpty(name))
            {
                return;
            }
            var bytes = CopyBuffer(new NativeBuffer { Data = valueBytes, Size = valueSize });
            var value = RivetProtocol.DecodeValue(bytes);
            EventReceived?.Invoke(this, new RivetEventArgs(name, value));
        }
        catch
        {
            // Managed event handlers are isolated from the native reader loop.
        }
    }

    private void EnterCall()
    {
        lock (_lifecycle)
        {
            if (_disposing || _disposed || _backend == IntPtr.Zero)
            {
                throw new ObjectDisposedException(nameof(EmbeddedRivetClient));
            }
            checked { _activeCalls++; }
        }
    }

    private void ExitCall()
    {
        lock (_lifecycle)
        {
            _activeCalls--;
            if (_disposing && _activeCalls == 0)
            {
                _drained.TrySetResult();
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        IntPtr backend;
        Task? drain = null;
        lock (_lifecycle)
        {
            if (_disposed || _disposing)
            {
                return;
            }
            _disposing = true;
            backend = _backend;
            if (_activeCalls != 0)
            {
                drain = _drained.Task;
            }
        }

        if (backend != IntPtr.Zero)
        {
            NativeMethods.BackendSetEventCallback(backend, null, IntPtr.Zero);
            NativeMethods.BackendStop(backend);
        }
        if (drain is not null)
        {
            await drain.ConfigureAwait(false);
        }
        if (backend != IntPtr.Zero)
        {
            NativeMethods.BackendDestroy(backend);
        }

        lock (_lifecycle)
        {
            _backend = IntPtr.Zero;
            _disposed = true;
            _disposing = false;
        }
    }

    private static void EnsureRuntimeFiles(NativeRuntimeConfig config)
    {
        foreach (var path in new[]
                 {
                     config.PetiteBoot,
                     config.SchemeBoot,
                     config.RacketBoot,
                     config.BackendBundle,
                 })
        {
            if (!File.Exists(path))
            {
                throw new FileNotFoundException("Embedded Rivet runtime file is missing.", path);
            }
        }
    }

    private static byte[] CopyBuffer(NativeBuffer buffer)
    {
        if (buffer.Data == IntPtr.Zero || buffer.Size == 0)
        {
            return [];
        }
        var length = checked((int)buffer.Size);
        var bytes = new byte[length];
        Marshal.Copy(buffer.Data, bytes, 0, length);
        return bytes;
    }

    private static string ConsumeError(ref NativeBuffer buffer, string fallback)
    {
        try
        {
            if (buffer.Data == IntPtr.Zero || buffer.Size == 0)
            {
                return fallback;
            }
            return Encoding.UTF8.GetString(CopyBuffer(buffer));
        }
        finally
        {
            NativeMethods.BufferFree(ref buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeBuffer
    {
        public IntPtr Data;
        public nuint Size;
    }

    private static class NativeMethods
    {
        private const string Library = "rivet_native";

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void EventCallback(
            IntPtr context,
            IntPtr nameUtf8,
            IntPtr valueBytes,
            nuint valueSize);

        [DllImport(Library, EntryPoint = "rivet_backend_create", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int BackendCreate(
            ref NativeRuntimeConfig config,
            out IntPtr backend,
            out NativeBuffer errorUtf8);

        [DllImport(Library, EntryPoint = "rivet_backend_start", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int BackendStart(IntPtr backend, out NativeBuffer errorUtf8);

        [DllImport(Library, EntryPoint = "rivet_backend_stop", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void BackendStop(IntPtr backend);

        [DllImport(Library, EntryPoint = "rivet_backend_running", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int BackendRunning(IntPtr backend);

        [DllImport(Library, EntryPoint = "rivet_backend_destroy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void BackendDestroy(IntPtr backend);

        [DllImport(Library, EntryPoint = "rivet_backend_set_event_callback", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void BackendSetEventCallback(
            IntPtr backend,
            EventCallback? callback,
            IntPtr context);

        [DllImport(Library, EntryPoint = "rivet_backend_begin_call", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int BackendBeginCall(
            IntPtr backend,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string rpcNameUtf8,
            byte[] argumentsValue,
            nuint argumentsSize,
            out IntPtr call,
            out NativeBuffer errorUtf8);

        [DllImport(Library, EntryPoint = "rivet_call_wait", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int CallWait(
            IntPtr call,
            out NativeBuffer resultValue,
            out NativeBuffer errorUtf8);

        [DllImport(Library, EntryPoint = "rivet_call_cancel", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void CallCancel(IntPtr call);

        [DllImport(Library, EntryPoint = "rivet_call_destroy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void CallDestroy(IntPtr call);

        [DllImport(Library, EntryPoint = "rivet_buffer_free", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void BufferFree(ref NativeBuffer buffer);
    }
}