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
	Joined ChannelName String | -- message to a channel
	Departed ChannelName String | -- message to a channel
	Members ChannelName (Set.Set ClientName) | -- message to a channel
	Command String -- command sent by client 

-- send message to a client
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = do 
	writeTChan clientSendChan msg

-- broadcast a message to all clients
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
	clientMap <- readTVar clients
	mapM_ (\client -> sendMessage client msg) (Map.elems clientMap)

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

sendMessageToChannel :: Channel -> Message -> STM ()
sendMessageToChannel Channel{..} msg = writeTChan channelTChan msg



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

removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} clientName = atomically $ do
	modifyTVar' clients $ Map.delete clientName
	broadcast server $ Notice (clientName ++ " left")



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
  							runClient server client `finally` removeClient server name

runClient :: Server -> Client -> IO ()
runClient srv@Server{..} client@Client{..} = do
	race (server srv client) (receive client)
	return ()

receive :: Client -> IO ()
receive client@Client{..} = forever $ do 
	msg <- hGetLine clientHandle
	atomically $ sendMessage client (Command msg)

server :: Server -> Client -> IO ()
server srv@Server{..} client@Client{..} = join $ atomically $ do
	kicked <- readTVar clientKicked
	case kicked of
		Just reason -> return $ hPutStrLn clientHandle $
			"You have been kicked for: " ++ reason
		Nothing -> do
			msg <- readTChan clientSendChan
			return $ do
				continue <- handleMessage srv client msg
				when continue $ server srv client

handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage srv@Server{..} client@Client{..} message =
	case message of
		Notice msg -> output $ "!! " ++ msg ++ " !!"

		Tell senderName msg -> output $ "*" ++ senderName ++"*: " ++ msg

		TellAll senderName msg -> output $ "<" ++ senderName ++">: " ++ msg

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
					atomically $ broadcast srv $ TellAll clientName msg
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


joinChannel :: Server -> Client -> ChannelName -> IO ()
joinChannel srv@Server{..} client@Client{..} channelName = do
	-- check if client already is in channel
	clientChannelsMap <- atomically $ readTVar clientChannels
	hPutStrLn clientHandle "[DEBUG] Check if you are already in channel"
	unless (Map.member channelName clientChannelsMap) $ do
		-- check if channel already exists
		serverChannelsMap <- atomically $ readTVar serverChannels
		channel@Channel{..} <- case Map.lookup channelName serverChannelsMap of
			Just (channel@Channel {..}) -> do
				hPutStrLn clientHandle "[DEBUG] Channel already exists, adding you to it"
				-- channel found, add client to it
				atomically $ modifyTVar' channelClients $ Set.insert clientName
				return channel
			Nothing -> do
				-- channel not found, create it
				hPutStrLn clientHandle "[DEBUG] Channel does not exist, creating it.."
				channel <- atomically $ newChannel channelName $ Set.singleton clientName
				atomically $ modifyTVar' serverChannels $ Map.insert channelName channel
				return channel
		
		clientChannel <- atomically $ dupTChan channelTChan
		hPutStrLn clientHandle $ "[DEBUG] channel = " ++ channelName ++ " client = " ++ clientName
		atomically $ modifyTVar' clientChannels $ Map.insert channelName clientChannel
		atomically $ sendMessageToChannel channel (Joined channelName clientName)


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
