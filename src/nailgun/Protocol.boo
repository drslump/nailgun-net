"""
Protocol should be compatible with Nailgun (http://www.martiansoftware.com/nailgun/protocol.html)
"""

namespace nailgun

from System import UInt32
from System.IO import BinaryReader, BinaryWriter
from System.Net.IPAddress import NetworkToHostOrder, HostToNetworkOrder
from System.Text import ASCIIEncoding


enum ChunkType:
    Argument
    Environment
    WorkingDirectory
    Command
    Stdin
    Stdout
    Stderr
    InputStart
    InputEnd
    Exit
    Heartbeat


class Chunk:
    static public mapping = {
        ChunkType.Argument: 'A',
        ChunkType.Environment: 'E',
        ChunkType.WorkingDirectory: 'D',
        ChunkType.Command: 'C',
        ChunkType.Stdin: '0',
        ChunkType.Stdout: '1',
        ChunkType.Stderr: '2',
        ChunkType.InputStart: 'S',
        ChunkType.InputEnd: '.',
        ChunkType.Exit: 'X',
        ChunkType.Heartbeat: 'H'
    }

    property Type as ChunkType
    property Data as string

    def constructor(type as ChunkType):
        Type = type

    def constructor(type as ChunkType, data as string):
        self(type)
        Data = data


def ByteToChunkType(type as byte) as ChunkType:
    strtype = ASCIIEncoding.ASCII.GetString((type,))
    for pair in Chunk.mapping:
        if pair.Value == strtype:
            return pair.Key

    raise "Unsupported chunk type: $type"


def ChunkTypeToByte(type as ChunkType) as byte:
    strtype as string = Chunk.mapping[type]
    return ASCIIEncoding.ASCII.GetBytes(strtype)[0]


def ParseChunk(br as BinaryReader):
    size as uint = NetworkToHostOrder(br.ReadInt32())
    type as byte = br.ReadByte()

    data as string = null
    if size > 0:
        bytes = br.ReadBytes(size)
        data = ASCIIEncoding().GetString(bytes, 0, bytes.Length)

    return Chunk(ByteToChunkType(type), data)


def SerializeChunk(chunk as Chunk, bw as BinaryWriter):
    if chunk.Data != null:
        buffer = ASCIIEncoding().GetBytes(chunk.Data)
    else:
        buffer = array(byte, 0)

    # Avoid runtime complaints about negative numbers being casted to unsigned
    # unchecked:
    #     bw.Write(HostToNetworkOrder(buffer.Length) cast uint)
    size = array(byte, 4)
    size[0] = (buffer.Length >> 24) & 0xff
    size[1] = (buffer.Length >> 16) & 0xff
    size[2] = (buffer.Length >> 8) & 0xff
    size[3] = buffer.Length & 0xff;
    bw.Write(size)

    bw.Write(ChunkTypeToByte(chunk.Type))
    bw.Write(buffer)
