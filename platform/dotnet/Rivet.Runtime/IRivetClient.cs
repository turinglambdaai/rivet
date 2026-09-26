namespace Rivet.Runtime;

public sealed class RivetEventArgs(string name, RivetValue value) : EventArgs
{
    public string Name { get; } = name;
    public RivetValue Value { get; } = value;
}

public sealed class RivetRemoteException(string message) : Exception(message);

public interface IRivetClient : IAsyncDisposable
{
    event EventHandler<RivetEventArgs>? EventReceived;

    Task<RivetValue> CallAsync(
        string rpcName,
        IReadOnlyList<RivetValue>? arguments = null,
        CancellationToken cancellationToken = default);

    Task<RivetValue> GetStateAsync(
        string name,
        CancellationToken cancellationToken = default);

    Task<RivetValue> SetStateAsync(
        string name,
        RivetValue value,
        CancellationToken cancellationToken = default);
}
