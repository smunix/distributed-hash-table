# distributed-hash-table

A Haskell implementation of distributed hash tables with distributed two-phase commit.
The views can hold locks, and have replicas that they always communicate with to achieve quorum-based consensus.

Written as a project for COMP 360 Distributed Systems, Fall 2016, Prof. Jeff
Epstein, Wesleyan University.

![Diagram](http://i.imgur.com/Ao8MzVQ.png)

## Installation

Make sure you have [Stack](http://haskellstack.org) installed.

Clone the repository and run `stack install`. The executable files
`dht-client`, `dht-server`, `dht-view-leader` must now be `~/.local/bin`, which
is probably in your path variable.

## Usage

You can run the server without any command line arguments: `dht-server`.

For `dht-client` and `dht-view-leader`, you can see all the options using the `--help` flag.

The executable  `dht-client` take optional arguments `--server` (or `-s`) and
`--viewleader` (or `-l`) that specifies which host to connect , such a call
would be of the form

```
dht-client --server 127.0.0.1 setr "lang" "Türkçe"
```

The executable `dht-server` also takes the `--viewleader` optional argument, to
be able to perform heartbeats.

If the optional argument `--server` isn't provided, it is assumed to be the local computer name.

The optional argument `--viewleader` (or with its short form `-l`) can be passed multiple times for each view replica, such as:

```
dht-view-leader -l mycomputer:39000 -l mycomputer:39001 -l mycomputer:39002 -l mycomputer:39003 -l mycomputer:39004
```

If the optional argument `--viewleader` isn't provided, it is assumed that there are 3 default inputs: your computer name with the ports 39000, 39001 and 39002.

### Timeouts

If a connection to a host name and a port, or a bind to a port doesn't happen
in 10 seconds, you will get a timeout error and the program will try the next
available port number.

If a server fails to send a heartbeat for 30 seconds, but then later succeeds,
it will be told by the view leader that it expired. In that case, the server
terminates.

### Locks and deadlock detection


When there is a request for a lock that receives the retry message, that client
is added to the queue for that lock. Even though the client stops asking, it will
get the lock when the clients that are waiting in front of it in the queue get
and release the lock.

The view leader assumes that a server crashed if it sends no heartbeat for 30
seconds.  In that case, if that server holds any locks (that have the requester
identifier format `:38000`, where the number is the port) are cancelled
automatically.

When the server has to return retry for a lock get request, it checks if there
is a deadlock in the system by building a directed graph and looking for
cycles. If there is, it logs the requesters and locks involved. Right now, it
repeatedly logs the same deadlock information as long as it keeps getting the
request. Since the client keeps retrying by default, it will not stop logging
the deadlock unless the client is stopped. If a requester ID is used for
multiple lock requests at the same time, this can cause some weird behavior.

*Deadlock detection is currently deactivated, will be reactivated after refactoring for consensus.*

### Bucket allocator

We assume that our hash function evenly distributes strings to integers. We
take the UUID of every server to be the string for its hash, i.e. the hash
value of the server. Therefore we assume that our servers more or less evenly
split the number of keys we want to hold. The primary bucket to hold a key is
the bucket that has the server that has the lowest hash value that still is
strictly greater than the hash of the key string. We hold 2 more replicas as
backup, in servers that have the next 2 lowest hash value.

### Rebalancing

If some servers are removed, then each server will check if the keys they
currently hold used to reside in one of the servers that are removed.  If
that's the case, then it will make a request to the new server that is suppose
to hold the data, to save the data.

When there are new servers, each server will check what keys they have.  If a
server has a key that should reside in a different server now, it will make a
request to that different server and then delete that key from itself.
