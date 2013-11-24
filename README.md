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

In essence it will make any program slower, however for repeated executions
the *perceived speed up* is usually considerable, although it varies from
program to program.


## How good is it?

The prototype shows some very good speed ups, without implementing a
customized `Prepare` method in the target program the improvement is
around a 30-50% for simple command line utilities.

When using a specialized `Prepare` method it shows up to a 100% speed
increase for moderately complex programs, like the Boo compiler.


## Is it compatible with my app?

The algorithm is designed to improve the compatibility with most
programs and reduce the risk of introducing bugs in them. Unlike
the Java version of Nailgun, static state is not shared across
different executions, each program is run in a clean AppDomain.
That said, you'll have to try it for yourself.

If your program uses colored output, the server can convert them
to Ansi escape sequences if your terminal supports them. The result
is not 100% correct but works fine enough most of the time.


## How can I make my app faster?

When loading the program assembly it will look for a static method
named `Prepare` in the type `Nailgun`. If it's found the method
will be invoked to warm up the background AppDomain for the next
execution.

You can put your logic in this method to prepare your application
environment for the next execution. From loading assemblies to
filling up caches.

If the method returns a truthy value the default actions will be
omitted, otherwise any assembly in the same directory will be
loaded and will try to trigger Jit compilation for all the methods
in them (Note: this is not supported in Mono).


## Roadmap

- [x] Prototype
- [ ] Shadow copy of pre-loaded assemblies
- [ ] Windows support
- [x] Standard input stream support
- [x] Multi threaded server
- [ ] Signal handling
- [ ] Automatic server spawning
- [ ] Warm up pristine AppDomains in the background
- [ ] Program cancellation on client disconnection
- [ ] Make AppDomain reusing an option 

## License

MIT
