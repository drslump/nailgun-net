"""
nailgun-net is a tool to speed up the start up of .Net applications

It keeps itself running in the background listening for commands
on a tcp socket. When running an application it communicates with 
the background process to actually execute the program in a
warmed up AppDomain.

BOO_DAEMON_PORT=8888
BOO_DAEMON_MEMORY=50M
BOO_DAEMON_LIFE=2h

boo-daemon --port=8888 --memory=50M --life=2h booc.exe -v file.boo
boo-daemon --life=+30m booi.exe --debug program.boo
boo-daemon --port=8888 --server
boo-daemon --port=8888 --kill

NOTE: Implementing the command in .net/mono incurs in an overhead,
      since the protocol is compatible with Nailgun we can reuse 
      the ng client.


Safe alternative:

    - One AppDomain per program
    - After execution destroy AppDomain and create a new one
      - Call Nailgun.Prepare() in the program assembly
      - Default: Preload assemblies in same directory and prejit methods in domain
    - Next execution uses the pre-loaded domain

"""

namespace nailgun

import System
import System.Reflection
from System.Collections import DictionaryEntry
from System.Collections.Generic import Dictionary, List
from System.Net import IPEndPoint, IPAddress
from System.Net.Sockets import TcpListener, TcpClient
from System.Diagnostics import Stopwatch
from System.IO import Path, Directory, BinaryReader, BinaryWriter, EndOfStreamException, IOException, TextWriter, TextReader


class AppDomainRunner(MarshalByRefObject):
    property Out as TextWriter
    property Error as TextWriter

    def constructor(bw as BinaryWriter):
        Out = NailgunStreamOutput(bw)
        Error = NailgunStreamError(bw)

    def PreJIT(asmfile as string):
        asm = Reflection.Assembly.LoadFrom(asmfile)
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
                        System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle)
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


    def Prepare(program as string):
        skip_default as duck = true

        asm = Reflection.Assembly.LoadFrom(program)
        ngtype = asm.GetType('Nailgun')
        if ngtype:
            method = ngtype.GetMethod('Prepare', BindingFlags.Public | BindingFlags.Static)
            if method:
                print "Calling Nailgun.Prepare hook"
                skip_default = method.Invoke(null, null);

        if not skip_default:
            try:
                path = System.IO.Path.GetDirectoryName(program)
                print "Pre-loading assemblies from", path
                files = System.IO.Directory.EnumerateFiles(path, "*.dll")
                for f in files:
                    PreJIT(f)
            except:
                print "Error running default preparation"


    def Run(program as string, argv as (string)) as int:
        # Replace console streams
        backupOut = Console.Out
        Console.SetOut(Out)
        backupErr = Console.Error
        Console.SetError(Error)

        try:
            asm = Reflection.Assembly.LoadFrom(program)
            main = asm.EntryPoint
            if not main:
                raise "Entry point not found"

            ngtype = asm.GetType('Nailgun')
            if ngtype:
                method = ngtype.GetMethod('Execute', BindingFlags.Public | BindingFlags.Static)
                if method:
                    #print "Calling Nailgun.Execute hook"
                    method.Invoke(null, null);


            # print 'args:', join(argv, ', ')
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


def CreateRunnerInAppDomain(domain as AppDomain, bw as BinaryWriter):
    runner as AppDomainRunner = domain.CreateInstanceAndUnwrap(
        typeof(AppDomainRunner).Assembly.FullName, 
        typeof(AppDomainRunner).FullName, 
        false, 
        BindingFlags.Public | BindingFlags.Instance, 
        null, 
        (bw,),
        null, 
        null
    )

    return runner


def dumpMemoryUsage():
    suf = ("B", "KB", "MB", "GB")
    count = GC.GetTotalMemory(false)
    if count == 0:
        place = 0
    else:
        bytes = Math.Abs(count);
        place = Convert.ToInt32(Math.Floor(Math.Log(bytes, 1024)))
        count = Math.Round(bytes / Math.Pow(1024, place), 1)

    print "[DEBUG] Memory Usage: $(count)$(suf[place])"


