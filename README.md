## Slat - Chat Server

### Description

Slat is a chat server written in Haskell using STM (software transactional memory). Slat users can:

- send a private message to another user

- send a public message to all users logged in

- create a private channel

- join a private channel

- send a message to private channel users

- retrieve the members of a private channel

- leave a private channel

- log in / out

### Starting the server

- Execute `./Main` on a Linux machine. The **server** will run on `localhost`, port `2233`.

- The executable is present so the compilation phase can be skipped. Otherwise, install Haskell GHC compiler and compile the `Main.hs` file.

- To connect as a **client**, netcat can be used: `nc localhost 2233`. Type your name and start sending messages.

### Commands available

A command is prefixed by `/` and it must be the first word within the message. Any message that does not have a command at the beginning will be treated like a public/broadcast message to all other users.

- `/tell <userName> <message>`
    + Send `message` to user with name `userName`
- `/tellChan <channelName> <message>`
    + Send `message` to users that are part of private channel `channelName`
- `/join <channelName`
    + Join private channel `channelName`
    + If the channel does not exist, it will be created
- `/leave <channelName`
    + Leave private channel `channelName`
- `/members <channelName>`
    + Retrieve list of members of channel `channelName`
- `/quit`
    + Log out (exit application)

### Software transactional memory

- Software transactional memory is a paradigm created as a alternate way to avoid deadlocks and synchronization problems between threads. The traditional way of doing this is using synchronization mechanisms like locks, semaphors, monitors. STM takes an optimistic view regarding race conditions, as it supposes that they happen rarely in the real world.

- At the core of STM there is the concept of **transaction** (like in database world). Transactions are represented multiple instructions that are executed atomically (they either execute fully or they don't). A thread running a transaction cannot observe an intermediary state of another transaction.

- When a transaction is started some variables/data are saved and isolated from the real world. The transaction takes a _snapshot_ of the world when it begins. Then, inside the transaction, these variable are changed and these modifications are stored in a in-memory log. The transactional variables can be changed outside the transaction, by other threads, but this will not impact the running transaction. At the end of the transaction (_commit phase_), the value of the variables inside the transaction are checked against the values from outside the transaction (the real world). If the transaction is consistent and no other threads have made changes to those values, the changes take effect outside the transaction.

- If a transaction cannot be commited, due to other threads messing with the transactional variables, it is aborted and retried.