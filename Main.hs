{-# LANGUAGE RecordWildCards #-}

module Main where

import Network (withSocketsDo, listenOn, PortID(..), accept)
import Text.Printf (printf, hPrintf)
import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import System.IO (Handle, hSetBuffering, BufferMode(..), hGetLine, hClose, hPutStrLn, stdout,
				  hSetNewlineMode, universalNewlineMode)
import Control.Exception (finally)

import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Map (Map)
import Data.Set (Set)

port = 2233 :: Int

main :: IO ()
main = withSocketsDo $ do
	server <- newServer
	sock <- listenOn (PortNumber (fromIntegral port))
	printf "Listening on port %d\n" port
	factor <- atomically $ newTVar 2
	forever $ do
		(handle, host, port) <- accept sock
		printf "Accepted connection from %s:%s\n" host (show port)
		forkIO $ (talk handle server) `finally` (hClose handle)


--------------- Data types ---------------

------- Client Data -------

type ClientName = String
type ChannelName = String

data Client = Client {
	clientName :: ClientName,
	clientHandle :: Handle,
	clientKicked :: TVar (Maybe String),
	clientSendChan :: TChan Message,
	clientChannels :: TVar (Map.Map ChannelName (TChan Message))
}

data Channel = Channel { 
	channelName  :: ChannelName,
    channelClients :: TVar (Set ClientName),
    channelTChan  :: TChan Message
}

newClient :: ClientName -> Handle -> STM Client
newClient name handle = do
	kicked <- newTVar Nothing
	chan <- newTChan
	clientChannels <- newTVar Map.empty
	return Client {
		clientName = name,
		clientHandle = handle,
		clientKicked = kicked,
		clientSendChan = chan,
		clientChannels = clientChannels
	}

newChannel :: ChannelName -> Set ClientName -> STM Channel
newChannel name clients = do
	clients <- newTVar clients
	chan <- newBroadcastTChan
	return Channel {
		channelName = name,
		channelClients = clients,
		channelTChan = chan
	}

------- Server Data -------

data Server = Server {
	clients :: TVar (Map ClientName Client),
	serverChannels :: TVar (Map ChannelName Channel)
}

newServer :: IO Server
newServer = do
	clients <- newTVarIO Map.empty
	channels <- newTVarIO Map.empty
	return Server { 
		clients = clients,
		serverChannels = channels
	}

------- Messages -------

data Message =
	Notice String | -- message from server
	Tell ClientName String | -- private message from other cleint
	TellAll ClientName String | -- public message from other client
	TellChan ChannelName ClientName String | -- message to a channel
	Joined ChannelName String | -- message to a channel
	Departed ChannelName String | -- message to a channel
	Members ChannelName (Set.Set ClientName) | -- message to a channel
	Command String -- command sent by client 

-- send message to a client
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = do 
	writeTChan clientSendChan msg

-- send message to a channel
sendMessageToChannel :: Channel -> Message -> STM ()
sendMessageToChannel Channel{..} msg = writeTChan channelTChan msg

-- broadcast a message to all clients
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
	clientMap <- readTVar clients
	mapM_ (\client -> sendMessage client msg) (Map.elems clientMap)


-- broadcast a message to all clients but the sender
broadcastExcludeSender :: Server -> ClientName -> Message -> STM ()
broadcastExcludeSender Server{..} who msg = do
	clientMap <- readTVar clients
	mapM_ (\client@Client{..} -> unless (clientName == who) $ sendMessage client msg) (Map.elems clientMap)


------------------------------------------------------------

validateAndAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
validateAndAddClient server@Server{..} clientName handle = atomically $ do
	clientMap <- readTVar clients
	if Map.member clientName clientMap
		then return Nothing
		else do
			client <- newClient clientName handle
			writeTVar clients $ Map.insert clientName client clientMap
			broadcast server $ Notice (clientName ++ " joined")
			return (Just client)

removeClient :: Server -> Client -> IO ()
removeClient server@Server{..} client@Client{..} = do
	atomically $ modifyTVar' clients $ Map.delete clientName
	clientChannelsMap <- atomically $ readTVar clientChannels
	mapM_ (\channelName -> leaveChannel server client channelName) $ Map.keys clientChannelsMap
	atomically $ broadcast server $ Notice (clientName ++ " left")

-- Talk to the client
talk :: Handle -> Server -> IO ()
talk handle server@Server{..} = do
	hSetBuffering handle LineBuffering
  	hSetNewlineMode handle universalNewlineMode
  	readName
  	where
  		readName = do
  			hPutStrLn handle "Enter your name:"
  			name <- hGetLine handle
  			if null name
  				then readName
  				else do
  					ok <- validateAndAddClient server name handle
  					case ok of 
  						Nothing -> do
  							hPutStrLn handle "Name already in use. Please enter another name."
  							readName
  						Just client -> do
  							runClient server client `finally` removeClient server client

runClient :: Server -> Client -> IO ()
runClient srv@Server{..} client@Client{..} = do
	race (server srv client) (receiveCommandsFromClient client)
	return ()

receiveCommandsFromClient :: Client -> IO ()
receiveCommandsFromClient client@Client{..} = forever $ do 
	msg <- hGetLine clientHandle
	atomically $ sendMessage client (Command msg)

server :: Server -> Client -> IO ()
server srv@Server{..} client@Client{..} = do
	-- try to read from all client channels, retry if there is no message
	msg <- atomically $ do 
		clientChannelsMap <- readTVar clientChannels
		foldr (orElse . readTChan) retry (clientSendChan : Map.elems clientChannelsMap)
	
	-- handle the message
	continue <- handleMessage srv client msg
	when continue $ server srv client

handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage srv@Server{..} client@Client{..} message =
	case message of
		-- messages from connected client or other client threads

		Notice msg -> output $ "!! " ++ msg ++ " !!"

		Tell senderName msg -> output $ "*" ++ senderName ++"*: " ++ msg

		TellAll senderName msg -> output $ "<" ++ senderName ++">: " ++ msg

		TellChan chanName senderName msg -> output $ "[" ++ chanName ++ "]" ++ "<" ++ senderName ++ ">: " ++ msg

		Joined channelName who -> output $ who ++ " JOINED CHANNEL " ++ channelName

		Departed channelName who -> output $ who ++ " LEFT CHANNEL " ++ channelName

		Members channelName members -> output $ 
			printf "Members of %s:  %s" channelName . unwords . Set.toList $ members

		Command msg ->
			case words msg of
				-- ["/kick", who] -> do
				-- 	atomically $ kick server who clientName
				-- 	return True
				"/tell" : receiver : what -> do
					tell srv client receiver (unwords what)
					return True
				"/tellChan" : channelName : what -> do
					tellChannel srv client channelName (unwords what)
					return True
				"/join" : channelName -> do
					joinChannel srv client (unwords channelName)
					return True
				"/leave" : channelName -> do
					leaveChannel srv client (unwords channelName)
					return True
				"/members" : channelName -> do 
					getMembers (unwords channelName)
					return True
				["/quit"] -> do
					hPutStrLn clientHandle "Thank you for using Slat!"
					return False
				('/':_):_ -> do
					hPutStrLn clientHandle $ "Unrecognized command: " ++ msg
					return True
				_ -> do
					atomically $ broadcastExcludeSender srv clientName $ TellAll clientName msg
					return True
	where
		output s = do hPutStrLn clientHandle s; return True

		getMembers channelName = do
			ok <- atomically $ do
				serverChannelsMap <- readTVar serverChannels
				case Map.lookup channelName serverChannelsMap of
					Nothing -> return False
					Just (Channel{..}) -> do
						channelClientsSet <- readTVar channelClients
						sendMessage client (Members channelName channelClientsSet)
						return True
			if ok 
				then return ()
				else hPutStrLn clientHandle "Channel does not exist"


-- a client sends a message to another client
tell :: Server -> Client -> ClientName -> String -> IO ()
tell srv@Server{..} client@Client{..} receiverName msg = do
	ok <- atomically $ do
		clientMap <- readTVar clients
		case Map.lookup receiverName clientMap of
			Nothing -> return False
			Just receiver -> do 
				sendMessage receiver (Tell clientName msg)
				return True
	if ok
		then return ()
		else hPutStrLn clientHandle (receiverName ++ " is not connected")

-- a client sends a message to a channel
tellChannel :: Server -> Client -> ChannelName -> String -> IO ()
tellChannel srv@Server{..} client@Client{..} channelName msg = do
	ok <- atomically $ do
		-- check that channel exists
		channelMap <- readTVar serverChannels
		case Map.lookup channelName channelMap of
			Nothing -> return False
			Just (channel@Channel{..}) -> do
				clientChannelsMap <- readTVar clientChannels
				case Map.lookup channelName clientChannelsMap of
					Nothing -> return False
					Just _ -> do 
						sendMessageToChannel channel (TellChan channelName clientName msg)
						return True
	if ok
		then return ()
		else hPutStrLn clientHandle "Channel does not exist or you are not a member"


joinChannel :: Server -> Client -> ChannelName -> IO ()
joinChannel srv@Server{..} client@Client{..} channelName = do
	-- check if client already is in channel
	clientChannelsMap <- atomically $ readTVar clientChannels
	unless (Map.member channelName clientChannelsMap) $ do
		-- check if channel already exists
		serverChannelsMap <- atomically $ readTVar serverChannels
		channel@Channel{..} <- case Map.lookup channelName serverChannelsMap of
			Just (channel@Channel {..}) -> atomically $ do
				-- channel found, add client to it
				modifyTVar' channelClients $ Set.insert clientName
				return channel
			Nothing -> atomically $ do
				-- channel not found, create it
				channel <- newChannel channelName $ Set.singleton clientName
				modifyTVar' serverChannels $ Map.insert channelName channel
				return channel

		atomically $ do
			clientChannel <- dupTChan channelTChan
			modifyTVar' clientChannels $ Map.insert channelName clientChannel
			sendMessageToChannel channel (Joined channelName clientName)


leaveChannel :: Server -> Client -> ChannelName -> IO ()
leaveChannel srv@Server{..} client@Client{..} channelName = do
	-- check if channel already exists
	ok <- atomically $ do
		serverChannelsMap <- readTVar serverChannels
		case Map.lookup channelName serverChannelsMap of
			Nothing -> return False
			Just (channel@Channel{..}) -> do
				-- delete client from channel
				modifyTVar' channelClients $ Set.delete clientName
				channelClientsSet <- readTVar channelClients
				when (Set.null channelClientsSet) $
					-- last user in channel, delete channel from server
					modifyTVar' serverChannels $ Map.delete channelName
				-- delete channel from client channels
				modifyTVar' clientChannels $ Map.delete channelName
				-- notify clients in channel that client has left
				sendMessageToChannel channel (Departed channelName clientName)
				return True
	if ok
		then return ()
		else hPutStrLn clientHandle "You cannot leave a channel that does not exist"
