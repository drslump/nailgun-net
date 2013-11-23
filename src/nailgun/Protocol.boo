"""
Protocol should be compatible with Nailgun (http://www.martiansoftware.com/nailgun/protocol.html)
"""

namespace nailgun

from System import UInt32
from System.IO import Stream, BinaryReader, BinaryWriter
from System.Net.IPAddress import NetworkToHostOrder
from System.Text import ASCIIEncoding


enum ChunkType:
    Unknown
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


struct Chunk:
    static public Mapping = {
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


class NailgunReader(BinaryReader):
""" Extends the binary reader to support Chunk types 
"""
    def constructor(stream as Stream):
        super(stream)

    def ReadChunk() as Chunk:
        # TODO: Perhaps is safer to handle the bytes ourselves like in the writer
        size as uint = NetworkToHostOrder(ReadInt32())
        type as byte = ReadByte()

        data as string = null
        if size > 0:
            bytes = ReadBytes(size)
            # TODO: Shall we default to UTF8? Work with bytes instead?
            data = ASCIIEncoding().GetString(bytes, 0, bytes.Length)

        strtype = ASCIIEncoding.ASCII.GetString((type,))
        chunktype = ChunkType.Unknown
        for pair in Chunk.Mapping:
            if pair.Value == strtype:
                chunktype = pair.Key

        return Chunk(chunktype, data)


class NailgunWriter(BinaryWriter):
""" Extends the binary writer to support Chunk types 
"""
    def constructor(stream as Stream):
        super(stream)

    def Write(chunk as Chunk):
        if chunk.Data != null:
            buffer = ASCIIEncoding().GetBytes(chunk.Data)
            l = buffer.Length
            size = array(byte, 4)
            size[0] = (l >> 24) & 0xff
            size[1] = (l >> 16) & 0xff
            size[2] = (l >> 8) & 0xff
            size[3] = l & 0xff;
            Write(size)
        else:
            Write(0 cast int)

        strtype = Chunk.Mapping[chunk.Type] as string
        type = ASCIIEncoding.ASCII.GetBytes(strtype)[0]

        Write(type)
        Write(buffer)
