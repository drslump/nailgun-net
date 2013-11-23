namespace nailgun

from System import MarshalByRefObject
from System.Collections.Generic import Dictionary, List
from System.IO import Path


class Command(MarshalByRefObject):
""" Models a command as sent by the client
    NOTE: This type will be marshaled to be consumed in an AppDomain
"""
    property Env = Dictionary[of string, string]()
    property Args = List[of string]()
    property WorkingDirectory as string

    _program as string
    Program:
        get: return _program
        set:
            # TODO: Resolve symlinks?
            if not Path.IsPathRooted(value):
                value = Path.Combine(WorkingDirectory, value)
            _program = Path.GetFullPath(value)


    def SupportsAnsi(idx as int):
        # Checks if it's explicitly disabled
        if "NAILGUN_TTY_$idx" in Env and Env["NAILGUN_TTY_$idx"] == "0":
            return false

        # Use global environment setting (non-standard Nailgun)
        if 'NAILGUN_ANSI' in Env:
            return Env['NAILGUN_ANSI'] =~ /^\s*(yes|true|on|1)\s*$/i

        # Disable for Windows clients since we won't have TTY info from them
        if 'NAILGUN_FILESEPARATOR' in Env and Env['NAILGUN_FILESEPARATOR'] == '\\':
            return false

        # Check the reported terminal
        if 'TERM' in Env and Env['TERM'] =~ /^(xterm|rxvt)/i:
            return 'COLORTERM' in Env or Env['TERM'] =~ /color/i

        return false

    def ToString():
        return "Command[$_program]"
