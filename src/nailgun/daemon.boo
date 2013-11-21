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
from System.Net import IPEndPoint, IPAddress
from System.Net.Sockets import TcpListener, TcpClient
from System.Diagnostics import Stopwatch
from System.IO import BinaryReader, BinaryWriter, EndOfStreamException, IOException, TextWriter, TextReader


class AppDomainRunner(MarshalByRefObject):
    property Out as TextWriter
    property Error as TextWriter

    def constructor(bw as BinaryWriter):
        Out = NailgunStreamOutput(bw)
        Error = NailgunStreamError(bw)

    def PreJIT(asmfile as string):
        print "file:", asmfile
        # Try to pre-initialize types by referencing them
        asm = Reflection.Assembly.LoadFrom(asmfile)
        # try:
        #     for type in asm.GetExportedTypes():
        #         GC.KeepAlive(type)
        # except:
        #     print "error loading types"

        # Pre-initialize types and pre-jit all methods
        try:
            for type in asm.GetTypes():
                # print "Type:", type
                for method in type.GetMethods(BindingFlags.DeclaredOnly | 
                    BindingFlags.NonPublic | 
                    BindingFlags.Public | BindingFlags.Instance | 
                    BindingFlags.Static):

                    if method.Attributes & method.Attributes.Abstract == MethodAttributes.Abstract:
                        continue

                    try:
                        # NOTE: this is a no-op in Mono
                        System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle)
                    except:
                        print "error jitting method:", method

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
            print "error loading types"


    def Prepare(program as string):
        skip_default as duck = true

        asm = Reflection.Assembly.LoadFrom(program)
        ngtype = asm.GetType('Nailgun')
        if ngtype:
            method = ngtype.GetMethod('Prepare', BindingFlags.Public | BindingFlags.Static)
            if method:
                print "Calling Nailgun Prepare hook!"
                skip_default = method.Invoke(null, null);

        if not skip_default:
            try:
                path = System.IO.Path.GetDirectoryName(program)
                print 'path:', path
                files = System.IO.Directory.EnumerateFiles(path, "*.dll")
                for f in files:
                    PreJIT(f)
            except:
                print "Error running default prepare"


    def Run(program as string, argv as (string)) as int:
        # Replace console streams
        backupOut = Console.Out
        Console.SetOut(Out)
        backupErr = Console.Error
        Console.SetError(Error)

        try:
            sw = Stopwatch()
            sw.Start()

            asm = Reflection.Assembly.LoadFrom(program)

            # print asm
            main = asm.EntryPoint
            if not main:
                raise "Entry point not found"

            sw.Stop()
            print "Load assembly: " + sw.ElapsedMilliseconds 

            ngtype = asm.GetType('Nailgun')
            if ngtype:
                method = ngtype.GetMethod('Execute', BindingFlags.Public | BindingFlags.Static)
                if method:
                    print "Calling Nailgun hook!"
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


def CreateRunnerInAppDomain(domain as AppDomain, bw as BinaryWriter):
    assemblies = AppDomain.CurrentDomain.GetAssemblies()
    for asm in assemblies:
        print "Preloaded assemblies: $(asm.FullName)"

    domain.AssemblyResolve += def (sender, args as ResolveEventArgs):
        print "Resolving: $(args.Name)"
        return null

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


def server():

    listener = TcpListener(IPAddress.Loopback, 8888)
    listener.Start()

    print "TCP server started"

    domain = AppDomain.CreateDomain("CompilerDomain")

    while true:
        # Wait for a new connection
        conn = listener.AcceptTcpClient()
        print "New connection!"

        stream = conn.GetStream()
        br = BinaryReader(stream)
        bw = BinaryWriter(stream)

        runner = CreateRunnerInAppDomain(domain, bw)

        # Reset the current environment variables
        for key in Environment.GetEnvironmentVariables().Keys:
            Environment.SetEnvironmentVariable(key, null)

        args = []
        sw = Stopwatch()
        program = null
        while true:
            try:
                chunk = ParseChunk(br)
                # print "Type: $(chunk.Type) -- $(chunk.Data)"
                if chunk.Type == ChunkType.Argument:
                    args.Add(chunk.Data)
                elif chunk.Type == ChunkType.Environment:
                    key, value = chunk.Data.Split((char('='),), 2)
                    Environment.SetEnvironmentVariable(key, value)
                elif chunk.Type == ChunkType.WorkingDirectory:
                    System.IO.Directory.SetCurrentDirectory(chunk.Data)
                elif chunk.Type == ChunkType.Command:

                    program = chunk.Data

                    try:
                        sw.Restart()
                        exitCode = runner.Run(program, array(string, args))
                        sw.Stop()
                        print "Run:", sw.ElapsedMilliseconds

                    except ex:
                        chunk = Chunk(ChunkType.Stderr, "Error running assembly: $ex")
                        SerializeChunk(chunk, bw)
                        exitCode = 128

                    chunk = Chunk(ChunkType.Exit, exitCode.ToString())
                    SerializeChunk(chunk, bw)
                    bw.Flush()


                    sw = Stopwatch()
                    sw.Start()

                    AppDomain.Unload(domain)
                    domain = AppDomain.CreateDomain("CompilerDomain")

                    # TODO: Find a better way to handle Input/Output streams (delegates?)
                    runner = CreateRunnerInAppDomain(domain, bw)

                    runner.Prepare(program)
                    
                    sw.Stop()
                    print "Prepare:", sw.ElapsedMilliseconds

                    break

                else:
                    print "Type: $(chunk.Type) -- $(chunk.Data)"

            except ex as EndOfStreamException:
                print "EOS"
                break
            except ex as IOException:
                print "IO error: $ex"
                break


server()