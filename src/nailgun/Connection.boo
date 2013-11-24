namespace nailgun

from System import Timers, Threading, MarshalByRefObject, IDisposable
from System.Net.Sockets import TcpClient
from System.IO import Path
from System.Diagnostics import Stopwatch
from System.Collections.Concurrent import BlockingCollection

import Boo.Lang.PatternMatching



class Connection:
""" Handles the interaction with a client.
    The operation is thread safe to allow the daemon to serve
    multiple clients in parallel.
"""

    class StreamsProxy(MarshalByRefObject, IDisposable):
    """ Allows to subscribe to events in the AppDomain without having
        to remote with the whole Connection type.
    """
        _runner as AppDomainRunner
        _reader as NailgunReader
        _writer as NailgunWriter
        _heartbeat as Stopwatch
        _timer as Timers.Timer

        _stdinQueue = BlockingCollection[of string]()
        _stdinCurrent = ''
        _stdinOffset = 0

        def constructor(runner as AppDomainRunner, reader as NailgunReader, writer as NailgunWriter):
            _reader = reader
            _writer = writer
            _runner = runner

            # Bind to the runner output streams events
            _runner.StdIn = OnStdIn
            _runner.StdOut = OnStdOut
            _runner.StdErr = OnStdErr

            # Run an interval timer to check the heartbeat
            _heartbeat = Stopwatch()
            _timer = Timers.Timer(500)
            _timer.Elapsed += OnCheckHeartbeat
            _timer.Enabled = true

            # Collect chunks in a separate thread
            Threading.ThreadPool.QueueUserWorkItem(ChunksConsumer)

        def Dispose():
            _timer.Dispose()

        _stdinFirst = false
        def OnStdIn() as int:
        """ Provides the next character available in stdin
            NOTE: Highly inefficient right now but it seems to work :)
        """
            # To optimize a bit the execution of commands consuming
            # from stdin we always request input from the client
            if not _stdinFirst:
                _stdinFirst = true
                _writer.Write(Chunk(ChunkType.InputStart))
			
			# It seems that we had reached the EOS before
            if _stdinCurrent is null:
                print "[DEBUG] StdIn requested after the EOS was received"
                return -1

            # Check if we need a new chunk from stdin (note that it blocks)
            if _stdinOffset >= len(_stdinCurrent):
                _stdinOffset = 0
                _stdinCurrent = _stdinQueue.Take()

            # Just give up if we have reached the end of the stream
            if _stdinCurrent is null:
                print "[DEBUG] StdIn EOS found"
                return -1

            ch = _stdinCurrent[_stdinOffset]
            _stdinOffset += 1
            return ch

        def OnStdOut(s):
            _writer.Write(Chunk(ChunkType.Stdout, s))

        def OnStdErr(s):
            _writer.Write(Chunk(ChunkType.Stderr, s))

        def ChunksConsumer():


            while true:
                try:
                    chunk = _reader.ReadChunk()
                    if chunk.Type == ChunkType.Heartbeat:
                        _heartbeat.Restart()
                    elif chunk.Type == ChunkType.Stdin:
                        if _heartbeat.IsRunning:
                            _heartbeat.Restart()
                        _stdinQueue.Add(chunk.Data)
                        # Notify the client we want another input chunk
                        _writer.Write(Chunk(ChunkType.InputStart))
                    elif chunk.Type == ChunkType.InputEnd:  # ie: Ctrl+D
                        _stdinQueue.Add(null)

                except ex as System.NullReferenceException:   # Mono
                    break
                except ex as System.ObjectDisposedException:  # .Net
                    break
                except ex as System.IO.EndOfStreamException:
                    break
                except ex as System.IO.IOException:  # .Net (Unable to read data from transport connection: An existing connections was forcibly closed by remote host)
                    break

            print "ChunksConsumer terminated"
            if _runner.IsRunning:
                _runner.Terminate()

        def OnCheckHeartbeat(source, evt):
            # If the heartbeat is not running just ignore the check since it 
            # may mean that it's a legacy client without heartbeat support
            # or that we are still in the setup phase.
            return unless _heartbeat.IsRunning

            if _runner.IsRunning and _heartbeat.ElapsedMilliseconds > 1000:
                print "Oh my God, they killed Kenny! ...You bastards!"
                _runner.Terminate()


    pool as AppDomainPool
    client as TcpClient

    def constructor(pool as AppDomainPool):
        self.pool = pool

    def Process(client as TcpClient):
        self.client = client

        stream = client.GetStream()
        reader = NailgunReader(stream)
        writer = NailgunWriter(stream)

        # Instantiate a new command model
        command = Command()

        sw = Stopwatch()
        try:
            while true:
                chunk = reader.ReadChunk()
                #print "Type: $(chunk.Type) -- $(chunk.Data) -- $(heartbeat.ElapsedMilliseconds)"

                match chunk.Type:
                    case ChunkType.Heartbeat:
                        print "Unexepected Heartbeat chunk. Command chunk not received yet"
                    case ChunkType.Stdin:
                        print "Unexepected Stdin chunk. Command chunk not received yet"
                    case ChunkType.InputEnd:
                        print "Unexpected Stdin EOF chunk"

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
                            runner = self.pool.Acquire(command)

                            sw.Stop()
                            if sw.Elapsed > 50ms:
                                print "[Debug] Waited for {0}ms to acquire a runner" % (sw.ElapsedMilliseconds,)
                            sw.Start()

                            using StreamsProxy(runner, reader, writer):
                                exitCode = runner.Execute()

                        except ex:
                            writer.Write(Chunk(ChunkType.Stderr, "[nailgun] Error running program: $ex"))
                            exitCode = 128

                        # Release the domain as soon as we're done with it
                        # TODO: The reload/preparation step should be configurable
                        # self.pool.Release(program)

                        # Notify the client the exit code
                        writer.Write(Chunk(ChunkType.Exit, exitCode.ToString()))
                        writer.Flush()

                        sw.Stop()
                        print "Exited with code $exitCode after {0}ms" % (sw.ElapsedMilliseconds,)

                        sw.Restart()
                        runner = self.pool.Reload(command)
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
            reader.Dispose()
            writer.Dispose()
            stream.Dispose()
