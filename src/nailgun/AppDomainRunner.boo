namespace nailgun

from System import Console, MarshalByRefObject, AppDomain
from System.IO import TextWriter, Path, Directory, BinaryReader, BinaryWriter
from System.Reflection import Assembly, MethodAttributes, BindingFlags
from System.Runtime.CompilerServices import RuntimeHelpers



class AppDomainRunner(MarshalByRefObject):
""" Responsible for preparing and executing a command in an AppDomain.

    NOTE: This type serves as bridge between the daemon and the isolated
          AppDomain. Calls are performed using remoting which is slow,
          so it shouldn't use complex types as params or return values.
"""
    event StdIn as callable(string)
    event StdOut as callable(string)
    event StdErr as callable(string)

    Domain:
        get: return AppDomain.CurrentDomain

    property Initialized as bool


    _program as string

    _stdin as NailgunStreamInput
    _stdout as NailgunStreamOutput
    _stderr as NailgunStreamOutput

    def constructor(program):
        _program = program

        # Bind the standard output streams to the exported events
        _stdout = NailgunStreamOutput(OnStdOut)
        _stderr = NailgunStreamOutput(OnStdErr)
        
    override def InitializeLifetimeService():
    """ Protect against the runtime tearing down the object after some time """
        return null

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

        asm = Assembly.LoadFrom(_program)
        ngtype = asm.GetType('Nailgun')
        if ngtype:
            method = ngtype.GetMethod('Prepare', BindingFlags.Public | BindingFlags.Static)
            if method:
                print "Calling Nailgun.Prepare hook"
                skip_default = method.Invoke(null, null);

        if not skip_default:
            try:
                path = Path.GetDirectoryName(_program)
                print "Pre-loading assemblies from", path
                files = Directory.EnumerateFiles(path, "*.dll")
                for f in files:
                    PreJIT(f)
            except:
                print "Error running default preparation"


    def Execute(argv as (string)) as int:
        # Replace console streams
        backupOut = Console.Out
        Console.SetOut(_stdout)
        backupErr = Console.Error
        Console.SetError(_stderr)

        try:
            asm = Assembly.LoadFrom(_program)

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
            # Restore console streams
            Console.SetOut(backupOut)
            Console.SetError(backupErr)
            # and the colors
            Console.ResetColor()

    def ToString():
        return "Runner[$_program]"
