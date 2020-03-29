{-# LANGUAGE OverloadedStrings, TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-deprecations #-}
module ConcordiumTests.PassiveFinalization where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (fromMaybe)
import Data.Time.Clock.POSIX
import Data.Time.Clock
import Lens.Micro.Platform
import System.IO.Unsafe
import System.Random

import Test.QuickCheck
import Test.Hspec

import Concordium.Afgjort.Finalize
import Concordium.Afgjort.Finalize.Types
import Concordium.Afgjort.Types (Party)
import Concordium.Afgjort.WMVBA

import Concordium.Birk.Bake

import qualified Concordium.Crypto.BlockSignature as Sig
import qualified Concordium.Crypto.BlsSignature as Bls
import Concordium.Crypto.DummyData
import Concordium.Crypto.SHA256
import qualified Concordium.Crypto.VRF as VRF

import Concordium.GlobalState
import Concordium.GlobalState.Bakers
import qualified Concordium.GlobalState.Basic.TreeState as TS
import Concordium.GlobalState.Block
import qualified Concordium.GlobalState.BlockPointer as BS
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.SeedState

import Concordium.Logger

import qualified Concordium.Scheduler.Utils.Init.Example as Example

import Concordium.Skov.Monad
import Concordium.Skov.MonadImplementations

import Concordium.Startup (makeBakerAccount)

import Concordium.Types
import Concordium.Types.HashableTo

-- Test that Concordium.Afgjort.Finalize.newPassiveRound has an effect on finalization;
-- specifically, that non-finalizers can successfully gather signatures from the pending-
-- finalization-message buffer and create finalization proofs from them. This is necessary
-- for cases where finalization messages are received out of order (i.e. messages for a later
-- finalization round arrive before the messages for an earlier finalization round).
--
-- This test has the following set up:
-- There are two bakers, baker1 and baker2, and a finalization-committee member, finMember.
-- (i) baker1 bakes two blocks A and B
-- (ii) baker2 receives finalization message for B at fin index 2
-- (iii) baker2 receives finalization message for A at fin index 1
-- (iv) baker2 bakes two blocks C and D
-- Then we test that C includes the record for A and D includes the record for B.
--
-- When baker2 receives a finalization message for fin index 2 (ii), this triggers an
-- attempt to finalize block B. However, Since the fin index is 2, and no finalization
-- has happened yet for fin index 1, the finalization message will be put into a buffer.
-- When baker2 subsequently receives a fin message for fin index 1 (iii), this triggers
-- the successful finalization of block A, and that first finalization record is put into
-- the finalization queue.
-- At the end of this finalization, a new finalization round for fin index 2 is attempted.
-- Since baker2 is not in the committee, this triggers `newPassiveRound`, which is what is being
-- tested.
-- `newPassiveRound` looks into the pending-finalization-message buffer. Due to (ii), this buffer
-- contains a finalization message for block B. As a result, baker2, a non-finalizer, can
-- successfully produce a finalization proof out of the existing signature created by finMember.
-- This resulting finalization record is also put into the finalization queue.
-- When afterwards block C is baked, baker2 takes the fin record for block A from the finalization
-- queue and adds it to C. 
-- Similarly, when block D is baked, the fin record for block B is included in D.
--
-- If `newPassiveRound` were not called, the successful finalization of block A would not trigger
-- the finalization of a block based on messages from the pending queue. I.e., if finalization
-- messages are received out of order, non-finalizers will not be able to create finalization records,
-- and finalization will depend on bakers being also in the finalization committee.  

{-# NOINLINE dummyCryptographicParameters #-}
dummyCryptographicParameters :: CryptographicParameters
dummyCryptographicParameters =
    fromMaybe
        (error "Could not read cryptographic parameters.")
        (unsafePerformIO (readCryptographicParameters <$> BSL.readFile "../scheduler/testdata/global.json"))

dummyTime :: UTCTime
dummyTime = posixSecondsToUTCTime 0

type Config t = SkovConfig MemoryTreeMemoryBlockConfig (ActiveFinalization t) NoHandler

finalizationParameters :: FinalizationParameters
finalizationParameters = FinalizationParameters 2 1000

type MyHandlers = SkovHandlers DummyTimer (Config DummyTimer) (StateT () LogIO)

newtype DummyTimer = DummyTimer Integer

type MySkovT = SkovT MyHandlers (Config DummyTimer) (StateT () LogIO)

dummyHandlers :: MyHandlers
dummyHandlers = SkovHandlers {..}
    where
        shBroadcastFinalizationMessage _ = return ()
        shBroadcastFinalizationRecord _ = return ()
        shOnTimeout _ _ = return $ DummyTimer 0
        shCancelTimer _ = return ()
        shPendingLive = return ()

myRunSkovT :: (MonadIO m)
           => MySkovT a
           -> MyHandlers
           -> SkovContext (Config DummyTimer)
           -> SkovState (Config DummyTimer)
           -> m (a, SkovState (Config DummyTimer), ())
myRunSkovT a handlers ctx st = liftIO $ flip runLoggerT doLog $ do
        ((res, st'), _) <- runStateT (runSkovT a handlers ctx st) ()
        return (res, st', ())
    where
        doLog src LLError msg = error $ show src ++ ": " ++ msg
        doLog _ _ _ = return () -- traceM $ show src ++ ": " ++ msg

type BakerState = (BakerIdentity, SkovContext (Config DummyTimer), SkovState (Config DummyTimer))
type BakerInformation = (BakerInfo, BakerIdentity, Account)

runTest1 :: BakerState
        -- ^State for the first baker
        -> BakerState
        -- ^State for the second baker
        -> BakerState
        -- ^State for the finalization committee member
        -> IO ()
runTest1 (bid1, fi1, fs1)
        (bid2, fi2, fs2)
        (fmId, _, SkovState TS.SkovData{..} FinalizationState{..} _ _) = do
            let bakeFirstSlots bid = do
                  b1 <- bake bid 1
                  b2 <- bake bid 2
                  return (b1, b2)
            -- Baker1 bakes first two blocks
            ((block1, block2), _, _) <- myRunSkovT (bakeFirstSlots bid1) dummyHandlers fi1 fs1
            -- Baker2 stores baker1's blocks
            void $ myRunSkovT (do
                    store block1
                    store block2
                    case _finsCurrentRound of
                        Right FinalizationRound{..} -> do
                            -- Creating finalization message for block2 and then for block1
                            -- and making baker2 receive them before baker2 starts baking blocks.
                            receiveFinMessage (_finsIndex + 1) block2 roundDelta _finsSessionId roundMe bid2 ResultPendingFinalization
                            receiveFinMessage _finsIndex block1 roundDelta _finsSessionId roundMe bid2 ResultSuccess
                            bakeAndVerify bid2 3 block1 1 _finsSessionId _finsCommittee
                            bakeAndVerify bid2 4 block2 2 _finsSessionId _finsCommittee
                        _ ->
                            fail "Finalizer should have active finalization round."
                ) dummyHandlers fi2 fs2

runTest2 :: BakerState
        -- ^State for the first baker
        -> BakerState
        -- ^State for the second baker who is a member of the fin committee
        -> BakerState
        -- ^State for the finalization committee member
        -> IO ()
runTest2 (bid1, fi1, fs1)
        (_, _, _)
        (fmId, fi3, fs3@(SkovState TS.SkovData{..} FinalizationState{..} _ _)) = do
            let bakeFirstSlots bid = do
                  b1 <- bake bid 1
                  b2 <- bake bid 2
                  return (b1, b2)
            -- Baker1 bakes first two blocks
            ((block1, block2), _, _) <- myRunSkovT (bakeFirstSlots bid1) dummyHandlers fi1 fs1
            -- Baker2 stores baker1's blocks
            void $ myRunSkovT (do
                    store block1
                    store block2
                    case _finsCurrentRound of
                        Right FinalizationRound{..} -> do
                            -- Creating finalization message for block1 and then for block2
                            -- and making the fin member receive them before the fin member starts baking blocks.
                            receiveFinMessage (_finsIndex + 1) block2 roundDelta _finsSessionId roundMe fmId ResultPendingFinalization
                            receiveFinMessage _finsIndex block1 roundDelta _finsSessionId roundMe fmId  ResultSuccess
                            bakeAndVerify fmId 3 block1 1 _finsSessionId _finsCommittee
                            bakeAndVerify fmId 4 block2 2 _finsSessionId _finsCommittee
                        _ ->
                            fail "Finalizer should have active finalization round."
                ) dummyHandlers fi3 fs3

runTest3 :: BakerState
        -- ^State for the first baker
        -> BakerState
        -- ^State for the second baker
        -> BakerState
        -- ^State for the finalization committee member
        -> IO ()
runTest3 (bid1, fi1, fs1)
         (bid2, fi2, fs2)
         (fmId, _, SkovState TS.SkovData{..} FinalizationState{..} _ _) = do
            -- Baker1 bakes first 12 blocks
            let slots = 12
            (blocks, _, _) <- myRunSkovT (mapM (bake bid1) [1..slots]) dummyHandlers fi1 fs1
            -- Baker2 stores baker1's blocks
            void $ myRunSkovT (do
                    mapM_ store blocks
                    case _finsCurrentRound of
                        Right FinalizationRound{..} -> do
                            let receive (ind, res) = receiveFinMessage (_finsIndex + ind) (blocks !! fromIntegral ind) roundDelta _finsSessionId roundMe fmId res
                            -- Creating finalization messages for blocks of the following slots:
                            --      1 -> 2 ->   (normal order, newPassiveRound unnecessary)
                            --      4 -> 3 ->   (reversed order, newPassiveRound necessary)
                            --      6 -> 5 ->   (one more reversed order, newPassiveRound necessary)
                            --      7 -> 8 ->   (normal order again)
                            --      11 -> 12 -> (too large indices, should be discarded)
                            --      10 ->       (goes into pending, newPassiveReound will be necessary)
                            --      12 ->       (too large index, should be discarded)
                            --      9           (normal order, after this we should process 10 with newPassiveRound)
                            -- and making baker2 receive them before baker2 starts baking blocks.
                            mapM_ receive [(0,  ResultSuccess),
                                           (1,  ResultSuccess),
                                           (3,  ResultPendingFinalization),
                                           (2,  ResultSuccess),
                                           (5,  ResultPendingFinalization),
                                           (4,  ResultSuccess),
                                           (6,  ResultSuccess),
                                           (7,  ResultSuccess),
                                           (10, ResultInvalid),
                                           (11, ResultInvalid),
                                           (9,  ResultPendingFinalization),
                                           (10, ResultInvalid),
                                           (8,  ResultSuccess)]
                            let bakeVerify slot b ind = bakeAndVerify bid2 slot b ind _finsSessionId _finsCommittee
                            -- Bake 10 more blocks and verify that they contain the first 10 blocks in their finalization records
                            mapM (\(i, b) -> bakeVerify (slots + i) b $ fromIntegral i) $ zip [1..] $ take 10 blocks
                        _ ->
                            fail "Finalizer should have active finalization round."
                ) dummyHandlers fi2 fs2


bake :: BakerIdentity -> Slot -> MySkovT BakedBlock
bake bid n = do
    mb <- bakeForSlot bid n
    maybe (fail $ "Could not bake for slot " ++ show n)
          (\BS.BlockPointer {_bpBlock = NormalBlock block} -> return block)
          mb

store :: SkovMonad m => BakedBlock -> m ()
store block = storeBlock (makePendingBlock block dummyTime) >>= \case
    ResultSuccess -> return()
    result        -> fail $ "Could not store block " ++ show block ++ ". Reason: " ++ show result


receiveFinMessage :: (FinalizationMonad m)
                  => FinalizationIndex
                  -> BakedBlock -- the block to be finalized
                  -> BlockHeight
                  -> FinalizationSessionId
                  -> Party -- finalization committee member whose signature we create
                  -> BakerIdentity -- baker identity of finalization committee member
                  -> UpdateResult -- expected result 
                  -> m ()
receiveFinMessage ind block delta sessId me bId expectedResult = do
    let msgHdr = FinalizationMessageHeader {
                   msgSessionId = sessId,
                   msgFinalizationIndex = ind,
                   msgDelta = delta,
                   msgSenderIndex = me
               }
        wmvbaMsg = makeWMVBAWitnessCreatorMessage (roundBaid sessId ind delta)
                                                (getHash block)
                                                (bakerAggregationKey bId)
        fmsg = signFinalizationMessage (bakerSignKey bId) msgHdr wmvbaMsg
    finalizationReceiveMessage (FPMMessage fmsg) >>= \result ->
        unless (result == expectedResult) $
            fail $ "Could not receive finalization message for index " ++ show (theFinalizationIndex ind)
                ++ "\nfor the following block:\n" ++ show block
                ++ ".\nExpected result: " ++ show expectedResult ++ ". Actual result: " ++ show result

bakeAndVerify :: BakerIdentity
              -> Slot
              -> BakedBlock
              -> FinalizationIndex
              -> FinalizationSessionId
              -> FinalizationCommittee
              -> MySkovT ()
bakeAndVerify bid slot finBlock finInd sessId finCom = do
    block <- bake bid slot
    -- Check that block contains finalization record for finBlock
    case bfBlockFinalizationData $ bbFields block of
        BlockFinalizationData fr@FinalizationRecord{..} -> do
            assertEqual "Wrong finalization index" finInd finalizationIndex
            assertEqual "Wrong finalization block hash" (getHash finBlock :: BlockHash) finalizationBlockPointer
            assertEqual "Finalization proof not verified" True $ verifyFinalProof sessId finCom fr
            liftIO $ putStrLn $ "Success: Block at slot " ++ show slot ++ " contains finalization proof\n  for block at slot "
                                ++ show (bbSlot finBlock) ++ " at finalization index " ++ show (theFinalizationIndex finInd)
        _ ->
            fail "Block 3 does not include finalization record"

assertEqual :: (Show x, Eq x, Monad m) => String -> x -> x -> m ()
assertEqual msg expected actual =
    unless (expected == actual) $ error $ msg ++ ":\nExpected: " ++ show expected ++ "\n=Actual:" ++ show actual

makeBaker :: BakerId -> Amount -> Gen BakerInformation
makeBaker bid initAmount = resize 0x20000000 $ do
        ek@(VRF.KeyPair _ epk) <- arbitrary
        sk                     <- genBlockKeyPair
        blssk                  <- fst . randomBlsSecretKey . mkStdGen <$> arbitrary
        let spk     = Sig.verifyKey sk
        let blspk   = Bls.derivePublicKey blssk
        let account = makeBakerAccount bid initAmount
        return (BakerInfo epk spk blspk initAmount (_accountAddress account), BakerIdentity sk ek blssk, account)

-- Create initial states for two bakers and a finalization committee member
createInitStates :: IO (BakerState, BakerState, BakerState)
createInitStates = do
    let bakerAmount = 10 ^ (4 :: Int)
    baker1 <- generate $ makeBaker 0 bakerAmount
    baker2 <- generate $ makeBaker 1 bakerAmount
    finMember <- generate $ makeBaker 2 (bakerAmount * 10 ^ (6 :: Int))
    let bis = [baker1, baker2, finMember]
        genesisBakers = fst . bakersFromList $ (^. _1) <$> bis
        bps = BirkParameters 1 genesisBakers genesisBakers genesisBakers (genesisSeedState (hash "LeadershipElectionNonce") 10)
        bakerAccounts = map (\(_, _, acc) -> acc) bis
        gen = GenesisData 0 1 bps bakerAccounts [] finalizationParameters dummyCryptographicParameters [] 10 $ Energy maxBound
        createState = liftIO . (\(_, bid, _) -> do
                                   let fininst = FinalizationInstance (bakerSignKey bid) (bakerElectionKey bid) (bakerAggregationKey bid)
                                       config = SkovConfig
                                           (MTMBConfig defaultRuntimeParameters gen (Example.initialState bps dummyCryptographicParameters bakerAccounts [] 2 []))
                                           (ActiveFinalization fininst gen)
                                           NoHandler
                                   (initCtx, initState) <- liftIO $ initialiseSkov config
                                   return (bid, initCtx, initState))
    b1 <- createState baker1
    b2 <- createState baker2
    fState <- createState finMember
    return (b1, b2, fState)

instance Show BakerIdentity where
    show _ = "[Baker Identity]"

instance Show FinalizationInstance where
    show _ = "[Finalization Instance]"

withInitialStates :: (BakerState -> BakerState -> BakerState -> IO ()) -> IO ()
withInitialStates r = do
    (b1, b2, fs) <- createInitStates
    r b1 b2 fs

test :: Spec
test = describe "Concordium.PassiveFinalization" $ do
    it "2 non-fin bakers, 1 fin member, received fin messages: round 2 -> round 1" $ withInitialStates runTest1
    -- same set up but fin baker executes active finalization round:
    it "2 fin bakers, received fin messages: round 2 -> round 1" $ withInitialStates runTest2
    it "2 non-fin bakers, 1 fin member, many messages" $ withInitialStates runTest3
-- TODO (MR) create more signatures per round