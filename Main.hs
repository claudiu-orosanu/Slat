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
import Data.Map (Map)

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

data Client = Client {
	clientName :: ClientName,
	clientHandle :: Handle,
	clientKicked :: TVar (Maybe String),
	clientSendChan :: TChan Message
}

data Message =
	Notice String | -- message from server
	Tell ClientName String | -- private message from other cleint
	Broadcast ClientName String | -- public message from other client
	Command String -- command sent by client 


newClient :: ClientName -> Handle -> STM Client
newClient name handle = do
	kicked <- newTVar Nothing
	chan <- newTChan
	return Client {
		clientName = name,
		clientHandle = handle,
		clientKicked = kicked,
		clientSendChan = chan
	}

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = do 
	writeTChan clientSendChan msg

------- Server Data -------

data Server = Server {
	clients :: TVar (Map ClientName Client)
}

newServer :: IO Server
newServer = do
	c <- newTVarIO Map.empty
	return Server { clients = c }

broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
	clientMap <- readTVar clients
	mapM_ (\client -> sendMessage client msg) (Map.elems clientMap)

------------------------------------------------------------

validateAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
validateAddClient server@Server{..} clientName handle = atomically $ do
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

sendTo :: Server -> ClientName -> Message -> STM Bool
sendTo srv@Server{..} clientName msg = do
	clientMap <- readTVar clients
	case Map.lookup clientName clientMap of
		Nothing -> return False
		Just client -> sendMessage client msg >> return True

tell :: Server -> Client -> ClientName -> String -> IO ()
tell srv@Server{..} client@Client{..} who msg = do
	ok <- atomically $ sendTo srv who (Tell clientName msg)
	if ok
		then return ()
		else hPutStrLn clientHandle (who ++ " is not connected")


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
  					ok <- validateAddClient server name handle
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
		Tell name msg -> output $ "*" ++ name ++"*: " ++ msg
		Broadcast name msg -> output $ "<" ++ name ++">: " ++ msg
		Command msg ->
			case words msg of
				-- ["/kick", who] -> do
				-- 	atomically $ kick server who clientName
				-- 	return True
				"/tell" : who : what -> do
					tell srv client who (unwords what)
					return True
				["/quit"] -> do
					hPutStrLn clientHandle "Thank you for using Slat!"
					return False
				('/':_):_ -> do
					hPutStrLn clientHandle $ "Unrecognized command: " ++ msg
					return True
				_ -> do
					atomically $ broadcast srv $ Broadcast clientName msg
					return True
	where
		output s = do hPutStrLn clientHandle s; return True

