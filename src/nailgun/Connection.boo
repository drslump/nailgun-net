namespace nailgun

from System import Timers, MarshalByRefObject, IDisposable
from System.Net.Sockets import TcpClient
from System.IO import Path
from System.Diagnostics import Stopwatch

import Boo.Lang.PatternMatching


class StreamsProxy(MarshalByRefObject, IDisposable):
""" Allows to subscribe to events in the AppDomain without making
    the whole Connection type serializable.
"""
    runner as AppDomainRunner
    bw as NailgunWriter

    def constructor(runner as AppDomainRunner, bw as NailgunWriter):
        self.runner = runner
        self.bw = bw
        runner.StdOut += OnStdOut
        runner.StdErr += OnStdErr

    def Dispose():
        runner.StdOut -= OnStdOut
        runner.StdErr -= OnStdErr
        # Make sure we reset the color
        # TODO: Only do it if ansi colors are enabled
        bw.Write(Chunk(ChunkType.Stdout, char(0x1B) + "[0m"))
        bw.Write(Chunk(ChunkType.Stderr, char(0x1B) + "[0m"))

    def OnStdOut(s):
        bw.Write(Chunk(ChunkType.Stdout, s))

    def OnStdErr(s):
        bw.Write(Chunk(ChunkType.Stderr, s))



class Connection:
""" Handles the interaction with a client.
    The operation is thread safe to allow the daemon to serve
    multiple clients in parallel.
"""
    pool as AppDomainPool
    client as TcpClient
    heartbeat as Stopwatch

    bw as NailgunWriter

    def constructor(pool as AppDomainPool):
        self.pool = pool

    def Process(client as TcpClient):
        self.client = client

        stream = client.GetStream()
        br = NailgunReader(stream)
        bw = NailgunWriter(stream)

        # Run an interval timer to check the heartbeat
        self.heartbeat = Stopwatch()
        timer = Timers.Timer(500)
        timer.Elapsed += CheckHeartbeat
        timer.Enabled = true

        # Instantiate a new command model
        command = Command()

        sw = Stopwatch()
        try:
            while true:
                chunk = br.ReadChunk()
                #print "Type: $(chunk.Type) -- $(chunk.Data) -- $(heartbeat.ElapsedMilliseconds)"

                match chunk.Type:
                    case ChunkType.Heartbeat:
                        heartbeat.Restart()

                    case ChunkType.Argument:
                        command.Args.Add(chunk.Data)

                    case ChunkType.Environment:
                        key, value = chunk.Data.Split((char('='),), 2)
                        command.Env[key] = value

                    case ChunkType.WorkingDirectory:
                        command.WorkingDirectory = chunk.Data

                    case ChunkType.Command:
                        command.Program = chunk.Data

                        print "Running $(command.Program)"

                        try:
                            sw.Restart()

                            # Acquire a new runner from the bound domain
                            runner = self.pool.Acquire(command.Program)

                            sw.Stop()
                            if sw.Elapsed > 50ms:
                                print "[Debug] Waited for {0}ms to acquire a runner" % (sw.ElapsedMilliseconds,)
                            sw.Start()

                            using StreamsProxy(runner, bw):
                                exitCode = command.Run(runner)

                        except ex:
                            bw.Write(Chunk(ChunkType.Stderr, "[nailgun] Error running program: $ex"))
                            exitCode = 128

                        # Release the domain as soon as we're done with it
                        # TODO: The reload/preparation step should be configurable
                        # self.pool.Release(program)

                        # Notify the client the exit code
                        bw.Write(Chunk(ChunkType.Exit, exitCode.ToString()))
                        bw.Flush()

                        sw.Stop()
                        print "Exited with code $exitCode after {0}ms" % (sw.ElapsedMilliseconds,)

                        sw.Restart()
                        runner = self.pool.Reload(command.Program)
                        sw.Stop()
                        print "Domain reloading took {0}ms" % (sw.ElapsedMilliseconds,)

                        sw.Restart()
                        runner.Prepare()
                        sw.Stop()
                        print "Domain preparation took {0}ms" % (sw.ElapsedMilliseconds,)

                        break

                    otherwise:
                        print "Unknown chunk type: '$(chunk.Data)'"

        ensure:
            # Make sure we release the lock on the domain
            if command.Program:
                self.pool.Release(command.Program)

            # Clean up disposable resources
            br.Dispose()
            bw.Dispose()
            stream.Dispose()
            timer.Dispose()


    def CheckHeartbeat(source, evt):
        # If the heartbeat is not running just ignore the check since it 
        # may mean that it's a legacy client without heartbeat support
        # or that we are still in the setup phase.
        return unless heartbeat.IsRunning

        if heartbeat.ElapsedMilliseconds > 1000:
            print "Oh my God, they killed Kenny! ...You bastards!"


