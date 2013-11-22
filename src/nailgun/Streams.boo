namespace nailgun

from System import Console, ConsoleColor
from System.IO import TextReader, TextWriter, BinaryReader, BinaryWriter


# TODO: Enable ansi colors with a command line switch or inspected the client sent environment
def toAnsi(fg, bg):

    bright = {
        ConsoleColor.Black: 30,
        ConsoleColor.Red: 31,
        ConsoleColor.Green: 32,
        ConsoleColor.Yellow: 33,
        ConsoleColor.Blue: 34,
        ConsoleColor.Magenta: 35,
        ConsoleColor.Cyan: 36,
        ConsoleColor.White: 37,
    }

    dark = {
        ConsoleColor.DarkRed: 31,
        ConsoleColor.DarkGreen: 32,
        ConsoleColor.DarkYellow: 33,
        ConsoleColor.DarkBlue: 34,
        ConsoleColor.DarkMagenta: 35,
        ConsoleColor.DarkCyan: 36,
        ConsoleColor.Gray: 37,
        ConsoleColor.DarkGray: 30,
    }

    esc = char(0x1B) + "["
    if fg in bright:
        esc += '1;' + bright[fg]
    else:
        esc += dark[fg]

    if bg in bright:
        esc += ';' + (10 + bright[bg] cast int)
    else:
        esc += ';' + (10 + dark[bg] cast int)

    return esc + 'm'


class NailgunStreamOutput(TextWriter):
    chunkType as ChunkType
    stream as BinaryWriter

    lastFg as ConsoleColor
    lastBg as ConsoleColor

    def constructor(stream as BinaryWriter, chunkType as ChunkType):
        super()
        self.stream = stream
        self.chunkType = chunkType

        lastFg = Console.ForegroundColor
        lastBg = Console.BackgroundColor

    def constructor(stream as BinaryWriter):
        self(stream, ChunkType.Stdout)

    override def Write(value as char):
        Write(value.ToString())

    override def Write(value as string):
        if Console.ForegroundColor != lastFg or Console.BackgroundColor != lastBg:
            lastFg = Console.ForegroundColor
            lastBg = Console.BackgroundColor
            value = toAnsi(lastFg, lastBg) + value

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

















