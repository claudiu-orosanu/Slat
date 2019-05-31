module Main where

import Network (withSocketsDo, listenOn, PortID(..), accept)
import Text.Printf (printf, hPrintf)
import Control.Monad (forever)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import System.IO (Handle, hSetBuffering, BufferMode(..), hGetLine, hClose, hPutStrLn, stdout,
				  hSetNewlineMode, universalNewlineMode)
import Control.Exception (finally)

port = 2233 :: Int

main = withSocketsDo $ do
	sock <- listenOn (PortNumber (fromIntegral port))
	printf "Listening on port %d\n" port
	factor <- atomically $ newTVar 2
	forever $ do
		(handle, host, port) <- accept sock
		printf "Accepted connection from %s:%s\n" host (show port)
		forkIO $ (talk handle factor) `finally` (hClose handle)

-- Talk to the client
talk :: Handle -> TVar Integer -> IO ()
talk handle factor = do
	hSetBuffering handle LineBuffering
  	hSetNewlineMode handle universalNewlineMode
  	chan <- atomically newTChan
  	race (server handle factor chan) (receive handle chan)
  	return ()

receive :: Handle -> TChan String -> IO ()
receive handle chan = forever $ do 
	line <- hGetLine handle
	atomically $ writeTChan chan line

server :: Handle -> TVar Integer -> TChan String -> IO()
server handle factor chan = do 
	currFactor <- atomically $ readTVar factor
	hPrintf handle "Current factor: %d\n" currFactor
	loop currFactor
	where 
		loop f = do
			action <- atomically $ do
				f' <- readTVar factor
				if (f /= f')
					then return (newfactor f')
					else do
						line <- readTChan chan
						return (command f line)
			action

		newfactor f = do
			hPrintf handle "new factor: %d\n" f
			loop f

		command f line =
			case line of
				"end" -> hPutStrLn handle ("Thank you for using Slat")
				'*':s -> do
					atomically $ writeTVar factor (read s :: Integer)
					loop f
				_ -> do
					hPutStrLn handle (show (f * (read line :: Integer)))
					loop f