class Command:
""" Represents a command as send by the client to execute
"""
    property Env = Dictionary[of string, string]()
    property Args = List[of string]()
    property WorkingDirectory as string

    _runner as AppDomainRunner

    def constructor(domain as AppDomain, bw as BinaryWriter):
        _runner = CreateRunnerInAppDomain(domain, bw)

    def Run(program) as int:
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
            program = Path.GetFullPath(program)
            exitCode = _runner.Run(program, array(string, Args))
        ensure:
            # Restore process environment
            Directory.SetCurrentDirectory(cwd)
            for pair in backup_env:
                Environment.SetEnvironmentVariable(pair.Key, pair.Value)

        return exitCode



def server(argv as (string)):

    port = (argv[0] if len(argv) > 0 else 2113)
    listener = TcpListener(IPAddress.Loopback, port)
    listener.Start()

    print "nailgun-net daemon started on port $port"

    # Bootstrap an initial AppDomain
    domain = AppDomain.CreateDomain("CompilerDomain")

    while true:
        # Wait for a new connection
        conn = listener.AcceptTcpClient()
        print "Incoming command..."

        stream = conn.GetStream()
        br = BinaryReader(stream)
        bw = BinaryWriter(stream)

        command = Command(domain, bw)

        sw = Stopwatch()
        program = null
        while true:
            try:
                chunk = ParseChunk(br)
                # print "Type: $(chunk.Type) -- $(chunk.Data)"

                if chunk.Type == ChunkType.Argument:
                    command.Args.Add(chunk.Data)
                elif chunk.Type == ChunkType.Environment:
                    key, value = chunk.Data.Split((char('='),), 2)
                    command.Env[key] = value
                elif chunk.Type == ChunkType.WorkingDirectory:
                    command.WorkingDirectory = chunk.Data
                elif chunk.Type == ChunkType.Command:

                    program = chunk.Data
                    if not Path.IsPathRooted(program):
                        program = Path.Combine(command.WorkingDirectory, program)
                    
                    print "Running $program"

                    try:
                        sw.Restart()
                        exitCode = command.Run(program)
                    except ex:
                        chunk = Chunk(ChunkType.Stderr, "[nailgun] Error running program: $ex")
                        SerializeChunk(chunk, bw)
                        exitCode = 128
                    ensure:
                        sw.Stop()

                    # Make sure we reset the color
                    # TODO: Only do it if ansi colors are enabled
                    chunk = Chunk(ChunkType.Stdout, char(0x1B) + "[0m")
                    SerializeChunk(chunk, bw)
                    chunk = Chunk(ChunkType.Stderr, char(0x1B) + "[0m")
                    SerializeChunk(chunk, bw)

                    # Notify the client the exit code
                    chunk = Chunk(ChunkType.Exit, exitCode.ToString())
                    SerializeChunk(chunk, bw)
                    bw.Flush()

                    print "Exited with code $exitCode after {0}ms" % (sw.ElapsedMilliseconds,)

                    sw.Restart()

                    # Re-cycle the AppDomain and prepare it for next run
                    AppDomain.Unload(domain)
                    domain = AppDomain.CreateDomain("CompilerDomain")

                    runner = CreateRunnerInAppDomain(domain, bw) 
                    runner.Prepare(program)
                    
                    sw.Stop()
                    print "Background AppDomain ready after a setup of {0}ms" % (sw.ElapsedMilliseconds,)

                    dumpMemoryUsage()

                    break

                else:
                    print "Type: $(chunk.Type) -- $(chunk.Data)"

            except ex as EndOfStreamException:
                print "EOS"
                break
            except ex as IOException:
                print "IO error: $ex"
                break


server(argv)
