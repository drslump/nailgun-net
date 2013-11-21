namespace nailgun

from System.IO import TextReader, TextWriter, BinaryReader, BinaryWriter


class NailgunStreamOutput(TextWriter):
    chunkType as ChunkType
    stream as BinaryWriter

    def constructor(stream as BinaryWriter, chunkType as ChunkType):
        super()
        self.stream = stream
        self.chunkType = chunkType

    def constructor(stream as BinaryWriter):
        self(stream, ChunkType.Stdout)

    override def Write(value as char):
        Write(value.ToString())

    override def Write(value as string):
        chunk = Chunk(chunkType, value)
        SerializeChunk(chunk, stream)


class NailgunStreamError(NailgunStreamOutput):

    def constructor(stream as BinaryWriter):
        super(stream, ChunkType.Stderr)


class NailgunStreamInput(TextReader):
    br as BinaryReader
    bw as BinaryWriter
    first as bool

    def constructor(br as BinaryReader, bw as BinaryWriter):
        super()
        self.br = br
        self.bw = bw
        self.first = true

    # override def Read(value as int) as string:
    #     if first:
    #         chunk = Chunk(ChunkType.InputStart)
    #         SerializeChunk(chunk, bw)

        # TODO: We have to lock until there is some input

















