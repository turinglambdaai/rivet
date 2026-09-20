namespace Rivet.Runtime;

public abstract record RivetValue
{
    private RivetValue() { }

    public sealed record NullValue : RivetValue;
    public sealed record BoolValue(bool Value) : RivetValue;
    public sealed record Int64Value(long Value) : RivetValue;
    public sealed record StringValue(string Value) : RivetValue;
    public sealed record BytesValue(byte[] Value) : RivetValue;
    public sealed record ListValue(IReadOnlyList<RivetValue> Value) : RivetValue;

    public static RivetValue Null { get; } = new NullValue();

    public static RivetValue From(bool value) => new BoolValue(value);
    public static RivetValue From(long value) => new Int64Value(value);
    public static RivetValue From(string value) => new StringValue(value);
    public static RivetValue From(byte[] value) => new BytesValue(value);
    public static RivetValue From(IReadOnlyList<RivetValue> value) => new ListValue(value);
    public static RivetValue List(params RivetValue[] values) => new ListValue(values);

    public bool AsBool() => this is BoolValue value
        ? value.Value
        : throw TypeMismatch("Bool");

    public long AsInt64() => this is Int64Value value
        ? value.Value
        : throw TypeMismatch("Int64");

    public string AsString() => this is StringValue value
        ? value.Value
        : throw TypeMismatch("String");

    public byte[] AsBytes() => this is BytesValue value
        ? value.Value
        : throw TypeMismatch("Bytes");

    public IReadOnlyList<RivetValue> AsList() => this is ListValue value
        ? value.Value
        : throw TypeMismatch("List");

    private InvalidDataException TypeMismatch(string expected) =>
        new($"Rivet value type mismatch: expected {expected}, received {GetType().Name}.");
}
