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
"""

    class Entry:
        property Program as string
        property Domain as AppDomain
        property LastUsed as DateTime

    class EntryComparer(IComparer[of Entry]):
        def Compare(x as Entry, y as Entry) as int:
            if x.LastUsed < y.LastUsed:
                return -1
            return 1


    property MaxDomains = 10

    _domains = ConcurrentDictionary[of string, AppDomain]()
    _sorted = SortedSet[of Entry](EntryComparer())
    _warmed = ConcurrentQueue[of AppDomain]()

    protected def CreateRunner(program as string, domain as AppDomain):
        runner as AppDomainRunner = domain.CreateInstanceAndUnwrap(
            typeof(AppDomainRunner).Assembly.FullName,
            typeof(AppDomainRunner).FullName,
            false,
            BindingFlags.Public | BindingFlags.Instance,
            null,
            (program,),
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
                    if Threading.Monitor.IsEntered(entry.Domain):
                        continue
                    Remove(entry.Program)
                    break

        domain as AppDomain
        _warmed.TryDequeue(domain)
        if not domain:
            domain = AppDomain.CreateDomain(program)

        lock _sorted:
            entry = Entry(Program: program, Domain: domain, LastUsed: DateTime.Now)
            _sorted.Add(entry)

        return domain

    def Warmup():
    """ Creates a series of AppDomains waiting to be used """
        while len(_warmed) < MaxDomains - len(_domains):
            domain = AppDomain.CreateDomain('warmed-' + len(_warmed))
            _warmed.Enqueue(domain)

    def Acquire(program) as AppDomainRunner:
    """ Acquire a domain associated to the program and lock on it """
        domain = _domains.GetOrAdd(program, Create)

        # Lock on the domain instance
        Threading.Monitor.Enter(domain)
        print "Locking on $domain"

        return CreateRunner(program, domain)

    def Release(program):
    """ Release the lock on the domain associated to the program """
        domain as AppDomain

        _domains.TryGetValue(program, domain)
        if domain:
            lock _sorted:
                # Looks inefficient but the list is small
                for entry in _sorted:
                    if entry.Domain is domain:
                        # The data container doesn't allow replacing
                        _sorted.Remove(entry)
                        entry.LastUsed = DateTime.Now
                        _sorted.Add(entry)
                        break

            print "Release $domain"
            Threading.Monitor.Exit(domain)

    def Reload(program as string):
        domain as AppDomain
        _domains.TryRemove(program, domain)

        # Ask for a new one before lifting the lock on the previous
        runner = Acquire(program)

        # Lift the lock on the previous one
        Threading.Monitor.Exit(domain)

        # Update the entry to reflect the new domain instance
        for entry in _sorted:
            if entry.Domain is domain:
                entry.Domain = runner.Domain
                break

        lock domain:
            AppDomain.Unload(domain)

        return runner

    def Remove(program):
    """ Removes a given domain from the pool """
        domain as AppDomain
        _domains.TryRemove(program, domain)
        if not domain:
            raise "Unable to remove AppDomaindomain"

        Release(program)

        lock _sorted:
            for entry in _sorted:
                if entry.Domain is domain:
                    _sorted.Remove(entry)
                    break

        lock domain:
            AppDomain.Unload(domain)

