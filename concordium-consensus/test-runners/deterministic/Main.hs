{-# LANGUAGE ViewPatterns, TemplateHaskell, GeneralisedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-deprecations #-}
-- |This module simulates running multiple copies of consensus together in a
-- deterministic fashion, without consideration for real time.  The goal is to
-- have a faster and more reproducible way of testing/profiling/benchmarking
-- performance-related issues.
--
-- Note that it is expected that you will edit this file depending on what
-- you wish to test.
module Main where

import qualified Data.Vector as Vec
import Control.Monad
import Control.Monad.IO.Class
import Lens.Micro.Platform
import Data.Time.Clock.POSIX
import Data.Time.Clock
import Control.Monad.Trans.State (StateT(..),execStateT)
import Control.Monad.State.Class
import Control.Monad.Trans.Reader (ReaderT(..))
import Control.Monad.Reader.Class
import qualified Data.PQueue.Min as MinPQ
import qualified Data.Sequence as Seq
import System.Random
import Control.Monad.Trans

import Concordium.Afgjort.Finalize.Types
import Concordium.Types
import qualified Concordium.GlobalState.Basic.BlockState as BState
import qualified Concordium.GlobalState.BlockPointer as BS
import Concordium.Types.Transactions
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.IdentityProviders
import Concordium.GlobalState.Block
import Concordium.GlobalState

import qualified Concordium.Scheduler.Utils.Init.Example as Example
import Concordium.Skov.Monad
import Concordium.Skov.MonadImplementations
import Concordium.Afgjort.Finalize
import Concordium.Logger
import Concordium.Birk.Bake
import Concordium.TimerMonad
import Concordium.Kontrol
import Concordium.TimeMonad

import Concordium.Startup

import Concordium.Crypto.DummyData
import Concordium.Types.DummyData (mateuszAccount)

-- |A timer is represented as an integer identifier.
-- Timers are issued with increasing identifiers.
newtype DummyTimer = DummyTimer Integer
    deriving (Num, Eq, Ord)

-- |Configuration to use for bakers.
-- Can be customised for different global state configurations (disk/memory/paired)
-- or to enable/disable finalization buffering.
type BakerConfig = SkovConfig DiskTreeDiskBlockConfig (BufferedFinalization DummyTimer) NoHandler

-- |The identity providers to use.
dummyIdentityProviders :: [IpInfo]
dummyIdentityProviders = []

-- |Construct genesis state.
genesisState :: GenesisData -> BState.BlockState
genesisState GenesisData{..} = Example.initialState
                       (BState.BasicBirkParameters genesisElectionDifficulty genesisBakers genesisBakers genesisBakers genesisSeedState)
                       genesisCryptographicParameters
                       genesisAccounts
                       genesisIdentityProviders
                       2 -- Initial number of counter contracts
                       genesisControlAccounts

-- |Construct the global state configuration.
-- Can be customised if changing the configuration.
makeGlobalStateConfig :: RuntimeParameters -> GenesisData -> IO DiskTreeDiskBlockConfig
makeGlobalStateConfig rt genData = return $ DTDBConfig rt genData (genesisState genData)

-- |Monad that provides a deterministic implementation of 'TimeMonad' -- i.e. that is
-- not dependent on real time.
newtype DeterministicTime m a = DeterministicTime { runDeterministic' :: ReaderT UTCTime m a }
    deriving (Functor, Applicative, Monad, MonadIO)

instance Monad m => TimeMonad (DeterministicTime m) where
    currentTime = DeterministicTime ask

-- |Run the 'DeterministicTime' action with the given time.
runDeterministic :: DeterministicTime m a -> UTCTime -> m a
runDeterministic (DeterministicTime a) t = runReaderT a t

-- |The base monad (with logging and time).
type LogBase = LoggerT (DeterministicTime IO)

-- |How 'SkovHandlers' should be instantiated for our setting.
type MyHandlers = SkovHandlers DummyTimer BakerConfig (StateT SimState LogBase)

-- |The monad for bakers to run in.
type BakerM a = SkovT MyHandlers BakerConfig (StateT SimState LogBase) a

-- |Events that trigger actions by bakers.
data Event
    = EBake Slot
    -- ^Attempt to bake a block in the given slot; generates a new event for the next slot
    | EBlock BakedBlock
    -- ^Receive a block
    | ETransaction BlockItem
    -- ^Receive a transaction
    | EFinalization FinalizationPseudoMessage
    -- ^Receive a finalization message
    | EFinalizationRecord FinalizationRecord
    -- ^Receive a finalization record
    | ETimer DummyTimer (BakerM ())
    -- ^Trigger a timer event

instance Show Event where
    show (EBake sl) = "Bake in slot " ++ show sl
    show (EBlock _) = "Receive block"
    show (ETransaction _) = "Receive transaction"
    show (EFinalization _) = "Receive finalization message"
    show (EFinalizationRecord _ ) = "Receive finalization record"
    show (ETimer _ _) = "Timer event"

-- |Both baker-specific and generic events.
data GEvent
    = BakerEvent Int Event
    -- ^An event for a particular baker
    | TransactionEvent (Nonce -> (BlockItem, GEvent))
    -- ^Spawn a transaction to send to bakers

-- |An event with a time at which it should occur.
-- The time is used for determining priority.
data PEvent = PEvent Integer GEvent
instance Eq PEvent where
    (PEvent i1 _) == (PEvent i2 _) = i1 == i2
instance Ord PEvent where
    compare (PEvent i1 _) (PEvent i2 _) = compare i1 i2

-- |The state of a particular baker.
data BakerState = BakerState {
    _bsIdentity :: BakerIdentity,
    _bsInfo :: BakerInfo,
    _bsContext :: SkovContext BakerConfig,
    _bsState :: SkovState BakerConfig
}

-- |Typeclass of a datastructure that collects events.
-- The instance of this structure determines how events
-- are ordered.
class Events e where
    -- |Add an event to the collection.
    addEvent :: PEvent -> e -> e
    -- |Filter the collection.
    filterEvents :: (PEvent -> Bool) -> e -> e
    -- |Make a collection from a list (in a default manner).
    makeEvents :: [PEvent] -> e
    -- |Extract the next event from the collection.
    nextEvent :: e -> Maybe (PEvent, e)

instance Events (MinPQ.MinQueue PEvent) where
    addEvent = MinPQ.insert
    filterEvents = MinPQ.filter
    makeEvents = MinPQ.fromList
    nextEvent = MinPQ.minView

-- |An instance of 'Events' that selects events randomly
-- (without regard for time).  The randomness is determined
-- by the 'StdGen', which is used to pick the next element
-- from the sequence.
data RandomisedEvents = RandomisedEvents {
    _reEvents :: Seq.Seq PEvent,
    _reGen :: StdGen
}

-- |State of the simulation. 
data SimState = SimState {
    _ssBakers :: Vec.Vector BakerState,
    _ssEvents :: MinPQ.MinQueue PEvent,
--  _ssEvents :: RandomisedEvents,
    _ssNextTransactionNonce :: Nonce,
    _ssNextTimer :: DummyTimer,
    _ssCurrentTime :: UTCTime
}

makeLenses ''RandomisedEvents
makeLenses ''BakerState
makeLenses ''SimState


-- |Pick an element from a sequence, returning the element
-- and the sequence with that element removed.
selectFromSeq :: (RandomGen g) => g -> Seq.Seq a -> (a, Seq.Seq a, g)
selectFromSeq g s =
    let (n , g') = randomR (0, length s - 1) g in
    (Seq.index s n, Seq.deleteAt n s, g')

-- |Seed to use for randomness in 'RandomisedEvents'.
-- This can be varied to generate different runs (when 'RandomisedEvents'
-- is used.)
randomisedEventsSeed :: Int
randomisedEventsSeed = 0

instance Events RandomisedEvents where
    addEvent e = reEvents %~ (Seq.|> e)
    filterEvents f = reEvents %~ Seq.filter f
    makeEvents l = RandomisedEvents (Seq.fromList l) (mkStdGen randomisedEventsSeed)
    nextEvent RandomisedEvents{..} = case _reEvents of
        Seq.Empty -> Nothing
        _ -> let (v, s', g') = selectFromSeq _reGen _reEvents in
                    Just (v, RandomisedEvents s' g')

-- |Maximal baker ID.
maxBakerId :: (Integral a) => a
maxBakerId = 9

-- |List of all baker IDs.
allBakers :: (Integral a) => [a]
allBakers = [0..maxBakerId]

-- |The initial state of the simulation.
initialState :: IO SimState
initialState = do
    -- This timestamp is only used for naming the database files.
    now <- currentTimestamp
    _ssBakers <- Vec.fromList <$> mapM (mkBakerState now) (zip [0..] bakers)
    return SimState {..}
    where
        -- The genesis parameters could be changed.
        -- The slot duration is set to 1 second (1000 ms), since the deterministic time is also
        -- set to increase in 1 second intervals.
        (genData, bakers) = makeGenesisData
                                0 -- Start at time 0, to match time
                                (maxBakerId + 1) -- Number of bakers
                                1000 -- Slot time is 1 second, to match time
                                0.2 -- Election difficulty
                                defaultFinalizationParameters
                                dummyCryptographicParameters
                                dummyIdentityProviders
                                [Example.createCustomAccount 1000000000000 mateuszKP mateuszAccount]
                                (Energy maxBound)
        mkBakerState :: Timestamp -> (BakerId, (BakerIdentity, BakerInfo)) -> IO BakerState
        mkBakerState now (bakerId, (_bsIdentity, _bsInfo)) = do
            gsconfig <- makeGlobalStateConfig (defaultRuntimeParameters { rpTreeStateDir = "data/treestate-" ++ show now ++ "-" ++ show bakerId, rpBlockStateFile = "data/blockstate-" ++ show now ++ "-" ++ show bakerId }) genData --dbConnString
            let
                finconfig = BufferedFinalization (FinalizationInstance (bakerSignKey _bsIdentity) (bakerElectionKey _bsIdentity) (bakerAggregationKey _bsIdentity))
                hconfig = NoHandler
                config = SkovConfig gsconfig finconfig hconfig
            (_bsContext, _bsState) <- runLoggerT (initialiseSkov config) (logFor (fromIntegral bakerId))
            return BakerState{..}
        _ssEvents = makeEvents [PEvent 0 (BakerEvent i (EBake 0)) | i <- allBakers]
        _ssNextTransactionNonce = 1
        _ssNextTimer = 0
        _ssCurrentTime = posixSecondsToUTCTime 0

-- |Log an event for a particular baker.
logFor :: (MonadIO m) => Int -> LogMethod m
-- logFor _ _ _ _ = return ()
logFor i src lvl msg = liftIO $ putStrLn $ "[" ++ show i ++ ":" ++ show src ++ ":" ++ show lvl ++ "] " ++ show msg

-- |Run a baker action in the state monad.
runBaker :: Integer -> Int -> BakerM a -> StateT SimState IO a
runBaker curTime bid a = do
        bakerState <- (Vec.! bid) <$> use ssBakers
        (r, bsState') <- runBase (runSkovT a handlers (_bsContext bakerState) (_bsState bakerState))
        ssBakers . ix bid . bsState .= bsState'
        return r
    where
        runBase z = do
            s <- get
            (r, s') <- liftIO $ runDeterministic (runLoggerT (runStateT z s) (logFor bid)) curTimeUTC
            put s'
            return r
        curTimeUTC = posixSecondsToUTCTime (fromIntegral curTime)
        handlers = SkovHandlers {..}
        shBroadcastFinalizationMessage = broadcastEvent curTime . EFinalization
        shBroadcastFinalizationRecord = broadcastEvent curTime . EFinalizationRecord
        shOnTimeout timeout action = do
            tmr <- ssNextTimer <<%= (1+)
            let t = case timeout of
                    DelayFor delay -> curTime + round delay
                    DelayUntil z -> curTime + max 1 (round (diffUTCTime z curTimeUTC))
            ssEvents %= addEvent (PEvent t (BakerEvent bid (ETimer tmr (void action))))
            return tmr
        shCancelTimer tmr = ssEvents %= filterEvents f
            where
                f (PEvent _ (BakerEvent _ (ETimer tmr' _))) = tmr' /= tmr
                f _ = True
        shPendingLive = return ()

-- |Send an event to all bakers.
broadcastEvent :: (MonadState SimState m) =>
                    Integer -> Event -> m ()
broadcastEvent curTime ev = ssEvents %= \e -> foldr addEvent e [PEvent curTime (BakerEvent i ev) | i <- allBakers]

-- |Display an event for a baker.
displayBakerEvent :: (MonadIO m) => Int -> Event -> m ()
displayBakerEvent i ev = liftIO $ putStrLn $ show i ++ "> " ++ show ev

-- |Run a step of the consensus. This takes the next event and
-- executes that.
stepConsensus :: StateT SimState IO ()
stepConsensus =
    (nextEvent <$> use ssEvents) >>= \case
        Nothing -> return ()
        Just (nextEv, evs') -> do
            ssEvents .= evs'
            case nextEv of
                (PEvent t (TransactionEvent mktr)) -> do
                    -- For a transaction event, generate transaction event for each baker and
                    -- a new transaction event.
                    nonce <- ssNextTransactionNonce <<%= (1+)
                    let (bi, nxt) = mktr nonce
                    ssEvents %= \e -> addEvent (PEvent (t+1) nxt) (foldr addEvent e [PEvent t (BakerEvent bid (ETransaction bi)) | bid <- allBakers])
                (PEvent t (BakerEvent i ev)) -> displayBakerEvent i ev >> case ev of
                    EBake sl -> do
                        bakerIdentity <- (^. bsIdentity) . (Vec.! i) <$> use ssBakers
                        let doBake =
                                bakeForSlot bakerIdentity sl
                        mb <- runBaker t i doBake
                        forM_ (BS._bpBlock <$> mb) $ \case
                            GenesisBlock{} -> return ()
                            NormalBlock b -> broadcastEvent t (EBlock b)
                        ssEvents %= addEvent (PEvent (t+1) (BakerEvent i (EBake (sl+1))))
                    EBlock bb -> do
                        let pb = makePendingBlock bb (posixSecondsToUTCTime (fromIntegral t))
                        _ <- runBaker t i (storeBlock pb)
                        return ()
                    ETransaction tr -> do
                        _ <- runBaker t i (receiveTransaction tr)
                        return ()
                    EFinalization fm -> do
                        _ <- runBaker t i (finalizationReceiveMessage fm)
                        return ()
                    EFinalizationRecord fr -> do
                        _ <- runBaker t i (finalizationReceiveRecord False fr)
                        return ()
                    ETimer _ a -> runBaker t i a

-- |Main runner. Simply runs consensus for a certain number of steps.
main :: IO ()
main = b (100000 :: Int)
    where
        loop 0 _ = return ()
        loop n s = do
            s' <- execStateT stepConsensus s
            loop (n-1) s'
        b steps = loop steps =<< initialState