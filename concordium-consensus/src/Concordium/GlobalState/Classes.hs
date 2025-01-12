{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Definition of some basic typeclasses that give access to the basic types
-- used in the implementation and some lenses to access specific components
module Concordium.GlobalState.Classes where

import Control.Monad.IO.Class
import Control.Monad.Reader.Class
import Control.Monad.State.Class
import Control.Monad.Trans.Class
import Control.Monad.Writer.Class
import Data.Functor.Identity
import Data.Kind
import Lens.Micro.Platform

import Concordium.Logger
import Concordium.Types

-- |Defines a lens for accessing the global state component of a type.
class HasGlobalState g s | s -> g where
    globalState :: Lens' s g

instance HasGlobalState g (Identity g) where
    globalState = lens runIdentity (const Identity)

-- |Defines a lens for accessing the global state context.
class HasGlobalStateContext c r | r -> c where
    globalStateContext :: Lens' r c

instance HasGlobalStateContext g (Identity g) where
    globalStateContext = lens runIdentity (const Identity)

-- |@MGSTrans t m@ is a newtype wrapper for a monad transformer @t@ applied
-- to a monad @m@.  This wrapper exists to support lifting various monad
-- type classes over monad transfers. (That is, instances of various typeclasses
-- are defined where @t@ is a monad transformer and @m@ implements the typeclass.)
-- The primary use for this is to provide instances for other types using the
-- deriving via mechanism.
newtype MGSTrans t (m :: Type -> Type) a = MGSTrans (t m a)
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

instance MonadProtocolVersion m => MonadProtocolVersion (MGSTrans t m) where
    type MPV (MGSTrans t m) = MPV m

deriving instance MonadReader r (t m) => MonadReader r (MGSTrans t m)
deriving instance MonadState s (t m) => MonadState s (MGSTrans t m)
deriving instance MonadWriter w (t m) => MonadWriter w (MGSTrans t m)
deriving instance MonadLogger (t m) => MonadLogger (MGSTrans t m)
