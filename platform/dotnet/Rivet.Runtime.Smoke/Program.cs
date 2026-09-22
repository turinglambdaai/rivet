using Rivet.Runtime;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

var value = RivetValue.List(
    RivetValue.Null,
    RivetValue.From(false),
    RivetValue.From(true),
    RivetValue.From(-42L),
    RivetValue.From("你好 Rivet"),
    RivetValue.From(new byte[] { 0, 1, 2, 255 }),
    RivetValue.List(RivetValue.From(7L), RivetValue.From("nested")));

var encoded = RivetProtocol.EncodeValue(value);
var decoded = RivetProtocol.DecodeValue(encoded).AsList();
Require(decoded.Count == 7, "value list length mismatch");
Require(decoded[0] is RivetValue.NullValue, "null mismatch");
Require(decoded[1].AsBool() is false, "false mismatch");
Require(decoded[2].AsBool(), "true mismatch");
Require(decoded[3].AsInt64() == -42, "int64 mismatch");
Require(decoded[4].AsString() == "你好 Rivet", "string mismatch");
Require(decoded[5].AsBytes().SequenceEqual(new byte[] { 0, 1, 2, 255 }), "bytes mismatch");
Require(decoded[6].AsList()[1].AsString() == "nested", "nested list mismatch");

await using var stream = new MemoryStream();
var frame = new RivetFrame(RivetMessageType.Request, 123, encoded);
await RivetProtocol.WriteFrameAsync(stream, frame);
stream.Position = 0;
var read = await RivetProtocol.ReadFrameAsync(stream)
    ?? throw new InvalidOperationException("frame unexpectedly reached EOF");
Require(read.Type == RivetMessageType.Request, "frame type mismatch");
Require(read.Id == 123, "frame id mismatch");
Require(RivetProtocol.DecodeValue(read.Payload).AsList()[4].AsString() == "你好 Rivet",
    "frame payload mismatch");

Console.WriteLine("Rivet.Runtime smoke passed.");
