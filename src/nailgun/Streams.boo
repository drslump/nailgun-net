namespace nailgun

from System import Console, ConsoleColor
from System.IO import Stream, TextReader, TextWriter, BinaryReader, BinaryWriter


class NailgunStreamOutput(TextWriter):

    static colorDark = {
        ConsoleColor.Black: 0,
        ConsoleColor.DarkRed: 1,
        ConsoleColor.DarkGreen: 2,
        ConsoleColor.DarkYellow: 3,
        ConsoleColor.DarkBlue: 4,
        ConsoleColor.DarkMagenta: 5,
        ConsoleColor.DarkCyan: 6,
        ConsoleColor.Gray: 7,
    }

    static colorLight = {
        ConsoleColor.DarkGray: 0,
        ConsoleColor.Red: 1,
        ConsoleColor.Green: 2,
        ConsoleColor.Yellow: 3,
        ConsoleColor.Blue: 4,
        ConsoleColor.Magenta: 5,
        ConsoleColor.Cyan: 6,
        ConsoleColor.White: 7,
    }

    static def GetAnsiColor(color as ConsoleColor, base as int):
        code = char(0x1b) + "["
        if color in colorLight:
            code += "1;"
            base += colorLight[color] cast int
        else:
            base += colorDark[color] cast int

        code += base + "m"

        return code


    property Ansi as bool

    lastFg as ConsoleColor
    lastBg as ConsoleColor

    delegate as callable(string)

    def constructor(delegate as callable(string)):
        super()

        self.delegate = delegate

        self.lastFg = Console.ForegroundColor
        self.lastBg = Console.BackgroundColor

    override def Write(value as char):
        Write(value.ToString())

    override def Write(value as string):
        if Ansi:
            # HACK: Perhaps it's only in Mono but calling `ResetColor` doesn't modify
            #       the FC or BC properties, so we can't detect them properly.
            #       What we do is just use the changed colors for the current string,
            #       not ideal but seems to work better than ignoring the reset completely.
            if Console.ForegroundColor != lastFg or Console.BackgroundColor != lastBg:
                value += char(0x1B) + "[0m"

            if Console.ForegroundColor != lastFg:
                lastFg = Console.ForegroundColor
                value = GetAnsiColor(lastFg, 30) + value
            if Console.BackgroundColor != lastBg:
                lastBg = Console.BackgroundColor
                value = GetAnsiColor(lastBg, 40) + value

        if delegate:
            delegate(value)


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

















