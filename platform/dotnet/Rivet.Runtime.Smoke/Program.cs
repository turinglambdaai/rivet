using System.Buffers.Binary;
using System.Text;
using Rivet.Runtime;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void ExpectInvalidData(Action action, string message)
{
    try
    {
        action();
    }
    catch (InvalidDataException)
    {
        return;
    }

    throw new InvalidOperationException(message);
}

static async Task ExpectInvalidDataAsync(Func<Task> action, string message)
{
    try
    {
        await action();
    }
    catch (InvalidDataException)
    {
        return;
    }

    throw new InvalidOperationException(message);
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

// Invalid UTF-8 must be rejected instead of silently replacing bad bytes.
ExpectInvalidData(
    () => RivetProtocol.DecodeValue(new byte[] { 0x04, 0x01, 0x00, 0x00, 0x00, 0xff }),
    "invalid UTF-8 was accepted");

// Likewise, malformed UTF-16 input must not be normalized into a different
// wire value by the managed encoder.
ExpectInvalidData(
    () => RivetProtocol.EncodeValue(RivetValue.From("\ud800")),
    "invalid Unicode input was accepted");

// Encoding a 65th nested List would exceed the RVT1 v1 depth budget of 64.
RivetValue tooDeep = RivetValue.Null;
for (var i = 0; i <= RivetProtocol.MaxValueDepth; i++)
{
    tooDeep = RivetValue.List(tooDeep);
}
ExpectInvalidData(
    () => RivetProtocol.EncodeValue(tooDeep),
    "over-depth Rivet value was encoded");

// Decoder depth checks must protect against bytes that did not come from our
// encoder.
var maliciousDepth = new List<byte>();
for (var i = 0; i <= RivetProtocol.MaxValueDepth; i++)
{
    maliciousDepth.Add(0x06);
    maliciousDepth.AddRange(new byte[] { 0x01, 0x00, 0x00, 0x00 });
}
maliciousDepth.Add(0x00);
ExpectInvalidData(
    () => RivetProtocol.DecodeValue(maliciousDepth.ToArray()),
    "over-depth Rivet payload was decoded");

// The root List itself consumes one node, so declaring MaxValueNodes children
// must fail before allocating an enormous array.
var nodeBomb = new byte[5];
nodeBomb[0] = 0x06;
BinaryPrimitives.WriteUInt32LittleEndian(
    nodeBomb.AsSpan(1, 4),
    checked((uint)RivetProtocol.MaxValueNodes));
ExpectInvalidData(
    () => RivetProtocol.DecodeValue(nodeBomb),
    "over-budget Rivet node declaration was accepted");

var tooManyChildren = Enumerable
    .Repeat(RivetValue.Null, RivetProtocol.MaxValueNodes)
    .ToArray();
ExpectInvalidData(
    () => RivetProtocol.EncodeValue(RivetValue.From(tooManyChildren)),
    "over-budget Rivet value graph was encoded");

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

// Unknown message types are protocol errors in both directions.
await ExpectInvalidDataAsync(
    async () =>
    {
        await using var invalidWrite = new MemoryStream();
        await RivetProtocol.WriteFrameAsync(
            invalidWrite,
            new RivetFrame((RivetMessageType)0xff, 0, Array.Empty<byte>()));
    },
    "unknown outbound message type was accepted");

var invalidHeader = new byte[18];
Encoding.ASCII.GetBytes("RVT1").CopyTo(invalidHeader, 0);
invalidHeader[4] = RivetProtocol.Version;
invalidHeader[5] = 0xff;
await ExpectInvalidDataAsync(
    async () =>
    {
        await using var invalidRead = new MemoryStream(invalidHeader);
        _ = await RivetProtocol.ReadFrameAsync(invalidRead);
    },
    "unknown inbound message type was accepted");

Console.WriteLine("Rivet.Runtime protocol and limit smoke passed.");