namespace nailgun

from System import AppDomain, Environment
from System.Collections.Generic import Dictionary, List
from System.IO import Path, Directory
from System.Reflection import BindingFlags


class Command:
""" Models a command as sent by the client
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


    def Run(runner as AppDomainRunner) as int:
        # TODO: What happens when two programs are run in parallel with 
        #       CurrentDirectory, Environment and Console redirection?

        # Make sure we are running from the same directory as the client
        cwd = Directory.GetCurrentDirectory()
        if WorkingDirectory:
            Directory.SetCurrentDirectory(WorkingDirectory)

        # Backup and reset the current environment variables
        backup_env = Dictionary[of string, string]()
        for key in Environment.GetEnvironmentVariables().Keys:
            backup_env[key] = Environment.GetEnvironmentVariable(key)
            Environment.SetEnvironmentVariable(key, null)

        # Setup the environment variables
        for pair in Env:
            Environment.SetEnvironmentVariable(pair.Key, pair.Value)

        try:

            exitCode = runner.Execute(array(string, Args))

        ensure:
            # Restore process environment
            Directory.SetCurrentDirectory(cwd)
            for pair in backup_env:
                Environment.SetEnvironmentVariable(pair.Key, pair.Value)

        return exitCode
