{-# LANGUAGE DeriveGeneric, OverloadedStrings, LambdaCase #-}
module RPC where

import Data.Aeson
import qualified Data.UUID
import Data.Serialize
import GHC.Generics
import Network.Socket hiding (recv)
import Network.Socket.ByteString (recv, sendAll)
import qualified Data.ByteString.Char8 as B
import System.Timeout
import System.Random
import System.Exit
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Array
import Data.Graph
import qualified STMContainers.Map as M
import Control.Monad.STM
import qualified Data.Sequence.Queue as Q

-- Data types and typeclass instances

type UUIDString = String

data ServerCommand =
    Print String
  | Get String
  | Set String String
  | QueryAllKeys
  deriving (Show, Eq, Generic)

instance Serialize ServerCommand

data ViewLeaderCommand =
    Heartbeat UUIDString ServiceName -- ^ Takes the server's UUID and port.
  | QueryServers
  | LockGet String UUIDString -- ^ Takes a lock name and a requester UUID.
  | LockRelease String UUIDString -- ^ Takes a lock name and a requester UUID.
  deriving (Show, Eq, Generic)

instance Serialize ViewLeaderCommand

data Status =
    Ok
  | NotFound
  | Retry
  | Granted
  | Forbidden
  deriving (Show, Eq)

instance ToJSON Status where
  toJSON st = String $ case st of
    Ok        -> "ok"
    NotFound  -> "not_found"
    Retry     -> "retry"
    Granted   -> "granted"
    Forbidden -> "forbidden"

instance FromJSON Status where
  parseJSON s = case s of
    String "ok"        -> pure Ok
    String "not_found" -> pure NotFound
    String "retry"     -> pure Retry
    String "granted"   -> pure Granted
    String "forbidden" -> pure Forbidden
    _                  -> mempty

data Response =
    Executed             { i :: Int , status :: Status }
  | GetResponse          { i :: Int , status :: Status , value :: String }
  | KeysResponse         { i :: Int , status :: Status , keys :: [String] }
  | QueryServersResponse { i :: Int , epoch  :: Int    , result :: [String] }
  deriving (Show, Eq, Generic)

instance ToJSON Response
instance FromJSON Response

newUUID :: IO UUIDString
newUUID = Data.UUID.toString <$> randomIO

-- Message length values and functions

-- | Standardize the size of the messages in which we send the length of the
-- actual message we will send later.
msgLenBytes :: Int
msgLenBytes = 8

-- | Convert an Int to a String for a given number of max bytes. The max number
-- of bytes should be greater than or equal to the number of digits in the
-- initial Int.
-- This is kind of hacky, it should be replaced with Data.Binary.
intWithCompleteBytes :: Int -- ^ Int that we want to return
                     -> Int -- ^ How many bytes we want to have in the string
                     -> String
intWithCompleteBytes n bytes = let s = show n in
  if length s < bytes then replicate (bytes - length s) '0' ++ s else s

-- Timeout and interval IO

-- | Forks a thread to loop an action with given the given waiting period.
setInterval :: IO Bool -- ^ Action to perform. Loop continues if it's True.
            -> Int -- ^ Wait between repetitions in microseconds.
            -> IO ()
setInterval action microsecs = do
    forkIO loop
    return ()
  where
    loop = do
      threadDelay microsecs
      b <- action
      when b loop

-- | Standardization of timeout limits in microseconds.
timeoutTime :: Int
timeoutTime = 10000000 -- 10 seconds

-- | Runs the given action and handles the success with the given function. Has
-- a fallback for what will happen if a timeout occurs. This is basically a
-- tidier abstraction to be used instead of cases.
timeoutAct :: IO a -- ^ Action to be performed in the first place.
           -> IO b -- ^ What to do when there's a timeout error.
           -> (a -> IO b) -- ^ Function to handle success in the action.
           -> IO b
timeoutAct act fail f = do
  m <- timeout timeoutTime act
  case m of
    Nothing -> fail
    Just x -> f x

-- | Runs the given action, kills the application with the given string as the
-- error message if a timeout occurs.
timeoutDie :: IO a -> String -> IO a
timeoutDie act dieStr = timeoutAct act (die dieStr) return

-- Simple logging abstractions

type Logger m a = WriterT [String] m a

logger :: Monad m => String -> Logger m ()
logger s = tell [s]

returnAndLog :: IO (a, [String]) -> IO a
returnAndLog v = do
  (res, logs) <- v
  mapM_ putStrLn logs
  return res

-- | A function that finds all cycles in a graph.  A cycle is given as a
-- finite list of the vertices in order of occurrence, where each vertex
-- only appears once. Written by Chris Smith, April 20, 2009.
-- <https://cdsmith.wordpress.com/2009/04/20/code-for-manipulating-graphs-in-haskell/>
cycles :: Graph -> [[Vertex]]
cycles g = concatMap cycles' (vertices g)
  where cycles' v   = build [] v v
        build p s v =
          let p'         = p ++ [v]
              local      = [ p' | x <- (g!v), x == s ]
              good w     = w > s && not (w `elem` p')
              ws         = filter good (g ! v)
              extensions = concatMap (build p' s) ws
          in  local ++ extensions

-- Simple queue abstractions

queueToList :: Q.Queue a -> [a]
queueToList q = case Q.viewl q of
  Q.EmptyL -> []
  x Q.:< xs -> x : queueToList xs

-- ^ Checks if an element is in a queue.
qElem :: Eq a => a -> Q.Queue a -> Bool
qElem e q = case Q.viewl q of
  Q.EmptyL -> False
  x Q.:< xs -> (x == e) || qElem e xs

-- ^ Pushes the given value to the queue associated with the given key in the
-- given map. If the value is already in the queue, the it is not added.
pushToQueueMap :: String -> String -> M.Map String (Q.Queue String) -> STM ()
pushToQueueMap k v m = M.lookup k m >>= \look ->
  M.insert (case look of
    Nothing -> Q.singleton v
    Just q -> if v `qElem` q then q else q Q.|> v) k m

-- ^ Pops ans returns the first element of the queue and updates the queue map
-- with the rest of the queue. i.e. removes the head of the queue.
popFromQueueMap :: String -> M.Map String (Q.Queue String) -> STM (Maybe String)
popFromQueueMap k m = M.lookup k m >>= \case
    Nothing -> return Nothing
    Just q -> case Q.viewl q of
      Q.EmptyL -> return Nothing
      x Q.:< xs -> do
        case Q.viewl xs of -- if the rest is empty, delete the key from map
          Q.EmptyL -> M.delete k m
          _ -> M.insert xs k m
        return $ Just x
