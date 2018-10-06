{-# LANGUAGE RecordWildCards #-}
module Concordium.Birk.Bake where

import qualified Data.Map.Strict as Map

import Control.Monad.Trans.Maybe
import Lens.Micro.Platform

import Concordium.Types
import Concordium.Skov.Monad
import Concordium.Kontrol.Monad
import Concordium.Payload.Monad
import Concordium.Birk.LeaderElection
import Concordium.Kontrol.BestBlock
import Concordium.Payload.Transaction

data BakerIdentity = BakerIdentity {
    bakerId :: BakerId,
    bakerSignKey :: BakerSignPrivateKey,
    bakerElectionKey :: BakerElectionPrivateKey
}

processInputs :: (PayloadMonad m) => BlockHash -> m (Maybe BlockData)
processInputs bh = 
    fmap (fromTransactions . take 100 . map snd . Map.toList) <$> getPendingTransactionsAtBlock bh

bakeForSlot :: (KontrolMonad m, PayloadMonad m) => BakerIdentity -> Slot -> m (Maybe Block)
bakeForSlot BakerIdentity{..} slot = runMaybeT $ do
    -- TODO: Should check that the best block is not already in this slot!
    bb <- bestBlockBefore slot
    BirkParameters{..} <- getBirkParameters bb
    electionProof <- MaybeT . pure $ do
        lotteryPower <- bakerLotteryPower <$> birkBakers ^? ix bakerId
        leaderElection birkLeadershipElectionNonce birkElectionDifficulty slot bakerElectionKey lotteryPower
    let nonce = computeBlockNonce birkLeadershipElectionNonce slot bakerElectionKey
    lastFinal <- finalizationBlockPointer <$> lastFinalizedBlock
    payload <- MaybeT $ processInputs bb
    let block = signBlock bakerSignKey slot bb bakerId electionProof nonce lastFinal payload
    storeBlock block
    return block
