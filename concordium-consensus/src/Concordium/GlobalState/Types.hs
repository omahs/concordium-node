{-# LANGUAGE ScopedTypeVariables, StandaloneDeriving, TypeFamilies, UndecidableInstances, DerivingVia #-}
module Concordium.GlobalState.Types where

import Concordium.GlobalState.Classes
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Except
import Data.Kind

import Concordium.GlobalState.BlockPointer (BlockPointerData)

-- |The basic types associated with a monad providing an
-- implementation of the global state.
class (BlockStateTypes m, BlockPointerData (BlockPointerType m)) => GlobalStateTypes m where
    type BlockPointerType m :: Type

instance (GlobalStateTypes m) => GlobalStateTypes (MGSTrans t m) where
    type BlockPointerType (MGSTrans t m) = BlockPointerType m

deriving via (MGSTrans MaybeT m) instance (GlobalStateTypes m) => GlobalStateTypes (MaybeT m)
deriving via (MGSTrans (ExceptT e) m) instance (GlobalStateTypes m) => GlobalStateTypes (ExceptT e m)
