module Main where

import Network (withSocketsDo, listenOn, PortID(..), accept)
import Text.Printf (printf)
import Control.Monad (forever)
import Control.Concurrent (forkIO)
import System.IO (Handle, hSetBuffering, BufferMode(..), hGetLine, hClose, hPutStrLn, stdout)
import Control.Exception (finally)

port = 2233 :: Int

main = withSocketsDo $ do
	sock <- listenOn (PortNumber (fromIntegral port))
	printf "Listening on port %d\n" port
	forever $ do
		(handle, host, port) <- accept sock
		printf "Accepted connection from %s:%s\n" host (show port)
		forkIO $ (talk handle stdout) `finally` (hClose handle)

-- Talk to the client
talk :: Handle -> Handle -> IO ()
talk handle hParentStdout = do
	hSetBuffering handle LineBuffering
	loop
	where loop = do
		line <- hGetLine handle
		hPutStrLn hParentStdout $ "Received string = " ++ line
		case line of 
			'e':'n':'d':_ -> hPutStrLn handle ("Thank you for using Slat")
			otherwise -> do
				hPutStrLn handle (show $ 2 * (read line :: Integer))
				loop
				
