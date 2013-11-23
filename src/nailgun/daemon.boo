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
from System.IO import Path, Directory, EndOfStreamException, IOException, TextWriter, TextReader
from System.Threading import ThreadPool


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


def server(argv as (string)):

    port = (argv[0] if len(argv) > 0 else 2113)
    listener = TcpListener(IPAddress.Loopback, port)
    listener.Start()

    print "nailgun-net daemon started on port $port"

    # Bootstrap an AppDomain pool
    pool = AppDomainPool()

    while true:
        # Wait for a new connection
        client = listener.AcceptTcpClient()
        print "Incoming command..."

        # TODO: Don't we have to close/dispose the client?
        conn = Connection(pool)
        # Serve the client in a thread
        ThreadPool.QueueUserWorkItem(conn.Process, client)

        dumpMemoryUsage()


server(argv)
