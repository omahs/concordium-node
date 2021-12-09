{-# LANGUAGE OverloadedStrings #-}
module Concordium.GlobalState.Instance where

import Data.Aeson
import Data.Serialize
import qualified Data.Set as Set
import qualified Concordium.Crypto.SHA256 as H

import Concordium.Types
import Concordium.Types.HashableTo
import qualified Concordium.Wasm as Wasm
import qualified Concordium.GlobalState.Wasm as GSWasm

-- |The fixed parameters associated with a smart contract instance
data InstanceParameters = InstanceParameters {
    -- |Address of the instance
    instanceAddress :: !ContractAddress,
    -- |Address of this contract instance owner, i.e., the creator account.
    instanceOwner :: !AccountAddress,
    -- |The name of the init method which created this contract.
    instanceInitName :: !Wasm.InitName,
    -- |The receive functions supported by this instance. Always a subset of
    -- receive methods of the module.
    instanceReceiveFuns :: !(Set.Set Wasm.ReceiveName),
    -- |The interface of 'instanceContractModule'
    instanceModuleInterface :: !GSWasm.ModuleInterface,
    -- |Hash of the fixed parameters
    instanceParameterHash :: !H.Hash
}

instance Show InstanceParameters where
    show InstanceParameters{..} = show instanceAddress ++ " :: " ++ show instanceContractModule ++ "." ++ show instanceInitName
        where instanceContractModule = GSWasm.miModuleRef instanceModuleInterface


instance HashableTo H.Hash InstanceParameters where
    getHash = instanceParameterHash

-- |An instance of a smart contract.
data Instance = Instance {
    -- |The fixed parameters of the instance
    instanceParameters :: !InstanceParameters,
    -- |The current local state of the instance
    instanceModel :: !Wasm.ContractState,
    -- |The current amount of GTU owned by the instance
    instanceAmount :: !Amount,
    -- |Hash of the smart contract instance
    instanceHash :: H.Hash
}

instance Show Instance where
    show Instance{..} = show instanceParameters ++ " {balance=" ++ show instanceAmount ++ ", model=" ++ show instanceModel ++ ", hash=" ++ show instanceHash ++ "}"

instance HashableTo H.Hash Instance where
    getHash = instanceHash

-- |Helper function for JSON encoding an 'Instance'.
instancePairs :: KeyValue kv => Instance -> [kv]
{-# INLINE instancePairs #-}
instancePairs istance =
    [ "model" .= instanceModel istance,
      "owner" .= instanceOwner params,
      "amount" .= instanceAmount istance,
      "methods" .= instanceReceiveFuns params,
      "name" .= instanceInitName params,
      "sourceModule" .= GSWasm.miModuleRef (instanceModuleInterface params)
    ]
  where
    params = instanceParameters istance

-- |JSON instance to support consensus queries.
instance ToJSON Instance where
    toJSON inst = object $ instancePairs inst
    toEncoding inst = pairs $ mconcat $ instancePairs inst

makeInstanceParameterHash :: ContractAddress -> AccountAddress -> ModuleRef -> Wasm.InitName -> H.Hash
makeInstanceParameterHash ca aa modRef conName = H.hashLazy $ runPutLazy $ do
        put ca
        put aa
        put modRef
        put conName

makeInstanceHash' :: H.Hash -> Wasm.ContractState -> Amount -> H.Hash
makeInstanceHash' paramHash conState a = H.hashLazy $ runPutLazy $ do
        put paramHash
        putByteString (H.hashToByteString (getHash conState))
        put a

makeInstanceHash :: InstanceParameters -> Wasm.ContractState -> Amount -> H.Hash
makeInstanceHash params = makeInstanceHash' (instanceParameterHash params)

makeInstance ::
    Wasm.InitName
    -- ^Name of the init method used to initialize the contract.
    -> Set.Set Wasm.ReceiveName
    -- ^Receive functions suitable for this instance.
    -> GSWasm.ModuleInterface
    -- ^Module interface
    -> Wasm.ContractState
    -- ^Initial state
    -> Amount
    -- ^Initial balance
    -> AccountAddress
    -- ^Owner/creator of the instance.
    -> ContractAddress
    -- ^Address for the instance
    -> Instance
makeInstance instanceInitName instanceReceiveFuns instanceModuleInterface instanceModel instanceAmount instanceOwner instanceAddress
        = Instance {..}
    where
        instanceContractModule = GSWasm.miModuleRef instanceModuleInterface
        instanceParameterHash = makeInstanceParameterHash instanceAddress instanceOwner instanceContractModule instanceInitName
        instanceParameters = InstanceParameters {..}
        instanceHash = makeInstanceHash instanceParameters instanceModel instanceAmount

-- |The address of a smart contract instance.
iaddress :: Instance -> ContractAddress
iaddress = instanceAddress . instanceParameters

-- |Update a given smart contract instance.
-- FIXME: Updates to the state should be done better in the future, we should not just replace it.
updateInstance :: AmountDelta -> Wasm.ContractState -> Instance -> Instance
updateInstance delta val i =  updateInstance' amnt val i
  where amnt = applyAmountDelta delta (instanceAmount i)

-- |Update a given smart contract instance with exactly the given amount and state.
updateInstance' :: Amount -> Wasm.ContractState -> Instance -> Instance
updateInstance' amnt val i =  i {
                                instanceModel = val,
                                instanceAmount = amnt,
                                instanceHash = makeInstanceHash (instanceParameters i) val amnt
                            }

-- |Serialize a smart contract instance in V0 format.
putInstanceV0 :: Putter Instance
putInstanceV0 Instance{instanceParameters = InstanceParameters{..}, ..} = do
        -- InstanceParameters
        -- Only put the Subindex part of the address
        put (contractSubindex instanceAddress)
        put instanceOwner
        put (GSWasm.miModuleRef instanceModuleInterface)
        put instanceInitName
        -- instanceReceiveFuns, instanceModuleInterface and instanceParameterHash
        -- are not included, since they can be derived from context.
        put instanceModel
        put instanceAmount

-- |Deserialize a smart contract instance in V0 format.
getInstanceV0
    :: (ModuleRef -> Wasm.InitName -> Maybe (Set.Set Wasm.ReceiveName, GSWasm.ModuleInterface))
    -- ^Function for resolving the receive functions and module interface.
    -> ContractIndex
    -- ^Index of the contract
    -> Get Instance
getInstanceV0 resolve idx = do
        -- InstanceParameters
        subindex <- get
        let instanceAddress = ContractAddress idx subindex
        instanceOwner <- get
        instanceContractModule <- get
        instanceInitName <- get
        (instanceReceiveFuns, instanceModuleInterface) <-
            case resolve instanceContractModule instanceInitName of
                Just r -> return r
                Nothing -> fail "Unable to resolve smart contract"
        instanceModel <- get
        instanceAmount <- get
        return $ makeInstance instanceInitName instanceReceiveFuns instanceModuleInterface instanceModel instanceAmount instanceOwner instanceAddress
