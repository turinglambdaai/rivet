using System.Buffers.Binary;
using System.Text;

namespace Rivet.Runtime;

public enum RivetMessageType : byte
{
    Hello = 1,
    Request = 2,
    Response = 3,
    Error = 4,
    Event = 5,
    Cancel = 6,
    Shutdown = 7,
}

public readonly record struct RivetFrame(RivetMessageType Type, ulong Id, byte[] Payload);

public static class RivetProtocol
{
    public const byte Version = 1;
    public const int MaxFramePayloadSize = 64 * 1024 * 1024;
    public const int MaxValueDepth = 64;
    public const int MaxValueNodes = 1 << 18;

    private static ReadOnlySpan<byte> Magic => "RVT1"u8;
    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    private const byte TagNull = 0x00;
    private const byte TagFalse = 0x01;
    private const byte TagTrue = 0x02;
    private const byte TagInt64 = 0x03;
    private const byte TagString = 0x04;
    private const byte TagBytes = 0x05;
    private const byte TagList = 0x06;

    public static byte[] EncodeValue(RivetValue value)
    {
        ArgumentNullException.ThrowIfNull(value);
        using var stream = new MemoryStream();
        var remainingNodes = MaxValueNodes;
        WriteValue(stream, value, depth: 0, ref remainingNodes);
        return stream.ToArray();
    }

    public static RivetValue DecodeValue(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxFramePayloadSize)
        {
            throw new InvalidDataException(
                $"Rivet encoded value exceeds {MaxFramePayloadSize} bytes: {bytes.Length}.");
        }

        var offset = 0;
        var remainingNodes = MaxValueNodes;
        var value = ReadValue(bytes, ref offset, depth: 0, ref remainingNodes);
        if (offset != bytes.Length)
        {
            throw new InvalidDataException("Trailing bytes after Rivet value.");
        }

