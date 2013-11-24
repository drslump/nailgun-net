namespace nailgun

from System import AppDomain, Threading, DateTime
from System.Collections.Generic import IComparer, SortedSet
from System.Collections.Concurrent import ConcurrentDictionary, ConcurrentQueue
from System.Reflection import BindingFlags


class AppDomainPool:
""" Controls a pool of AppDomains to be used for running commands.
    The pool must ensure thread safety since competing threads
    might want to acquire a domain at the same time

    TODO: Add some way to automatically destroy AppDomains after
          a certain amount of time.

    TODO: Refactor needed. Too complex and most probably full of bugs :(
"""

    class Entry:
        property Program as string
        property Domain as AppDomain
        property Locked as bool
        property LastUsed as DateTime

    class EntryComparer(IComparer[of Entry]):
        def Compare(x as Entry, y as Entry) as int:
            if x.LastUsed < y.LastUsed:
                return -1
            return 1


    property MaxDomains = 10

    _domains = ConcurrentDictionary[of string, Entry]()
    _sorted = SortedSet[of Entry](EntryComparer())
    _warmed = ConcurrentQueue[of AppDomain]()

    protected def CreateRunner(command as Command, domain as AppDomain):
        runner as AppDomainRunner = domain.CreateInstanceAndUnwrap(
            typeof(AppDomainRunner).Assembly.FullName,
            typeof(AppDomainRunner).FullName,
            false,
            BindingFlags.Public | BindingFlags.Instance,
            null,
            (command,),
            null,
            null
        )
        return runner

    protected def Create(program):
        # Remove oldest released AppDomain if we have reached the limit
        while _domains.Count >= MaxDomains:
            lock _sorted:
                for entry in _sorted:
                    # Skip those that haven't been released yet
                    continue if entry.Locked
                    Remove(entry.Program)
                    break

        domain as AppDomain
        _warmed.TryDequeue(domain)
        if not domain:
            domain = AppDomain.CreateDomain(program)

        lock _sorted:
            entry = Entry(Program: program, Domain: domain, LastUsed: DateTime.Now)
            _sorted.Add(entry)

        return entry

    def Warmup():
    """ Creates a series of AppDomains waiting to be used """
        while len(_warmed) < MaxDomains - len(_domains):
            domain = AppDomain.CreateDomain('warmed-' + len(_warmed))
            _warmed.Enqueue(domain)

    def Acquire(command as Command) as AppDomainRunner:
    """ Acquire a domain associated to the program and lock on it """
        target = _domains.GetOrAdd(command.Program, Create)

        # Lock on the domain instance
        Threading.Monitor.Enter(target)
        target.Locked = true
        print "Locking on $command (domain: $(target.Domain))"

        return CreateRunner(command, target.Domain)

    def Release(program):
    """ Release the lock on the domain associated to the program """
        target as Entry

        _domains.TryGetValue(program, target)
        if target:
            lock _sorted:
                # Looks inefficient but the list is small
                for entry in _sorted:
                    if entry is target:
                        # The data container doesn't allow replacing
                        _sorted.Remove(entry)
                        entry.LastUsed = DateTime.Now
                        _sorted.Add(entry)
                        break

            print "Release $program (domain: $(target.Domain))"
            target.Locked = false
            Threading.Monitor.Exit(target)

    def Reload(command as Command):
        target as Entry
        _domains.TryRemove(command.Program, target)
        lock _sorted:
            _sorted.Remove(target)

        print "Reload: $(target.Domain)"

        prevDomain = target

        # Ask for a new one before lifting the lock on the previous
        runner = Acquire(command)

        # Lift the lock on the previous one
        target.Locked = false
        Threading.Monitor.Exit(target)

        print "Disposing: $(target.Domain)"
        AppDomain.Unload(target.Domain)

        return runner

    def Remove(program):
    """ Removes a given domain from the pool """
        target as Entry
        _domains.TryRemove(program, target)
        if not target:
            raise "Unable to remove AppDomain"

        Release(program)

        lock _sorted:
            _sorted.Remove(target)

        print "Disposing: $(target.Domain)"
        AppDomain.Unload(target.Domain)

