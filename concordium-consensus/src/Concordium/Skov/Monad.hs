{-# LANGUAGE LambdaCase #-}
module Concordium.Skov.Monad where

import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class
import Data.Maybe

import Concordium.Types

class (Monad m, MonadIO m) => SkovMonad m where
    -- |Look up a block in the table given its hash
    resolveBlock :: BlockHash -> m (Maybe BlockPointer)
    -- |Store a block in the block table and add it to the tree
    -- if possible.
    storeBlock :: Block -> m BlockHash
    -- |Finalize a block that is in the block table and a child
    -- of the last finalized block.  These properties may not be
    -- checked.
    finalizeBlock :: FinalizationRecord -> m ()
    -- |Determine if a block has been finalized
    isFinalized :: BlockHash -> m Bool
    -- |Determine the last finalized block
    lastFinalizedBlock :: m BlockPointer
    getGenesisData :: m GenesisData
    genesisBlock :: m BlockPointer
    -- |Get the height of the highest blocks in the tree.
    -- Note: the genesis block has height 0
    getCurrentHeight :: m BlockHeight
    -- |Get the blocks in the branches of the tree grouped by descending height.
    -- That is the first element of the list is all of the blocks at 'getCurrentHeight',
    -- the next is those at @getCurrentHeight - 1@, etc.
    branchesFromTop :: m [[BlockPointer]]
    -- |Get a list of all the blocks at a given height in the tree.
    getBlocksAtHeight :: BlockHeight -> m [BlockPointer]

instance SkovMonad m => SkovMonad (MaybeT m) where
    resolveBlock = lift . resolveBlock
    storeBlock = lift . storeBlock
    finalizeBlock = lift . finalizeBlock
    isFinalized = lift . isFinalized
    lastFinalizedBlock = lift lastFinalizedBlock
    getGenesisData = lift getGenesisData
    genesisBlock = lift genesisBlock
    getCurrentHeight = lift getCurrentHeight
    branchesFromTop = lift branchesFromTop
    getBlocksAtHeight = lift . getBlocksAtHeight

getBirkParameters :: (SkovMonad m) => Slot -> m BirkParameters
getBirkParameters _ = genesisBirkParameters <$> getGenesisData

getGenesisTime :: (SkovMonad m) => m Timestamp
getGenesisTime = genesisTime <$> getGenesisData

getFinalizationParameters :: (SkovMonad m) => m FinalizationParameters
getFinalizationParameters = genesisFinalizationParameters <$> getGenesisData