        return value;
    }

    public static async Task WriteFrameAsync(
        Stream stream,
        RivetFrame frame,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(frame.Payload);
        ValidateMessageType((byte)frame.Type);
        if (frame.Payload.Length > MaxFramePayloadSize)
        {
            throw new InvalidDataException(
                $"Rivet payload exceeds {MaxFramePayloadSize} bytes: {frame.Payload.Length}.");
        }

        var header = new byte[18];
        Magic.CopyTo(header);
        header[4] = Version;
        header[5] = (byte)frame.Type;
        BinaryPrimitives.WriteUInt64LittleEndian(header.AsSpan(6, 8), frame.Id);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(14, 4), checked((uint)frame.Payload.Length));

        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        if (frame.Payload.Length != 0)
        {
            await stream.WriteAsync(frame.Payload, cancellationToken).ConfigureAwait(false);
        }
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task<RivetFrame?> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var header = new byte[18];
        if (!await ReadExactAsync(stream, header, allowCleanEof: true, cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        if (!header.AsSpan(0, 4).SequenceEqual(Magic))
        {
            throw new InvalidDataException("Invalid Rivet frame magic.");
        }
        if (header[4] != Version)
        {
            throw new InvalidDataException(
                $"Unsupported Rivet protocol version {header[4]} (expected {Version}).");
        }

        var type = ValidateMessageType(header[5]);
        var id = BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(6, 8));
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(14, 4));
        if (length > MaxFramePayloadSize)
        {
            throw new InvalidDataException(
                $"Rivet payload exceeds {MaxFramePayloadSize} bytes: {length}.");
        }

        var payload = new byte[checked((int)length)];
        if (payload.Length != 0)
        {
            await ReadExactAsync(stream, payload, allowCleanEof: false, cancellationToken).ConfigureAwait(false);
        }

        return new RivetFrame(type, id, payload);
    }

    private static RivetMessageType ValidateMessageType(byte raw) => raw switch
    {
        (byte)RivetMessageType.Hello => RivetMessageType.Hello,
        (byte)RivetMessageType.Request => RivetMessageType.Request,
        (byte)RivetMessageType.Response => RivetMessageType.Response,
        (byte)RivetMessageType.Error => RivetMessageType.Error,
        (byte)RivetMessageType.Event => RivetMessageType.Event,
        (byte)RivetMessageType.Cancel => RivetMessageType.Cancel,
        (byte)RivetMessageType.Shutdown => RivetMessageType.Shutdown,
        _ => throw new InvalidDataException($"Unknown Rivet message type: {raw}.")
    };

    private static void WriteValue(
        Stream stream,
        RivetValue value,
        int depth,
        ref int remainingNodes)
    {
        ConsumeEncodeNode(ref remainingNodes);

        switch (value)
        {
            case RivetValue.NullValue:
                EnsureEncodedSize(stream, 1);
                stream.WriteByte(TagNull);
                break;
            case RivetValue.BoolValue { Value: false }:
                EnsureEncodedSize(stream, 1);
                stream.WriteByte(TagFalse);
                break;
            case RivetValue.BoolValue:
                EnsureEncodedSize(stream, 1);
                stream.WriteByte(TagTrue);
                break;
            case RivetValue.Int64Value integer:
            {
                EnsureEncodedSize(stream, 9);
                stream.WriteByte(TagInt64);
                Span<byte> bytes = stackalloc byte[8];
                BinaryPrimitives.WriteInt64LittleEndian(bytes, integer.Value);
                stream.Write(bytes);
                break;
            }
            case RivetValue.StringValue text:
            {
                if (text.Value is null)
                {
                    throw new InvalidDataException("Rivet String value is null.");
                }

                int byteCount;
                try
                {
                    byteCount = StrictUtf8.GetByteCount(text.Value);
                }
                catch (EncoderFallbackException ex)
                {
                    throw new InvalidDataException("Rivet String contains invalid Unicode data.", ex);
                }

                EnsureEncodedSize(stream, 5L + byteCount);
                stream.WriteByte(TagString);
                WriteLength(stream, byteCount);
                try
                {
                    var bytes = StrictUtf8.GetBytes(text.Value);
                    stream.Write(bytes);
                }
                catch (EncoderFallbackException ex)
                {
                    throw new InvalidDataException("Rivet String contains invalid Unicode data.", ex);
                }
                break;
            }
            case RivetValue.BytesValue blob:
                if (blob.Value is null)
                {
                    throw new InvalidDataException("Rivet Bytes value is null.");
                }
                EnsureEncodedSize(stream, 5L + blob.Value.Length);
                stream.WriteByte(TagBytes);
                WriteLength(stream, blob.Value.Length);
                stream.Write(blob.Value);
                break;
            case RivetValue.ListValue list:
                if (list.Value is null)
                {
                    throw new InvalidDataException("Rivet List value is null.");
                }
                if (depth >= MaxValueDepth)
                {
                    throw new InvalidDataException("Rivet value nesting exceeds protocol limit.");
                }
                if (list.Value.Count > remainingNodes)
                {
                    throw new InvalidDataException("Rivet value node count exceeds protocol limit.");
                }
                EnsureEncodedSize(stream, 5);
                stream.WriteByte(TagList);
                WriteLength(stream, list.Value.Count);
                foreach (var item in list.Value)
                {
                    if (item is null)
                    {
                        throw new InvalidDataException("Rivet List contains a null object reference.");
                    }
                    WriteValue(stream, item, depth + 1, ref remainingNodes);
                }
                break;
            default:
                throw new InvalidDataException($"Unsupported Rivet value: {value.GetType().FullName}.");
        }
    }

    private static RivetValue ReadValue(
        ReadOnlySpan<byte> bytes,
        ref int offset,
        int depth,
        ref int remainingNodes)
    {
        ConsumeDecodeNode(ref remainingNodes);
        EnsureAvailable(bytes, offset, 1);
        var tag = bytes[offset++];
        return tag switch
        {
            TagNull => RivetValue.Null,
            TagFalse => RivetValue.From(false),
            TagTrue => RivetValue.From(true),
            TagInt64 => ReadInt64(bytes, ref offset),
            TagString => ReadString(bytes, ref offset),
            TagBytes => ReadBytes(bytes, ref offset),
            TagList => ReadList(bytes, ref offset, depth, ref remainingNodes),
            _ => throw new InvalidDataException($"Unknown Rivet value tag: {tag}.")
        };
    }

    private static RivetValue ReadInt64(ReadOnlySpan<byte> bytes, ref int offset)
    {
        EnsureAvailable(bytes, offset, 8);
        var value = BinaryPrimitives.ReadInt64LittleEndian(bytes.Slice(offset, 8));
        offset += 8;
        return RivetValue.From(value);
    }

    private static RivetValue ReadString(ReadOnlySpan<byte> bytes, ref int offset)
    {
        var data = ReadSizedBytes(bytes, ref offset);
        try
        {
            return RivetValue.From(StrictUtf8.GetString(data));
        }
        catch (DecoderFallbackException ex)
        {
            throw new InvalidDataException("Invalid UTF-8 in Rivet String value.", ex);
        }
    }

    private static RivetValue ReadBytes(ReadOnlySpan<byte> bytes, ref int offset)
    {
        return RivetValue.From(ReadSizedBytes(bytes, ref offset).ToArray());
    }

    private static RivetValue ReadList(
        ReadOnlySpan<byte> bytes,
        ref int offset,
        int depth,
        ref int remainingNodes)
    {
        if (depth >= MaxValueDepth)
        {
            throw new InvalidDataException("Rivet value nesting exceeds protocol limit.");
        }

        var count = ReadLength(bytes, ref offset);
        // Every declared element consumes at least one value node. Reject the
        // declaration before allocating the array so a tiny payload cannot
        // request a huge managed allocation.
        if (count > remainingNodes)
        {
            throw new InvalidDataException("Rivet value node count exceeds protocol limit.");
        }
        // Every encoded item needs at least one tag byte.
        if (count > bytes.Length - offset)
        {
            throw new InvalidDataException($"Impossible Rivet list length: {count}.");
        }

        var values = new RivetValue[count];
        for (var i = 0; i < values.Length; i++)
        {
            values[i] = ReadValue(bytes, ref offset, depth + 1, ref remainingNodes);
        }
        return RivetValue.From(values);
    }

    private static ReadOnlySpan<byte> ReadSizedBytes(ReadOnlySpan<byte> bytes, ref int offset)
    {
        var length = ReadLength(bytes, ref offset);
        EnsureAvailable(bytes, offset, length);
        var value = bytes.Slice(offset, length);
        offset += length;
        return value;
    }

    private static int ReadLength(ReadOnlySpan<byte> bytes, ref int offset)
    {
        EnsureAvailable(bytes, offset, 4);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(bytes.Slice(offset, 4));
        offset += 4;
        if (length > int.MaxValue)
        {
            throw new InvalidDataException($"Rivet length is too large: {length}.");
        }
        return checked((int)length);
    }

    private static void WriteLength(Stream stream, int length)
    {
        if (length < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(length));
        }
        Span<byte> bytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, checked((uint)length));
        stream.Write(bytes);
    }

    private static void ConsumeEncodeNode(ref int remainingNodes)
    {
        if (remainingNodes == 0)
        {
            throw new InvalidDataException("Rivet value node count exceeds protocol limit.");
        }
        remainingNodes--;
    }

    private static void ConsumeDecodeNode(ref int remainingNodes)
    {
        if (remainingNodes == 0)
        {
            throw new InvalidDataException("Rivet value node count exceeds protocol limit.");
        }
        remainingNodes--;
    }

    private static void EnsureEncodedSize(Stream stream, long additional)
    {
        if (additional < 0 ||
            stream.Length > MaxFramePayloadSize ||
            additional > MaxFramePayloadSize - stream.Length)
        {
            throw new InvalidDataException("Rivet encoded value exceeds payload limit.");
        }
    }

    private static void EnsureAvailable(ReadOnlySpan<byte> bytes, int offset, int count)
    {
        if (count < 0 || offset < 0 || offset > bytes.Length - count)
        {
            throw new InvalidDataException("Unexpected EOF in Rivet value.");
        }
    }

    private static async Task<bool> ReadExactAsync(
        Stream stream,
        Memory<byte> destination,
        bool allowCleanEof,
        CancellationToken cancellationToken)
    {
        var total = 0;
        while (total < destination.Length)
        {
            var read = await stream.ReadAsync(destination[total..], cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                if (total == 0 && allowCleanEof)
                {
                    return false;
                }
                throw new EndOfStreamException("Unexpected EOF in Rivet frame.");
            }
            total += read;
        }
        return true;
    }
}