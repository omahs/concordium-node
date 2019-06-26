{-# LANGUAGE TemplateHaskell, RecordWildCards, MultiParamTypeClasses, TypeFamilies, GeneralizedNewtypeDeriving #-}
module Concordium.GlobalState.Basic.BlockState where

import Lens.Micro.Platform
import Data.Hashable hiding (unhashed, hashed)
import Data.Time
import Data.Time.Clock.POSIX
import Control.Exception
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe

import qualified Concordium.Crypto.SHA256 as Hash
import Concordium.ID.Types(cdi_regId)
import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Block
import Concordium.GlobalState.Bakers
import qualified Concordium.GlobalState.BlockState as BS
import qualified Concordium.GlobalState.Modules as Modules
import qualified Concordium.GlobalState.Account as Account
import qualified Concordium.GlobalState.Instances as Instances
import qualified Concordium.GlobalState.Rewards as Rewards
import qualified Concordium.GlobalState.IdentityProviders as IPS

data BlockState = BlockState {
    _blockAccounts :: !Account.Accounts,
    _blockInstances :: !Instances.Instances,
    _blockModules :: !Modules.Modules,
    _blockBank :: !Rewards.BankStatus,
    _blockIdentityProviders :: !IPS.IdentityProviders,
    _blockBirkParameters :: BirkParameters
}

makeLenses ''BlockState

-- |Mostly empty block state, apart from using 'Rewards.genesisBankStatus' which
-- has hard-coded initial values for amount of gtu in existence.
emptyBlockState :: BirkParameters -> BlockState
emptyBlockState _blockBirkParameters = BlockState {
  _blockAccounts = Account.emptyAccounts
  , _blockInstances = Instances.emptyInstances
  , _blockModules = Modules.emptyModules
  , _blockBank = Rewards.emptyBankStatus
  , _blockIdentityProviders = IPS.emptyIdentityProviders
  ,..
  }


data BlockPointer = BlockPointer {
    -- |Hash of the block
    _bpHash :: !BlockHash,
    -- |The block itself
    _bpBlock :: !Block,
    -- |Pointer to the parent (circular reference for genesis block)
    _bpParent :: BlockPointer,
    -- |Pointer to the last finalized block (circular for genesis)
    _bpLastFinalized :: BlockPointer,
    -- |Height of the block in the tree
    _bpHeight :: !BlockHeight,
    -- |The handle for accessing the state (of accounts, contracts, etc.) after execution of the block.
    _bpState :: !BlockState,
    -- |Time at which the block was first received
    _bpReceiveTime :: UTCTime,
    -- |Time at which the block was first considered part of the tree (validated)
    _bpArriveTime :: UTCTime,
    -- |Number of transactions in a block
    _bpTransactionCount :: Int
}

instance Eq BlockPointer where
    bp1 == bp2 = _bpHash bp1 == _bpHash bp2

instance Ord BlockPointer where
    compare bp1 bp2 = compare (_bpHash bp1) (_bpHash bp2)

instance Hashable BlockPointer where
    hashWithSalt s = hashWithSalt s . _bpHash
    hash = hash . _bpHash

instance Show BlockPointer where
    show = show . _bpHash

instance HashableTo Hash.Hash BlockPointer where
    getHash = _bpHash

instance BlockData BlockPointer where
    blockSlot = blockSlot . _bpBlock
    blockFields = blockFields . _bpBlock
    blockTransactions = blockTransactions . _bpBlock
    verifyBlockSignature key = verifyBlockSignature key . _bpBlock

-- |Make a 'BlockPointer' from a 'PendingBlock'.
-- The parent and last finalized block pointers must match the block data.
makeBlockPointer ::
    PendingBlock        -- ^Pending block
    -> BlockPointer     -- ^Parent block pointer
    -> BlockPointer     -- ^Last finalized block pointer
    -> BlockState       -- ^Block state
    -> UTCTime          -- ^Block arrival time
    -> BlockPointer
makeBlockPointer pb _bpParent _bpLastFinalized _bpState _bpArriveTime
        = assert (getHash _bpParent == blockPointer bf) $
            assert (getHash _bpLastFinalized == blockLastFinalized bf) $
                BlockPointer {
                    _bpHash = getHash pb,
                    _bpBlock = NormalBlock (pbBlock pb),
                    _bpHeight = _bpHeight _bpParent + 1,
                    _bpReceiveTime = pbReceiveTime pb,
                    _bpTransactionCount = length (blockTransactions pb),
                    ..}
    where
        bf = bbFields $ pbBlock pb


makeGenesisBlockPointer :: GenesisData -> BlockState -> BlockPointer
makeGenesisBlockPointer genData _bpState = theBlockPointer
    where
        theBlockPointer = BlockPointer {..}
        _bpBlock = makeGenesisBlock genData
        _bpHash = getHash _bpBlock
        _bpParent = theBlockPointer
        _bpLastFinalized = theBlockPointer
        _bpHeight = 0
        _bpReceiveTime = posixSecondsToUTCTime (fromIntegral (genesisTime genData))
        _bpArriveTime = _bpReceiveTime
        _bpTransactionCount = 0


instance BS.BlockPointerData BlockPointer where
    type BlockState' BlockPointer = BlockState

    bpHash = _bpHash
    bpBlock = _bpBlock
    bpParent = _bpParent
    bpLastFinalized = _bpLastFinalized
    bpHeight = _bpHeight
    bpState = _bpState
    bpReceiveTime = _bpReceiveTime
    bpArriveTime = _bpArriveTime
    bpTransactionCount = _bpTransactionCount

newtype PureBlockStateMonad m a = PureBlockStateMonad {runPureBlockStateMonad :: m a}
    deriving (Functor, Applicative, Monad)

type instance BS.BlockPointer (PureBlockStateMonad m) = BlockPointer
type instance BS.UpdatableBlockState (PureBlockStateMonad m) = BlockState

instance Monad m => BS.BlockStateQuery (PureBlockStateMonad m) where
    {-# INLINE getModule #-}
    getModule bs mref = 
        return $ bs ^. blockModules . to (Modules.getModule mref)

    {-# INLINE getContractInstance #-}
    getContractInstance bs caddr = return (Instances.getInstance caddr (bs ^. blockInstances))

    {-# INLINE getAccount #-}
    getAccount bs aaddr =
      return $ bs ^? blockAccounts . ix aaddr

    {-# INLINE getModuleList #-}
    getModuleList bs = return $ bs ^. blockModules . to Modules.moduleList

    {-# INLINE getContractInstanceList #-}
    getContractInstanceList bs = return (bs ^.. blockInstances . Instances.foldInstances)

    {-# INLINE getAccountList #-}
    getAccountList bs =
      return $ Map.keys (Account.accountMap (bs ^. blockAccounts))
  
    {-# INLINE getBirkParameters #-}
    getBirkParameters = return . _blockBirkParameters

    {-# INLINE getRewardStatus #-}
    getRewardStatus = return . _blockBank

instance Monad m => BS.BlockStateOperations (PureBlockStateMonad m) where

    {-# INLINE bsoGetModule #-}
    bsoGetModule bs mref = return $ bs ^. blockModules . to (Modules.getModule mref)

    {-# INLINE bsoGetInstance #-}
    bsoGetInstance bs caddr = return (Instances.getInstance caddr (bs ^. blockInstances))

    {-# INLINE bsoGetAccount #-}
    bsoGetAccount bs aaddr =
      return $ bs ^? blockAccounts . ix aaddr

    {-# INLINE bsoRegIdExists #-}
    bsoRegIdExists bs regid = return (Account.regIdExists regid (bs ^. blockAccounts))

    {-# INLINE bsoPutNewAccount #-}
    bsoPutNewAccount bs acc = return $
        if Account.exists addr accounts then
          (False, bs)
        else
          (True, bs & blockAccounts .~ Account.putAccount acc accounts & bakerUpdate)
        where
            accounts = bs ^. blockAccounts
            addr = acc ^. accountAddress
            bakerUpdate = blockBirkParameters . birkBakers %~ addStake (acc ^. accountStakeDelegate) (acc ^. accountAmount)

    bsoPutNewInstance bs mkInstance = return (instanceAddress, bs')
        where
            (inst, instances') = Instances.createInstance mkInstance (bs ^. blockInstances)
            Instances.InstanceParameters{..} = Instances.instanceParameters inst
            bs' = bs
                -- Add the instance
                & blockInstances .~ instances'
                -- Update the owner accounts set of instances
                & blockAccounts . ix instanceOwner . accountInstances %~ Set.insert instanceAddress
                & maybe (error "Instance has invalid owner") 
                    (\owner -> blockBirkParameters . birkBakers %~ addStake (owner ^. accountStakeDelegate) (Instances.instanceAmount inst))
                    (bs ^? blockAccounts . ix instanceOwner)

    bsoPutNewModule bs mref iface viface source = return $
        case Modules.putInterfaces mref iface viface source (bs ^. blockModules) of
          Nothing -> (False, bs)
          Just mods' -> (True, bs & blockModules .~ mods')

    bsoModifyInstance bs caddr amount model = return $
        bs & blockInstances %~ Instances.updateInstanceAt caddr amount model
        & maybe (error "Instance has invalid owner") 
            (\owner -> blockBirkParameters . birkBakers %~ modifyStake (owner ^. accountStakeDelegate) (amountDiff amount $ Instances.instanceAmount inst))
            (bs ^? blockAccounts . ix instanceOwner)
        where
            inst = fromMaybe (error "Instance does not exist") $ bs ^? blockInstances . ix caddr
            Instances.InstanceParameters{..} = Instances.instanceParameters inst

    bsoModifyAccount bs accountUpdates = return $
        -- Update the account
        (case accountUpdates ^. BS.auCredential of
             Nothing -> bs & blockAccounts %~ Account.putAccount updatedAccount
             Just cdi ->
               bs & blockAccounts %~ Account.putAccount updatedAccount
                                   . Account.recordRegId (cdi_regId cdi))
        -- If we change the amount, update the delegate
        & maybe id 
            (\amt -> blockBirkParameters . birkBakers
                    %~ modifyStake (account ^. accountStakeDelegate)
                            (amountDiff amt $ account ^. accountAmount))
            (accountUpdates ^. BS.auAmount)
        where
            account = bs ^. blockAccounts . singular (ix (accountUpdates ^. BS.auAddress))
            updatedAccount = BS.updateAccount accountUpdates account

    {-# INLINE bsoNotifyExecutionCost #-}
    bsoNotifyExecutionCost bs amnt =
      return . snd $ bs & blockBank . Rewards.executionCost <%~ (+ amnt)

    bsoNotifyIdentityIssuerCredential bs idk =
      return . snd $ bs & blockBank . Rewards.identityIssuersRewards . at idk . non 0 <%~ (+ 1)

    {-# INLINE bsoGetExecutionCost #-}
    bsoGetExecutionCost bs =
      return $ bs ^. blockBank . Rewards.executionCost 

    {-# INLINE bsoGetBirkParameters #-}
    bsoGetBirkParameters = return . _blockBirkParameters

    bsoAddBaker bs binfo = return $ 
        let
            (bid, newBakers) = createBaker binfo (bs ^. blockBirkParameters . birkBakers)
        in (bid, bs & blockBirkParameters . birkBakers .~ newBakers)

    -- NB: The caller must ensure the baker exists. Otherwise this method is incorrect and will raise a runtime error.
    bsoUpdateBaker bs bupdate = return $
        bs & blockBirkParameters . birkBakers %~ updateBaker bupdate

    bsoRemoveBaker bs bid = return $ 
        let
            (rv, bakers') = removeBaker bid $ bs ^. blockBirkParameters . birkBakers
        in (rv, bs & blockBirkParameters . birkBakers .~ bakers')

    bsoSetInflation bs amnt = return $
        bs & blockBank . Rewards.mintedGTUPerSlot .~ amnt

    -- mint currency in the central bank, and also update the total gtu amount to maintain the invariant
    -- that the total gtu amount is indeed the total gtu amount
    bsoMint bs amount = return $
        let updated = bs & ((blockBank . Rewards.totalGTU) +~ amount) .
                           ((blockBank . Rewards.centralBankGTU) +~ amount)
        in (updated ^. blockBank . Rewards.centralBankGTU, updated)

    bsoDecrementCentralBankGTU bs amount = return $
        let updated = bs & ((blockBank . Rewards.centralBankGTU) -~ amount)
        in (updated ^. blockBank . Rewards.centralBankGTU, updated)

    bsoDelegateStake bs aaddr target = return $ if targetValid then (True, bs') else (False, bs)
        where
            targetValid = case target of
                Nothing -> True
                Just bid -> isJust $ bs ^. blockBirkParameters . birkBakers . bakerMap . at bid
            acct = fromMaybe (error "Invalid account address") $ bs ^? blockAccounts . ix aaddr
            stake = acct ^. accountAmount + 
                sum [Instances.instanceAmount inst |
                        Just inst <- Set.toList (acct ^. accountInstances) <&> flip Instances.getInstance (bs ^. blockInstances)]
            bs' = bs & blockBirkParameters . birkBakers %~ removeStake (acct ^. accountStakeDelegate) stake . addStake target stake
                    & blockAccounts . ix aaddr %~ (accountStakeDelegate .~ target)