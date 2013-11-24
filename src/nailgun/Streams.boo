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
        elif color in colorDark:
            base += colorDark[color] cast int
        else:
            base = 0

        return code + base + "m"


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
            #       The only possible solution seems to be to capture the actual output
            #       stream of the process and detect the Ansi reset there. However
            #       it would involve spawning a child process to run the target program
            #       there, which is certainly not ideal form any point of view.
            #
            #       What we do now is use the changed colors only for the current string,
            #       works for a bunch of use cases and is certainly better than a non-reset.
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
    callable InputCallback() as int

    _delegate as InputCallback

    def constructor(delegate as InputCallback):
        super()
        _delegate = delegate

    override def Read() as int:
        return _delegate()

    # override def ReadToEnd() as string:
    #     result = ''
    #     while (ch = Read()) != -1:
    #         result += ch cast char 
    #     return result

    # override def Read(buffer as (char), index as int, count as int) as int:
    #     cnt = 0
    #     for i in range(index, index+count):
    #         ch = Read()
    #         break if ch == -1
    #         buffer[index + cnt] = ch

    #     return cnt

    # override def ReadLine() as string:
    #     result = _delegate(10)
    #     return result


















