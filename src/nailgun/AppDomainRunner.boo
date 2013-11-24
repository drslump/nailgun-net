namespace nailgun

from System import Console, Environment, MarshalByRefObject, AppDomain
from System.Collections.Generic import Dictionary
from System.IO import Path, Directory
from System.Reflection import Assembly, MethodAttributes, BindingFlags
from System.Runtime.CompilerServices import RuntimeHelpers



class AppDomainRunner(MarshalByRefObject):
""" Responsible for preparing and executing a command in an AppDomain.

    NOTE: This type serves as bridge between the daemon and the isolated
          AppDomain. Calls are performed using remoting which is slow,
          so it shouldn't use complex types as params or return values.
"""
    property StdIn as NailgunStreamInput.InputCallback
    property StdOut as callable(string)
    property StdErr as callable(string)

    Domain:
        get: return AppDomain.CurrentDomain

    property IsRunning = false

    _command as Command

    _stdin as NailgunStreamInput
    _stdout as NailgunStreamOutput
    _stderr as NailgunStreamOutput

    def constructor(command as Command):
        _command = command

        # Bind the standard streams to the exported events
        _stdin = NailgunStreamInput(OnStdIn)
        _stdout = NailgunStreamOutput(OnStdOut, Ansi: command.SupportsAnsi(1))
        _stderr = NailgunStreamOutput(OnStdErr, Ansi: command.SupportsAnsi(2))

    override def InitializeLifetimeService():
    """ Protect against the runtime tearing down the object after some time """
        return null

    protected def OnStdIn() as int:
        return StdIn() if StdIn

    protected def OnStdOut(str):
        StdOut(str) if StdOut

    protected def OnStdErr(str):
        StdErr(str) if StdErr

    protected def PreJIT(asmfile as string):
        asm = Assembly.LoadFrom(asmfile)
        # Try to pre-initialize types by referencing them
        # try:
        #     for type in asm.GetExportedTypes():
        #         GC.KeepAlive(type)
        # except:
        #     print "error loading types"

        # Pre-initialize types and pre-jit all methods
        try:
            for type in asm.GetTypes():
                # print "Type:", type
                flags = BindingFlags.DeclaredOnly | BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static
                for method in type.GetMethods(flags):
                    if method.Attributes & method.Attributes.Abstract == MethodAttributes.Abstract:
                        continue

                    try:
                        # NOTE: this is a no-op in Mono currently (3.2)
                        RuntimeHelpers.PrepareMethod(method.MethodHandle)
                    except:
                        print "Error pre-jitting method:", method

                # HACK: This is very dirty, since mono doesn't allow to programatically
                #       force the jitting of methods, we try to trigger it by invoking
                #       the type constructors which shouldn't have side effects.
                # NOTE: We don't get that much of an improvement (around 10%) and is 
                #       risky, so perhaps we should just remove it or use a flag.
                # try:
                #     Activator.CreateInstance(type)
                # except:
                #     print "error with constructor for:", type
        except:
            print "Error loading types from assembly:", asm

    def Prepare():

        skip_default as duck = true

        asm = Assembly.LoadFrom(_command.Program)
        ngtype = asm.GetType('Nailgun')
        if ngtype:
            method = ngtype.GetMethod('Prepare', BindingFlags.Public | BindingFlags.Static)
            if method:
                print "Calling Nailgun.Prepare hook"
                skip_default = method.Invoke(null, null);

        if not skip_default:
            try:
                path = Path.GetDirectoryName(_command.Program)
                print "Pre-loading assemblies from", path
                files = Directory.EnumerateFiles(path, "*.dll")
                for f in files:
                    PreJIT(f)
            except:
                print "Error running default preparation"


    protected def Invoke(asm as Assembly, argv as (string)) as int:
        # Replace console streams
        backupIn = Console.In
        Console.SetIn(_stdin)
        backupOut = Console.Out
        Console.SetOut(_stdout)
        backupErr = Console.Error
        Console.SetError(_stderr)

        try:
            # Check if we find an override for Main
            ngtype = asm.GetType('Nailgun')
            if ngtype:
                main = ngtype.GetMethod('Main', BindingFlags.Public | BindingFlags.Static)

            # Query the assembly for its entry point if no specific Main was found
            if not main:
                main = asm.EntryPoint

            if not main:
                raise "Entry point not found"

            result as duck = main.Invoke(null, (argv,))

            if result != null:
                return result
            else:
                return 0
        ensure:
            # Make sure we reset Ansi colors
            if _command.SupportsAnsi(1):
                Console.Out.Write(char(0x1B) + "[0m")
            if _command.SupportsAnsi(2):
                Console.Error.Write(char(0x1B) + "[0m")

            # Restore console streams
            Console.SetIn(backupIn)
            Console.SetOut(backupOut)
            Console.SetError(backupErr)
            # and the colors
            Console.ResetColor()

    def Execute() as int:
        # TODO: What happens when two programs are run in parallel with 
        #       CurrentDirectory, Environment and Console redirection?

        # Make sure we are running from the same directory as the client
        cwd = Directory.GetCurrentDirectory()
        if _command.WorkingDirectory:
            Directory.SetCurrentDirectory(_command.WorkingDirectory)

        # Backup and reset the current environment variables
        backup_env = Dictionary[of string, string]()
        for key in Environment.GetEnvironmentVariables().Keys:
            backup_env[key] = Environment.GetEnvironmentVariable(key)
            Environment.SetEnvironmentVariable(key, null)

        # Setup the environment variables
        for pair in _command.Env:
            Environment.SetEnvironmentVariable(pair.Key, pair.Value)

        result as duck
        try:

            IsRunning = true
            asm = Assembly.LoadFrom(_command.Program)
            result = Invoke(asm, _command.Args.ToArray())

        ensure:
            IsRunning = false

            # Restore process environment
            Directory.SetCurrentDirectory(cwd)
            for pair in backup_env:
                Environment.SetEnvironmentVariable(pair.Key, pair.Value)

        return result

    def Terminate():
        raise "Termination is not implemented yet"        

    def ToString():
        return "Runner[$_command.Program]"
