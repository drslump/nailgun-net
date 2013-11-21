# Nailgun-Net

Nailgun-Net is a tool to speed up the start up of .Net applications

It keeps itself running in the background listening for commands
on a tcp socket. When running an application it communicates with
the background process to actually execute the program in a warmed
up AppDomain.

While it works in a completely different way from the [Nailgun tool
for Java](http://www.martiansoftware.com/nailgun/), it's compatible
with its protocol and so it can be used with the standard nailgun
client (`ng`).


## How it works

- For each program an AppDomain is created
- The program is executed in the AppDomain
- The AppDomain is destroyed (resources are freed)
- In the background a new AppDomain is created
  - Call Nailgun.Prepare() in the program assembly
  - Default: Preload assemblies in same directory and prejit methods in domain
- Next execution uses the warmed up AppDomain


## How good is it?

The prototype shows some very good speed ups, without implementing a
customized `Prepare` method in the target program the improvement is
around a 20-30% for simple command line utilities.

When using a specialized `Prepare` method it shows up to a 100% speed
increase for moderately complex programs, like the Boo compiler.


## Is it compatible with my app?

The algorithm is designed to improve the compatibility with most
programs and reduce the risk of introducing bugs in them. Unlike
the Java version of Nailgun, the static state is not shared across
different executions, each program is run a clean AppDomain.


## How can I make my app faster?

When loading the program assembly it will look for a static method
named `Prepare` in the type `Nailgun`. If it's found the method
will be invoked to warm up the background AppDomain for the next
execution.

You can put your logic in this method to prepare your application
environment for the next execution. From loading assemblies to
fill up caches.

If the method returns a truthy value the default actions will be
omitted, otherwise any assembly in the same directory will be
loaded and will try to trigger Jit compilation for all the methods
in them (Note: this is not supported in Mono).


## Roadmap

-[x] Prototype
-[ ] Shadow copy of pre-loaded assemblies
-[ ] Windows support
-[ ] Standard input stream support
-[ ] Multi threaded server
-[ ] Signal handling
-[ ] Automatic server spawning


## License

MIT
