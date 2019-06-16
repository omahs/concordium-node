{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, FunctionalDependencies, FlexibleContexts #-}
module Concordium.Getters where

import Lens.Micro.Platform hiding ((.=))

import Concordium.Kontrol.BestBlock
import Concordium.Skov
import Concordium.Skov.Update (isAncestorOf)

import qualified Concordium.Scheduler.Types as AT
import Concordium.GlobalState.TreeState(BlockPointerData(..))
import qualified Concordium.GlobalState.TreeState as TS
import Concordium.Types as T
import Concordium.GlobalState.Information(jsonStorable)
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Block
import Concordium.Types.HashableTo
import Concordium.GlobalState.Instances
import Concordium.GlobalState.Finalization

import Concordium.Afgjort.Finalize

import Data.IORef
import Text.Read hiding (get, String)
import qualified Data.Map as Map
import Data.Aeson
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as EL
import Control.Monad.State.Class
import Data.Word
import Data.ByteString.Builder(toLazyByteString, byteStringHex)
import Data.Vector (fromList)

class SkovQueryMonad m => SkovStateQueryable z m | z -> m where
    runStateQuery :: z -> m a -> IO a

instance SkovStateQueryable (IORef SkovFinalizationState) (SimpleSkovMonad SkovFinalizationState IO) where
    runStateQuery sfsRef a = readIORef sfsRef >>= evalSSM a

hsh :: (HashableTo BlockHash a) => a -> String
hsh x = show (getHash x :: BlockHash)

getBestBlockState :: SkovQueryMonad m => m (TS.BlockState m)
getBestBlockState = bpState <$> bestBlock

getLastFinalState :: SkovQueryMonad m => m (TS.BlockState m)
getLastFinalState = bpState <$> lastFinalizedBlock

getAccountList :: SkovStateQueryable z m => m (TS.BlockState m) -> z -> IO Value
getAccountList blockstate sfsRef = runStateQuery sfsRef $ do
  st <- blockstate
  alist <- TS.getAccountList st
  return . toJSON . map show $ alist  -- show instance for account addresses is based on Base58 encoding

getInstances :: (SkovStateQueryable z m) => m (TS.BlockState m) -> z -> IO Value
getInstances blockstate sfsRef = runStateQuery sfsRef $ do
  ilist <- TS.getContractInstanceList =<< blockstate
  return $ toJSON [object ["index" .= toInteger contractIndex, "subindex" .= toInteger contractSubindex] | ContractAddress{..} <- map iaddress ilist]

getAccountInfo :: (SkovStateQueryable z m) => m (TS.BlockState m) -> z -> AccountAddress -> IO Value
getAccountInfo blockstate sfsRef addr = runStateQuery sfsRef $ do
  st <- blockstate
  TS.getAccount st addr >>=
      \case Nothing -> return Null
            Just acc -> return $ object ["accountNonce" .= let Nonce n = (acc ^. T.accountNonce) in n
                                        ,"accountAmount" .= toInteger (acc ^. T.accountAmount)
                                        ]

getContractInfo :: (SkovStateQueryable z m) => m (TS.BlockState m) -> z -> AT.ContractAddress -> IO Value
getContractInfo blockstate sfsRef addr = runStateQuery sfsRef $ do
  st <- blockstate
  TS.getContractInstance st addr >>=
      \case Nothing -> return Null
            Just istance -> let params = instanceParameters istance
                            in return $ object ["model" .= jsonStorable (instanceModel istance)
                                               ,"owner" .= String (T.pack (show (instanceOwner params))) -- account address show instance is base58
                                               ,"amount" .= toInteger (instanceAmount istance)]

getRewardStatus :: (SkovStateQueryable z m) => m (TS.BlockState m) -> z -> IO Value
getRewardStatus blockstate sfsRef = runStateQuery sfsRef $ do
  reward <- TS.getRewardStatus =<< blockstate
  return $ object [
    "totalAmount" .= (fromIntegral (reward ^. AT.totalGTU) :: Integer),
    "totalEncryptedAmount" .= (fromIntegral (reward ^. AT.totalEncryptedGTU) :: Integer),
    "centralBankAmount" .= (fromIntegral (reward ^. AT.centralBankGTU) :: Integer),
    "mintedAmountPerSlot" .= (fromIntegral (reward ^. AT.mintedGTUPerSlot) :: Integer)
    ]

getBirkParameters :: (SkovStateQueryable z m) => m (TS.BlockState m) -> z -> IO Value
getBirkParameters blockstate sfsRef = runStateQuery sfsRef $ do
  BirkParameters{..} <- TS.getBirkParameters =<< blockstate
  return $ object [
    "electionDifficulty" .= birkElectionDifficulty,
    "electionNonce" .= String (TL.toStrict . EL.decodeUtf8 . toLazyByteString . byteStringHex $ birkLeadershipElectionNonce),
    "bakers" .= Array (fromList .
                       map (\(bid, BakerInfo{..}) -> object ["bakerId" .= (bid :: Word64)
                                                            ,"bakerAccount" .= show bakerAccount
                                                            ,"bakerLotteryPower" .= bakerLotteryPower
                                                            ]) .
                       Map.toList $ birkBakers)
    ]

getConsensusStatus :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> IO Value
getConsensusStatus sfsRef = runStateQuery sfsRef $ do
        bb <- bestBlock
        lfb <- lastFinalizedBlock
        genesis <- genesisBlock
        stats <- TS.getConsensusStatistics
        return $ object [
                "bestBlock" .= hsh bb,
                "genesisBlock" .= hsh genesis,
                "lastFinalizedBlock" .= hsh lfb,
                "bestBlockHeight" .= theBlockHeight (bpHeight bb),
                "lastFinalizedBlockHeight" .= theBlockHeight (bpHeight lfb),
                "blocksReceivedCount" .= (stats ^. TS.blocksReceivedCount),
                "blockLastReceivedTime" .= (stats ^. TS.blockLastReceived),
                "blockReceiveLatencyEMA" .= (stats ^. TS.blockReceiveLatencyEMA),
                "blockReceiveLatencyEMSD" .= sqrt (stats ^. TS.blockReceiveLatencyEMVar),
                "blockReceivePeriodEMA" .= (stats ^. TS.blockReceivePeriodEMA),
                "blockReceivePeriodEMSD" .= (sqrt <$> (stats ^. TS.blockReceivePeriodEMVar)),
                "blocksVerifiedCount" .= (stats ^. TS.blocksVerifiedCount),
                "blockLastArrivedTime" .= (stats ^. TS.blockLastArrive),
                "blockArriveLatencyEMA" .= (stats ^. TS.blockArriveLatencyEMA),
                "blockArriveLatencyEMSD" .= sqrt (stats ^. TS.blockArriveLatencyEMVar),
                "blockArrivePeriodEMA" .= (stats ^. TS.blockArrivePeriodEMA),
                "blockArrivePeriodEMSD" .= (sqrt <$> (stats ^. TS.blockArrivePeriodEMVar)),
                "transactionsPerBlockEMA" .= (stats ^. TS.transactionsPerBlockEMA),
                "transactionsPerBlockEMSD" .= sqrt (stats ^. TS.transactionsPerBlockEMVar),
                "finalizationCount" .= (stats ^. TS.finalizationCount),
                "lastFinalizedTime" .= (stats ^. TS.lastFinalizedTime),
                "finalizationPeriodEMA" .= (stats ^. TS.finalizationPeriodEMA),
                "finalizationPeriodEMSD" .= (sqrt <$> (stats ^. TS.finalizationPeriodEMVar))
            ]

getBlockInfo :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> String -> IO Value
getBlockInfo sfsRef blockHash = case readMaybe blockHash of
        Nothing -> return Null
        Just bh -> runStateQuery sfsRef $
                resolveBlock bh >>= \case
                    Nothing -> return Null
                    Just bp -> do
                        let slot = blockSlot (bpBlock bp)
                        reward <- TS.getRewardStatus (bpState bp)
                        slotTime <- getSlotTime slot
                        bfin <- isFinalized bh
                        return $ object [
                            "blockHash" .= hsh bp,
                            "blockParent" .= hsh (bpParent bp),
                            "blockLastFinalized" .= hsh (bpLastFinalized bp),
                            "blockHeight" .= theBlockHeight (bpHeight bp),
                            "blockReceiveTime" .= bpReceiveTime bp,
                            "blockArriveTime" .= bpArriveTime bp,
                            "blockSlot" .= (fromIntegral slot :: Word64),
                            "blockSlotTime" .= slotTime,
                            "blockBaker" .= case blockFields bp of
                                            Nothing -> Null
                                            Just bf -> toJSON (blockBaker bf),
                            "finalized" .= bfin,
                            "transactionCount" .= bpTransactionCount bp,

                            "totalAmount" .= (fromIntegral (reward ^. AT.totalGTU) :: Integer),
                            "totalEncryptedAmount" .= (fromIntegral (reward ^. AT.totalEncryptedGTU) :: Integer),
                            "centralBankAmount" .= (fromIntegral (reward ^. AT.centralBankGTU) :: Integer),
                            "mintedAmountPerSlot" .= (fromIntegral (reward ^. AT.mintedGTUPerSlot) :: Integer),
                            "executionCost" .= (fromIntegral (reward ^. AT.executionCost) :: Integer)
                            ]

getAncestors :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> String -> BlockHeight -> IO Value
getAncestors sfsRef blockHash count = case readMaybe blockHash of
        Nothing -> return Null
        Just bh -> runStateQuery sfsRef $
                resolveBlock bh >>= \case
                    Nothing -> return Null
                    Just bp -> do
                        let heightLim = if count > bpHeight bp then 0 else bpHeight bp - count + 1
                        return $ toJSONList $ map hsh $ takeWhile (\b -> bpHeight b >= heightLim) $ iterate bpParent bp
 
getBranches :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> IO Value
getBranches sfsRef = runStateQuery sfsRef $ do
            brs <- branchesFromTop
            let brt = foldl up Map.empty brs
            lastFin <- lastFinalizedBlock
            return $ object ["blockHash" .= hsh lastFin, "children" .= Map.findWithDefault [] lastFin brt]
    where
        up childrenMap = foldr (\b -> at (bpParent b) . non [] %~ (object ["blockHash" .= hsh b, "children" .= Map.findWithDefault [] b childrenMap] :)) Map.empty

getBlockData :: (SkovStateQueryable z m) => z -> BlockHash -> IO (Maybe Block)
getBlockData sfsRef bh = runStateQuery sfsRef $
            fmap bpBlock <$> resolveBlock bh

getBlockDescendant :: (SkovStateQueryable z m) => z -> BlockHash -> BlockHeight -> IO (Maybe Block)
getBlockDescendant sfsRef ancestor distance = runStateQuery sfsRef $
            resolveBlock ancestor >>= \case
                Nothing -> return Nothing
                Just bp -> do
                    candidates <- getBlocksAtHeight (bpHeight bp + distance)
                    return $ bpBlock <$> candidates ^? each . filtered (bp `isAncestorOf`)

getBlockFinalization :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> BlockHash -> IO (Maybe FinalizationRecord)
getBlockFinalization sfsRef bh = runStateQuery sfsRef $ do
            bs <- TS.getBlockStatus bh
            case bs of
                Just (TS.BlockFinalized _ fr) -> return $ Just fr
                _ -> return Nothing

getIndexedFinalization :: (SkovStateQueryable z m, TS.TreeStateMonad m) => z -> FinalizationIndex -> IO (Maybe FinalizationRecord)
getIndexedFinalization sfsRef finInd = runStateQuery sfsRef $ TS.getFinalizationAtIndex finInd

getFinalizationMessages :: (SkovStateQueryable z m, MonadState s m, FinalizationStateLenses s) => z -> FinalizationPoint -> IO [FinalizationMessage]
getFinalizationMessages sfsRef finPt = runStateQuery sfsRef $ get <&> \sfs -> getPendingFinalizationMessages sfs finPt

getFinalizationPoint :: (SkovStateQueryable z m, MonadState s m, FinalizationStateLenses s) => z -> IO FinalizationPoint
getFinalizationPoint sfsRef = runStateQuery sfsRef $ get <&> getCurrentFinalizationPoint
