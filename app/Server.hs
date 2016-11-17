{-# LANGUAGE RecordWildCards, LambdaCase #-}
module Server where

import Control.Concurrent
import Control.Monad
import Control.Monad.STM
import Control.Concurrent.STM.TVar
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict
import qualified STMContainers.Map as M
import qualified ListT
import Control.Exception
import Network.Socket hiding (recv)
import Network.Socket.ByteString (recv, sendAll)
import qualified Network.Socket.ByteString as L
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B
import qualified Data.Serialize as S
import qualified Data.Aeson as JSON
import Data.Hashable
import System.Console.Chalk
import System.Timeout
import System.Exit
import qualified Options.Applicative as A
import Options.Applicative (Parser, (<>))

import RPC
import RPC.Socket

data Options = Options
  { viewLeaderAddr :: HostName
  , uuid           :: UUIDString
  } deriving (Show)

-- | A type for mutable state.
data MutState = MutState
  { keyStore      :: M.Map String String
  -- ^ A map to keep track of what we are committed on.
  , keyCommit     :: M.Map String (CommitId, String)
  , nextCommitId  :: TVar CommitId
  , heartbeats    :: TVar Int
  -- ^ Keeps track of the epoch in the view leader.
  , epoch         :: TVar Int
  -- ^ Keeps track of the most recent active servers list, so that we don't
  -- have to make a request to the view leader every time we make a request.
  , activeServers :: TVar [(UUIDString, AddrString)]
  }

initialState :: IO MutState
initialState = MutState <$> M.newIO <*> M.newIO <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO []

-- | Runs the command with side effects and returns the response that is to be
-- sent back to the client.
runCommand :: (Int, ServerCommand) -- ^ A pair of the request ID and a command.
           -> Options
           -> MutState -- ^ A reference to the mutable state.
           -> IO Response
runCommand (i, cmd) opt st@MutState{..} =
  case cmd of
    Get k -> returnAndLog $ runWriterT $
      lift (atomically $ (,) <$> M.lookup k keyStore <*> M.lookup k keyCommit) >>= \case
        (_, Just (i', v')) -> do
          logger $ red $ "Getting \"" ++ k ++ "\" is forbidden"
          return $ GetResponse i Forbidden ""
        (Just v, Nothing) -> do
          logger $ green $ "Got \"" ++ k ++ "\""
          return $ GetResponse i Ok v
        (Nothing, Nothing) -> do
          logger $ red $ "Couldn't get \"" ++ k ++ "\""
          return $ GetResponse i NotFound ""
    GetR k epochInput -> do
      ep <- atomically $ readTVar epoch
      if ep /= epochInput
      then return $ GetResponse i Forbidden ""
      else runCommand (i, Get k) opt st
    SetRVote k v epochInput -> returnAndLog $ runWriterT $ do -- Phase one
      ep <- lift $ atomically $ readTVar epoch
      currentId <- lift $ atomically $ readTVar nextCommitId
      lift (atomically $ M.lookup k keyCommit) >>= \case
        Just (i, v) -> do
          logger $ red $ "Setting \"" ++ k ++ "\" to \"" ++ v ++ "\" is forbidden, because "
                         ++ show (currentId, v) ++ " is in the commits"
          return $ SetResponseR i Forbidden ep currentId
        Nothing -> do
          lift $ atomically $ do
            modifyTVar' nextCommitId (+1)
            M.insert (currentId, v) k keyCommit
          logger $ red $ "Starting commit \"" ++ k ++ "\" to \"" ++ show (currentId, v)
          return $ SetResponseR i Ok ep currentId
    SetRCommit{..} -> returnAndLog $ runWriterT $ -- Phase two confirmation
      lift (atomically $ M.lookup k keyCommit) >>= \case
          Nothing -> do
            logger $ yellow $ "Commit: No such commit for \"" ++ k ++ "\" with the id " ++ show commitId
            return $ Executed i NotFound
          Just (id, v) -> if id /= commitId
            then do
              logger $ red $ "Commit: Wrong id. The commit for \"" ++ k ++ "\" with the id "
                             ++ show id ++ ", not with " ++ show commitId
              return $ Executed i Forbidden
            else do
              lift $ atomically $ do
                M.delete k keyCommit
                M.insert v k keyStore
              logger $ green $ "Finalizing commit for \"" ++ k ++ "\" with the id " ++ show commitId
              return $ Executed i Ok
    SetRCancel{..} -> returnAndLog $ runWriterT $ -- Phase two cancellation
      lift (atomically $ M.lookup k keyCommit) >>= \case
          Nothing -> do -- This should never be reached normally.
            logger $ yellow $ "Cancel: No such commit for \"" ++ k ++ "\" with the id " ++ show commitId
            return $ Executed i NotFound
          Just (id, v) -> if id /= commitId
            then do
              logger $ red $ "Cancel: Wrong id. The commit for \"" ++ k ++ "\" with the id "
                             ++ show id ++ ", not with " ++ show commitId
              return $ Executed i Forbidden
            else do
              lift $ atomically $ M.delete k keyCommit
              logger $ green $ "Canceling commit for \"" ++ k ++ "\" with the id " ++ show commitId
              return $ Executed i Ok
    QueryAllKeys -> returnAndLog $ runWriterT $ do
      kvs <- lift $ atomically $ ListT.toList $ M.stream keyStore
      logger $ green "Returned all keys"
      return $ KeysResponse i Ok (map fst kvs)

    -- _ -> returnAndLog $ runWriterT $ do
    --   logger $ bgRed "Unimplemented command on the server side"
    --   return $ Executed i NotFound

-- | Receives messages, decodes and runs the content if necessary, and returns
-- the response. Should be run after you accepted a connection.
runConn :: (Socket, SockAddr) -> Options -> MutState -> IO ()
runConn (sock, sockAddr) opt st = do
  timeoutAct (recvWithLen sock) (putStrLn $ red "Timeout when receiving") $
    \cmdMsg -> case S.decode cmdMsg :: Either String (Int, ServerCommand) of
      Left e ->
        putStrLn $ red "Couldn't parse the message received because " ++ e
      Right (i, cmd) -> do
        response <- runCommand (i, cmd) opt st
        timeoutAct (sendWithLen sock (BL.toStrict (JSON.encode response)))
                   (putStrLn $ red "Timeout when sending")
                   return
  close sock

sendHeartbeat :: Options -- ^ Command line options.
              -> SockAddr -- ^ The socket address of the listening server.
              -> MutState -- ^ A reference to the mutable state.
              -> IO ()
sendHeartbeat opt@Options{..} sockAddr st@MutState{..} = do
  attempt <- findAndConnectOpenPort viewLeaderAddr $ map show [39000..39010]
  i <- atomically $ modifyTVar' heartbeats (+1) >> readTVar heartbeats
  case attempt of
    Nothing ->
      die $ bgRed $ "Heartbeat: Couldn't connect to ports 39000 to 39010 on " ++ viewLeaderAddr
    Just (sock, sockAddr) -> do
      timeoutDie
        (sendWithLen sock (S.encode (i, Heartbeat uuid (show sockAddr))))
        (red "Timeout error when sending heartbeat request")
      r <- timeoutDie (recvWithLen sock)
            (red "Timeout error when receiving heartbeat response")
      close sock
      case JSON.decode (BL.fromStrict r) of
        Just (HeartbeatResponse _ Ok newEpoch) -> do
          oldEpoch <- atomically $ swapTVar epoch newEpoch
          when (oldEpoch /= newEpoch) $ updateActiveServers opt st
          putStrLn "Heartbeat sent"
        Just _ -> do
          putStrLn $ bgRed "Heartbeat: View leader rejects the server ID"
          exitFailure
        Nothing -> do
          putStrLn $ bgRed "Couldn't parse heartbeat response"
          exitFailure

updateActiveServers :: Options -> MutState -> IO ()
updateActiveServers opt@Options{..} st@MutState{..} = do
  attempt <- findAndConnectOpenPort viewLeaderAddr $ map show [39000..39010]
  i <- atomically $ readTVar heartbeats
  case attempt of
    Nothing ->
      die $ bgRed $ "Active servers: Couldn't connect to ports 39000 to 39010 on " ++ viewLeaderAddr
    Just (sock, sockAddr) -> do
      timeoutDie
        (sendWithLen sock (S.encode (i, QueryServers)))
        (red "Timeout error when sending query servers request")
      r <- timeoutDie (recvWithLen sock)
            (red "Timeout error when receiving query servers response")
      close sock
      case JSON.decode (BL.fromStrict r) of
        Just (QueryServersResponse _ newEpoch newActiveServers) -> do
          atomically $ do
            writeTVar epoch newEpoch
            writeTVar activeServers newActiveServers
          putStrLn $ green "Current list of active servers updated"
          rebalanceKeys opt st
        Just _ ->
          putStrLn $ bgRed "Wrong kind of response for query servers"
        Nothing ->
          putStrLn $ bgRed "Couldn't parse query servers response"

rebalanceKeys :: Options -> MutState -> IO ()
rebalanceKeys Options{..} MutState{..} = do
  -- TODO
  -- keyPairs <- atomically $ undefined
  putStrLn $ "Starting rebalancing keys"

-- | The main loop that keeps accepting more connections.
loop :: Socket -> Options -> MutState -> IO ()
loop sock opt st = do
  conn <- accept sock
  forkIO (runConn conn opt st)
  loop sock opt st

run :: Options -> IO ()
run opt = do
    uuidStr <- newUUID
    let opt = opt {uuid = uuidStr}
    attempt <- findAndListenOpenPort $ map show [38000..38010]
    case attempt of
      Nothing -> die $ bgRed "Couldn't bind ports 38000 to 38010"
      Just (sock, sockAddr) -> do
        st <- initialState
        sendHeartbeat opt sockAddr st -- the initial heartbeat
        setInterval (sendHeartbeat opt sockAddr st >> pure True) 5000000 -- every 5 sec
        loop sock opt st
        close sock

-- | Parser for the optional parameters of the client.
optionsParser :: Parser Options
optionsParser = Options
  <$> A.strOption
      ( A.long "viewleader"
     <> A.short 'l'
     <> A.metavar "VIEWLEADERADDR"
     <> A.help "Address of the view leader to connect"
     <> A.value "localhost" )
  <*> pure "" -- This must be replaced in the run function later

main :: IO ()
main = A.execParser opts >>= run
  where
    opts = A.info (A.helper <*> optionsParser)
      ( A.fullDesc
     <> A.progDesc "Start the server"
     <> A.header "client for an RPC implementation with locks and a view leader" )
