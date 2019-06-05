{-# LANGUAGE OverloadedStrings #-}
module SchedulerTests.DummyData where

import qualified Data.ByteString.Char8 as BS
import qualified Data.FixedByteString as FBS
import Concordium.Crypto.SHA256(Hash(..))
import Concordium.Crypto.SignatureScheme as Sig
import Concordium.Types hiding (accountAddress)
import Concordium.GlobalState.Transactions
import Concordium.ID.Account
import Concordium.ID.Types
import Concordium.ID.Attributes
import Concordium.Crypto.Ed25519Signature

import qualified Concordium.Scheduler.Types as Types

import System.Random

blockPointer :: BlockHash
blockPointer = Hash (FBS.pack (replicate 32 (fromIntegral (0 :: Word))))

makeHeader :: Sig.KeyPair -> Nonce -> Energy -> TransactionHeader
makeHeader kp nonce amount = makeTransactionHeader Sig.Ed25519 (Sig.verifyKey kp) nonce amount blockPointer


alesKP :: KeyPair
alesKP = fst (randomKeyPair (mkStdGen 1))

alesVK :: VerifyKey
alesVK = verifyKey alesKP

alesAccount :: AccountAddress
alesAccount = accountAddress alesVK Ed25519

thomasKP :: KeyPair
thomasKP = fst (randomKeyPair (mkStdGen 2))

thomasVK :: VerifyKey
thomasVK = verifyKey thomasKP

thomasAccount :: AccountAddress
thomasAccount = accountAddress thomasVK Ed25519

accountAddressFrom :: Int -> AccountAddress
accountAddressFrom n = accountAddress (accountVFKeyFrom n) Ed25519

accountVFKeyFrom :: Int -> VerifyKey
accountVFKeyFrom = verifyKey . fst . randomKeyPair . mkStdGen 

mkAccount ::AccountVerificationKey -> Amount -> Account
mkAccount vfKey amnt = Types.Account aaddr
                                     1 -- nonce
                                     amnt -- initial amount
                                     [] -- encrypted amounts
                                     Nothing -- no encryption key
                                     vfKey
                                     Ed25519
                                     []
  where aaddr = accountAddress vfKey Ed25519

-- |Make a dummy credential deployment information from an account registration
-- id and sequential registration id. All the proofs are dummy values, and there
-- is no anoymity revocation data.
mkDummyCDI :: AccountVerificationKey -> Int -> CredentialDeploymentInformation
mkDummyCDI vfKey nregId =
    CDI {cdi_verifKey = vfKey
        ,cdi_sigScheme = Ed25519
        ,cdi_regId = let d = show nregId
                         l = length d
                         pad = replicate (48-l) '0'
                     in RegIdCred (BS.pack (pad ++ d))
        ,cdi_arData = []
        ,cdi_ipId = IP_ID "ip_id"
        ,cdi_policy = AtomicMaxAccount (LessThan 100)
        ,cdi_auxData = "auxdata"
        ,cdi_proof = Proof "proof"
        }
