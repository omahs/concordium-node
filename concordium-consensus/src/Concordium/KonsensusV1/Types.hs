{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Concordium.KonsensusV1.Types where

import Control.Monad
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Serialize
import qualified Data.Vector as Vector
import Data.Word
import Numeric.Natural

import qualified Concordium.Crypto.BlockSignature as BlockSig
import qualified Concordium.Crypto.BlsSignature as Bls
import qualified Concordium.Crypto.SHA256 as Hash
import qualified Concordium.Crypto.VRF as VRF
import Concordium.Genesis.Data.BaseV1
import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.Types.Transactions
import Concordium.Utils.BinarySearch
import Concordium.Utils.Serialization

import qualified Concordium.GlobalState.Basic.BlockState.LFMBTree as LFMBT

-- |A round number for consensus.
newtype Round = Round {theRound :: Word64}
    deriving (Eq, Ord, Show, Serialize, Num, Integral, Real, Enum, Bounded)

-- |A strict version of 'Maybe'.
data Option a
    = Absent
    | Present !a
    deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- |Putter for an @Option a@.
putOptionOf :: Putter a -> Putter (Option a)
putOptionOf _ Absent = putWord8 0
putOptionOf pa (Present a) = putWord8 1 >> pa a

-- |Getter for an @Option a@.
getOptionOf :: Get a -> Get (Option a)
getOptionOf ma = do
    getWord8 >>= \case
        0 -> return Absent
        _ -> Present <$> ma

-- |'Serialize' instance for an @Option a@.
instance (Serialize a) => Serialize (Option a) where
    put = putOptionOf put
    get = getOptionOf get

-- |Returns 'True' if and only if the value is 'Present'.
isPresent :: Option a -> Bool
isPresent Absent = False
isPresent (Present _) = True

-- |Returns 'True' if and only if the value is 'Absent'.
isAbsent :: Option a -> Bool
isAbsent Absent = True
isAbsent (Present _) = False

-- |The message that is signed by a finalizer to certify a block.
data QuorumSignatureMessage = QuorumSignatureMessage
    { -- |Hash of the genesis block.
      qsmGenesis :: !BlockHash,
      -- |Hash of the block being signed.
      qsmBlock :: !BlockHash,
      -- |Round of the block being signed.
      qsmRound :: !Round,
      -- |Epoch of the block being signed.
      qsmEpoch :: !Epoch
    }
    deriving (Eq, Show)

instance Serialize QuorumSignatureMessage where
    put QuorumSignatureMessage{..} = do
        put qsmGenesis
        put qsmBlock
        put qsmRound
        put qsmEpoch
    get = do
        qsmGenesis <- get
        qsmBlock <- get
        qsmRound <- get
        qsmEpoch <- get
        return QuorumSignatureMessage{..}

-- |Compute the byte representation of a 'QuorumSignatureMessage' that is actually signed.
quorumSignatureMessageBytes :: QuorumSignatureMessage -> BS.ByteString
quorumSignatureMessageBytes QuorumSignatureMessage{..} = runPut $ do
    putByteString "QUORUM."
    put qsmGenesis
    put qsmBlock
    put qsmRound
    put qsmEpoch

-- |Signature by a finalizer on a 'QuorumSignatureMessage', or an aggregation of signatures on a
-- common message.
newtype QuorumSignature = QuorumSignature {theQuorumSignature :: Bls.Signature}
    deriving (Eq, Ord, Show, Serialize, Semigroup, Monoid)

-- |Sign a 'QuorumSignatureMessage' with a baker's private key.
signQuorumSignatureMessage :: QuorumSignatureMessage -> BakerAggregationPrivateKey -> QuorumSignature
signQuorumSignatureMessage msg privKey =
    QuorumSignature $ Bls.sign (quorumSignatureMessageBytes msg) privKey

-- |Check the signature on a 'QuorumSignatureMessage' that is signed by a single party.
checkQuorumSignatureSingle ::
    QuorumSignatureMessage -> BakerAggregationVerifyKey -> QuorumSignature -> Bool
checkQuorumSignatureSingle msg pubKey =
    Bls.verify (quorumSignatureMessageBytes msg) pubKey
        . theQuorumSignature

-- |Check the signature on a 'QuorumSignatureMessage' that is signed by multiple parties.
checkQuorumSignature ::
    QuorumSignatureMessage -> [BakerAggregationVerifyKey] -> QuorumSignature -> Bool
checkQuorumSignature msg pubKeys =
    Bls.verifyAggregate (quorumSignatureMessageBytes msg) pubKeys
        . theQuorumSignature

-- |Index of a finalizer in the finalization committee vector.
newtype FinalizerIndex = FinalizerIndex {theFinalizerIndex :: Word32}
    deriving (Eq, Ord, Show, Enum, Bounded, Serialize)

-- |The message that is multicast by a finalizer when validating and signing blocks.
data QuorumMessage = QuorumMessage
    { -- |Signature on a 'QuorumSignatureMessage'
      qmSignature :: !QuorumSignature,
      -- |Hash of the block that was was signed.
      qmBlock :: !BlockHash,
      -- |The index of the finalizer multicasting this message.
      qmFinalizerIndex :: !FinalizerIndex,
      -- |Round of the block that was signed.
      qmRound :: !Round,
      -- |Epoch of the block that was signed.
      qmEpoch :: !Epoch
    }
    deriving (Eq, Show)

instance Serialize QuorumMessage where
    put QuorumMessage{..} = do
        put qmSignature
        put qmBlock
        put qmFinalizerIndex
        put qmRound
        put qmEpoch
    get = do
        qmSignature <- get
        qmBlock <- get
        qmFinalizerIndex <- get
        qmRound <- get
        qmEpoch <- get
        return QuorumMessage{..}

-- |Information about a finalizer.
data FinalizerInfo = PartyInfo
    { -- |The index of the finalizer in the finalization committee vector.
      finalizerIndex :: !FinalizerIndex,
      -- |The voter power of the finalizer
      finalizerWeight :: !VoterPower,
      -- |The block signature verification key of the finalizer
      finalizerSignKey :: !BlockSig.VerifyKey,
      -- |The VRF public key of the finalizer
      finalizerVRFKey :: !VRF.PublicKey,
      -- |The BLS public key of the finalizer
      finalizerBlsKey :: !Bls.PublicKey,
      -- |The baker ID of the finalizer
      finalizerBakerId :: !BakerId
    }
    deriving (Eq, Ord)

instance Show FinalizerInfo where
    show = show . finalizerIndex

-- |The finalization committee.
data FinalizationCommittee = FinalizationCommittee
    { -- |All eligible finalizers, in ascending order of baker ID
      committeeFinalizers :: !(Vector.Vector FinalizerInfo),
      -- |The total voter power.
      committeeTotalWeight :: !VoterPower
    }
    deriving (Eq, Show)

-- |Get the 'FinalizerInfo' associated for a particular 'BakerId'.
finalizerByBakerId :: FinalizationCommittee -> BakerId -> Maybe FinalizerInfo
finalizerByBakerId = binarySearch finalizerBakerId . committeeFinalizers

-- |A set of 'FinalizerIndex'es.
-- This is represented as a bit vector, where the bit @i@ is set iff the finalizer index @i@ is
-- in the set.
newtype FinalizerSet = FinalizerSet {theFinalizerSet :: Natural}
    deriving (Eq)

-- |The serialization of a 'FinalizerSet' consists of a length (Word32, big-endian), followed by
-- that many bytes, the first of which (if any) must be non-zero. These bytes encode the bit-vector
-- in big-endian. This enforces that the serialization of a finalizer set is unique.
instance Serialize FinalizerSet where
    put fs = do
        let (byteCount, putBytes) = unroll 0 (return ()) (theFinalizerSet fs)
        putWord32be byteCount
        putBytes
      where
        unroll :: Word32 -> Put -> Natural -> (Word32, Put)
        -- Compute the number of bytes and construct a 'Put' that serializes in big-endian.
        -- We do this by adding the low order byte to the accumulated 'Put' (at the start)
        -- and recursing with the bitvector shifted right 8 bits.
        unroll bc cont 0 = (bc, cont)
        unroll bc cont n = unroll (bc + 1) (putWord8 (fromIntegral n) >> cont) (shiftR n 8)
    get = label "FinalizerSet" $ do
        byteCount <- getWord32be
        FinalizerSet <$> roll1 byteCount
      where
        roll1 0 = return 0
        roll1 bc = do
            b <- getWord8
            when (b == 0) $ fail "unexpected 0 byte"
            roll (bc - 1) (fromIntegral b)
        roll 0 n = return n
        roll bc n = do
            b <- getWord8
            roll (bc - 1) (shiftL n 8 .|. fromIntegral b)

-- |Convert a 'FinalizerSet' to a list of 'FinalizerIndex'.
finalizerList :: FinalizerSet -> [FinalizerIndex]
finalizerList = unroll 0 . theFinalizerSet
  where
    unroll _ 0 = []
    unroll i x
        | testBit x 0 = FinalizerIndex i : r
        | otherwise = r
      where
        r = unroll (i + 1) (shiftR x 1)

instance Show FinalizerSet where
    show = show . finalizerList

-- | A quorum certificate, to be formed when enough finalizers have signed the same 'QuorumSignatureMessage'.
data QuorumCertificate = QuorumCertificate
    { -- |Hash of the block this certificate refers to.
      qcBlock :: !BlockHash,
      -- |Round of the block this certificate refers to.
      qcRound :: !Round,
      -- |Epoch of the block this certificate refers to.
      qcEpoch :: !Epoch,
      -- |Aggregate signature on the 'QuorumSignatureMessage' with the block hash 'qcBlock'.
      qcAggregateSignature :: !QuorumSignature,
      -- |The set of finalizers whose signature is in 'qcAggregateSignature'.
      qcSignatories :: !FinalizerSet
    }
    deriving (Eq, Show)

instance Serialize QuorumCertificate where
    put QuorumCertificate{..} = do
        put qcBlock
        put qcRound
        put qcEpoch
        put qcAggregateSignature
        put qcSignatories
    get = do
        qcBlock <- get
        qcRound <- get
        qcEpoch <- get
        qcAggregateSignature <- get
        qcSignatories <- get
        return QuorumCertificate{..}

instance HashableTo Hash.Hash QuorumCertificate where
    getHash = Hash.hash . encode

-- |Check the signature in a quorum certificate.
checkQuorumCertificateSignature ::
    -- |Genesis block hash
    BlockHash ->
    (FinalizerSet -> [BakerAggregationVerifyKey]) ->
    QuorumCertificate ->
    Bool
checkQuorumCertificateSignature qsmGenesis toKeys QuorumCertificate{..} =
    checkQuorumSignature qsm (toKeys qcSignatories) qcAggregateSignature
  where
    qsm = QuorumSignatureMessage{qsmGenesis = qsmGenesis, qsmBlock = qcBlock, qsmRound = qcRound, qsmEpoch = qcEpoch}

-- |A Merkle proof that one block is the successor of another.
type SuccessorProof = BlockQuasiHash

-- |Compute the 'BlockHash' of a block that is the successor of another block.
successorBlockHash ::
    -- |Block header
    BlockHeader ->
    -- |Successor proof
    SuccessorProof ->
    BlockHash
successorBlockHash bh = computeBlockHash bhh
  where
    bhh = getHash bh

-- |A finalization entry that witnesses that a block has been finalized with quorum certificates
-- for two consecutive rounds. The finalization entry includes a proof that the blocks are in
-- consecutive rounds so that the entry can be validated without the second block.
--
-- The following invariants hold:
--
-- - @qcRound feSuccessorQuorumCertificate == qcRound feFinalizedQuorumCertificate + 1@
-- - @qcBlock feSuccessorQuorumCertificate == successorBlockHash (BlockHeader (qcRound feSuccessorQuorumCertificate) (qcEpoch feSuccessorQuorumCertificate) (qcBlock feFinalizedQuorumCertificate)) feSuccessorProof@
data FinalizationEntry = FinalizationEntry
    { -- |Quorum certificate for the finalized block.
      feFinalizedQuorumCertificate :: !QuorumCertificate,
      -- |Quorum certificate for the successor block.
      feSuccessorQuorumCertificate :: !QuorumCertificate,
      -- |Proof that establishes the successor block is the immediate successor of the finalized
      -- block (without further knowledge of the successor block beyond its hash).
      feSuccessorProof :: !SuccessorProof
    }
    deriving (Eq, Show)

instance Serialize FinalizationEntry where
    put FinalizationEntry{..} = do
        put feFinalizedQuorumCertificate
        let QuorumCertificate{..} = feSuccessorQuorumCertificate
        put qcEpoch
        put qcAggregateSignature
        put qcSignatories
        put feSuccessorProof
    get = do
        feFinalizedQuorumCertificate <- get
        qcEpoch <- get
        qcAggregateSignature <- get
        qcSignatories <- get
        feSuccessorProof <- get
        let sqcRound = qcRound feFinalizedQuorumCertificate + 1
        let feSuccessorQuorumCertificate =
                QuorumCertificate
                    { qcRound = sqcRound,
                      qcBlock =
                        successorBlockHash
                            ( BlockHeader
                                sqcRound
                                qcEpoch
                                (qcBlock feFinalizedQuorumCertificate)
                            )
                            feSuccessorProof,
                      ..
                    }
        return FinalizationEntry{..}

instance HashableTo Hash.Hash (Option FinalizationEntry) where
    getHash Absent = Hash.hash $ encode (0 :: Word8)
    getHash (Present fe) = Hash.hash $ runPut $ do
        putWord8 1
        put fe

-- |The message that is signed by the sender of a timeout message, to indicate that a round has
-- timed out for the sender.
data TimeoutSignatureMessage = TimeoutSignatureMessage
    { -- |Hash of the genesis block.
      tsmGenesis :: !BlockHash,
      -- |Round number of the timed-out round
      tsmRound :: !Round,
      -- |Round number of the highest known valid quorum certificate.
      tsmQCRound :: !Round,
      -- |Epoch number of the highest known valid quorum certificate.
      tsmQCEpoch :: !Epoch
    }
    deriving (Eq, Show)

instance Serialize TimeoutSignatureMessage where
    put TimeoutSignatureMessage{..} = do
        put tsmGenesis
        put tsmRound
        put tsmQCRound
        put tsmQCEpoch
    get = do
        tsmGenesis <- get
        tsmRound <- get
        tsmQCRound <- get
        tsmQCEpoch <- get
        return TimeoutSignatureMessage{..}

-- |Compute the byte representation of a 'TimeoutSignatureMessage' that is actually signed.
timeoutSignatureMessageBytes :: TimeoutSignatureMessage -> BS.ByteString
timeoutSignatureMessageBytes TimeoutSignatureMessage{..} = runPut $ do
    putByteString "TIMEOUT."
    put tsmGenesis
    put tsmRound
    put tsmQCRound
    put tsmQCEpoch

-- |Signature by a finalizer on a 'TimeoutSignatureMessage', or an aggregation of such signatures.
newtype TimeoutSignature = TimeoutSignature {theTimeoutSignature :: Bls.Signature}
    deriving (Eq, Ord, Show, Serialize, Semigroup, Monoid)

-- |Sign a 'TimeoutSignatureMessage' with a Baker's private key.
signTimeoutSignatureMessage :: TimeoutSignatureMessage -> BakerAggregationPrivateKey -> TimeoutSignature
signTimeoutSignatureMessage msg privKey =
    TimeoutSignature $ Bls.sign (timeoutSignatureMessageBytes msg) privKey

-- |Check the signature on a 'TimeoutSignatureMessage' that is signed by a single party.
checkTimeoutSignatureSingle ::
    TimeoutSignatureMessage -> BakerAggregationVerifyKey -> TimeoutSignature -> Bool
checkTimeoutSignatureSingle msg pubKey =
    Bls.verify (timeoutSignatureMessageBytes msg) pubKey
        . theTimeoutSignature

-- |Data structure recording which finalizers have quorum certificates for which rounds.
--
-- Invariant: @Map.size theFinalizerRounds <= fromIntegral (maxBound :: Word32)@.
newtype FinalizerRounds = FinalizerRounds {theFinalizerRounds :: Map.Map Round FinalizerSet}
    deriving (Eq, Show)

instance Serialize FinalizerRounds where
    put (FinalizerRounds fr) = do
        putWord32be $ fromIntegral $ Map.size fr
        putSafeSizedMapOf put put fr
    get = do
        count <- getWord32be
        FinalizerRounds <$> getSafeSizedMapOf count get get

-- |Unpack a 'FinalizerRounds' as a list of rounds and finalizer sets, in ascending order of
-- round.
finalizerRoundsList :: FinalizerRounds -> [(Round, FinalizerSet)]
finalizerRoundsList = Map.toAscList . theFinalizerRounds

-- |A timeout certificate aggregates signatures on timeout messages for the same round.
-- Finalizers may have different QC rounds.
--
-- Invariant: If 'tcFinalizerQCRoundsSecondEpoch' is not empty, then so is
-- 'tcFinalizerQCRoundsFirstEpoch'.
data TimeoutCertificate = TimeoutCertificate
    { -- |The round that has timed-out.
      tcRound :: !Round,
      -- |The minimum epoch for which we include signatures.
      tcMinEpoch :: !Epoch,
      -- |The rounds for which finalizers have their best QCs in the epoch 'tcMinEpoch'.
      tcFinalizerQCRoundsFirstEpoch :: !FinalizerRounds,
      -- |The rounds for which finalizers have their best QCs in the epoch @tcMinEpoch + 1@.
      tcFinalizerQCRoundsSecondEpoch :: !FinalizerRounds,
      -- |Aggregate of the finalizers' 'TimeoutSignature's on the round and QC round.
      tcAggregateSignature :: !TimeoutSignature
    }
    deriving (Eq, Show)

instance Serialize TimeoutCertificate where
    put TimeoutCertificate{..} = do
        put tcRound
        put tcMinEpoch
        put tcAggregateSignature
        put tcFinalizerQCRoundsFirstEpoch
        put tcFinalizerQCRoundsSecondEpoch
    get = label "TimeoutCertificate" $ do
        tcRound <- get
        tcMinEpoch <- get
        tcAggregateSignature <- get
        tcFinalizerQCRoundsFirstEpoch <- get
        tcFinalizerQCRoundsSecondEpoch <- get
        when (null (theFinalizerRounds tcFinalizerQCRoundsFirstEpoch)) $
            unless (null (theFinalizerRounds tcFinalizerQCRoundsSecondEpoch)) $
                fail "tcMinEpoch is not the minimum epoch"
        return TimeoutCertificate{..}

instance HashableTo Hash.Hash (Option TimeoutCertificate) where
    getHash Absent = Hash.hash $ encode (0 :: Word8)
    getHash (Present tc) = Hash.hash $ runPut $ do
        putWord8 1
        put tc

-- |Check the signature in a timeout certificate.
checkTimeoutCertificateSignature ::
    -- |Genesis block hash
    BlockHash ->
    -- |Get the public keys for a set of finalizers for a given 'Epoch'.
    (FinalizerSet -> Epoch -> [BakerAggregationVerifyKey]) ->
    TimeoutCertificate ->
    Bool
checkTimeoutCertificateSignature tsmGenesis toKeys TimeoutCertificate{..} =
    Bls.verifyAggregateHybrid msgsKeys (theTimeoutSignature tcAggregateSignature)
  where
    msgsKeysForEpoch tsmQCEpoch finalizerRounds =
        [ ( timeoutSignatureMessageBytes TimeoutSignatureMessage{tsmRound = tcRound, ..},
            toKeys fs tsmQCEpoch
          )
          | (tsmQCRound, fs) <- finalizerRoundsList finalizerRounds
        ]
    msgsKeys =
        msgsKeysForEpoch tcMinEpoch tcFinalizerQCRoundsFirstEpoch
            ++ msgsKeysForEpoch (tcMinEpoch + 1) tcFinalizerQCRoundsSecondEpoch

-- |The body of a timeout message. Timeout messages are generated by the finalizers
-- when not enough enough signatures are received within a certain time.
--
-- The following invariants apply:
--
-- * @qcRound tmQuorumCertificate < tmRound@
-- * if @qcRound tmQuorumCertificate + 1 /= tmRound@ then @isJust tmTimeoutCertificate@
-- * if @tmTimeoutCertificate == Just tc@ then @tcRound tc + 1 == tmRound@
data TimeoutMessageBody = TimeoutMessageBody
    { -- |Index of the finalizer sending the timeout message.
      tmFinalizerIndex :: !FinalizerIndex,
      -- |Round number of the round being timed-out.
      tmRound :: !Round,
      -- |Highest quorum certificate known to the sender at the time of timeout.
      tmQuorumCertificate :: !QuorumCertificate,
      -- |A timeout certificate if the previous round timed out, or 'Nothing' otherwise.
      tmTimeoutCertificate :: !(Option TimeoutCertificate),
      -- |A epoch finalization entry for the epoch @qcEpoch tmQuorumCertificate@, if one is known.
      tmEpochFinalizationEntry :: !(Option FinalizationEntry),
      -- |A 'TimeoutSignature' from the sender for this round.
      tmAggregateSignature :: !TimeoutSignature
    }
    deriving (Eq, Show)

instance Serialize TimeoutMessageBody where
    put TimeoutMessageBody{..} = do
        putWord8 tmFlags
        put tmFinalizerIndex
        put tmQuorumCertificate
        putTC
        putEFE
        put tmAggregateSignature
      where
        (tcFlag, putTC) = case tmTimeoutCertificate of
            Absent -> (0, return ())
            Present tc -> (bit 0, put tc)
        (efeFlag, putEFE) = case tmEpochFinalizationEntry of
            Absent -> (0, return ())
            Present efe -> (bit 1, put efe)
        tmFlags = tcFlag .|. efeFlag
    get = label "TimeoutMessageBody" $ do
        tmFlags <- getWord8
        unless (tmFlags .&. 0b11 == tmFlags) $
            fail $
                "deserialization encountered invalid flag byte (" ++ show tmFlags ++ ")"
        tmFinalizerIndex <- get
        tmQuorumCertificate <- get
        (tmRound, tmTimeoutCertificate) <-
            if testBit tmFlags 0
                then do
                    tc <- get
                    unless (qcRound tmQuorumCertificate <= tcRound tc) $
                        fail $
                            "failed check: quorum certificate round (" ++ show (qcRound tmQuorumCertificate) ++ ") <= timeout certificate round (" ++ show (tcRound tc) ++ ")"
                    return (tcRound tc + 1, Present tc)
                else return (qcRound tmQuorumCertificate + 1, Absent)
        tmEpochFinalizationEntry <-
            if testBit tmFlags 1
                then do
                    Present <$> get
                else return Absent
        tmAggregateSignature <- get
        return TimeoutMessageBody{..}

-- |The 'TimeoutSignatureMessage' associated with a 'TimeoutMessageBody'.
tmSignatureMessage ::
    -- |Genesis block hash
    BlockHash ->
    -- |The timeout message body
    TimeoutMessageBody ->
    -- |The resulting timeout signature message
    TimeoutSignatureMessage
tmSignatureMessage tsmGenesis tmb =
    TimeoutSignatureMessage
        { tsmRound = tmRound tmb,
          tsmQCRound = qcRound (tmQuorumCertificate tmb),
          tsmQCEpoch = qcEpoch (tmQuorumCertificate tmb),
          ..
        }

-- |A timeout message including the sender's signature.
data TimeoutMessage = TimeoutMessage
    { -- |Body of the timeout message.
      tmBody :: !TimeoutMessageBody,
      -- |Signature on the timeout message.
      tmSignature :: !BlockSig.Signature
    }
    deriving (Eq, Show)

instance Serialize TimeoutMessage where
    put TimeoutMessage{..} = do
        put tmBody
        put tmSignature
    get = do
        tmBody <- get
        tmSignature <- get
        return TimeoutMessage{..}

-- |Byte representation of a 'TimeoutMessageBody' used for signing the timeout message.
timeoutMessageBodySignatureBytes ::
    -- |The contents of the timeout message.
    TimeoutMessageBody ->
    -- |The genesis block hash.
    BlockHash ->
    -- |The resulting bytestring to sign.
    BS.ByteString
timeoutMessageBodySignatureBytes body genesisHash = runPut $ do
    putByteString "TIMEOUTMESSAGE."
    put body
    put genesisHash

-- |Sign a timeout message.
signTimeoutMessage ::
    -- |The contents of the timeout message.
    TimeoutMessageBody ->
    -- |The genesis block hash.
    BlockHash ->
    -- |The private key of the baker.
    BakerSignPrivateKey ->
    -- |The resulting signed timeout message.
    TimeoutMessage
signTimeoutMessage tmBody genesisHash privKey = TimeoutMessage{..}
  where
    msg = timeoutMessageBodySignatureBytes tmBody genesisHash
    tmSignature = BlockSig.sign privKey msg

-- |Check the signature on a timeout message.
checkTimeoutMessageSignature ::
    -- |The public key of the baker.
    BakerSignVerifyKey ->
    -- |The genesis block hash.
    BlockHash ->
    -- |The timeout message
    TimeoutMessage ->
    -- |Whether the signature could be verified or not.
    Bool
checkTimeoutMessageSignature pubKey genesisHash TimeoutMessage{..} =
    BlockSig.verify pubKey (timeoutMessageBodySignatureBytes tmBody genesisHash) tmSignature

-- |Projections for the data associated with a baked (i.e. non-genesis) block.
class BakedBlockData d where
    -- |Quorum certificate on the parent block.
    blockQuorumCertificate :: d -> QuorumCertificate

    -- |Parent block hash.
    blockParent :: d -> BlockHash
    blockParent = qcBlock . blockQuorumCertificate

    -- |'BakerId' of the baker of the block.
    blockBaker :: d -> BakerId

    -- |If the previous round timed-out, the timeout certificate for that round.
    blockTimeoutCertificate :: d -> Option TimeoutCertificate

    -- |If this block begins a new epoch, this is the finalization entry that finalizes the
    -- trigger block.
    blockEpochFinalizationEntry :: d -> Option FinalizationEntry

    -- |The 'BlockNonce' generated by the baker's VRF.
    blockNonce :: d -> BlockNonce

    -- |The baker's signature on the block.
    blockSignature :: d -> BlockSignature

-- |Projections for the data associated with a block (including a genesis block).
class BlockData b where
    -- |An associated type that should be an instance of 'BakedBlockData'.
    -- This is returned by 'blockBakedData' for non-genesis blocks.
    type BakedBlockDataType b

    -- |Round number of the block.
    blockRound :: b -> Round

    -- |Epoch number of the block.
    blockEpoch :: b -> Epoch

    -- |Timestamp of the block.
    blockTimestamp :: b -> Timestamp

    -- |If the block is a baked (i.e. non-genesis) block, this returns the baked block data.
    -- If the block is a genesis block, this returns 'Absent'.
    blockBakedData :: b -> Option (BakedBlockDataType b)

    -- |The list of transactions in the block.
    blockTransactions :: b -> [BlockItem]

    -- |The hash of the block state after executing the block.
    blockStateHash :: b -> StateHash

-- |A 'BakedBlock' consists of a non-genesis block, excluding the block signature.
data BakedBlock = BakedBlock
    { -- |Block round number. Must be non-zero.
      bbRound :: !Round,
      -- |Block epoch number.
      bbEpoch :: !Epoch,
      -- |Block nominal timestamp.
      bbTimestamp :: !Timestamp,
      -- |Block baker identity.
      bbBaker :: !BakerId,
      -- |Quorum certificate of parent block.
      bbQuorumCertificate :: !QuorumCertificate,
      -- |Timeout certificate if the previous round timed-out.
      bbTimeoutCertificate :: !(Option TimeoutCertificate),
      -- |Epoch finalization entry if this is the first block in a new epoch.
      bbEpochFinalizationEntry :: !(Option FinalizationEntry),
      -- |Block nonce generated from the baker's VRF.
      bbNonce :: !BlockNonce,
      -- |Transactions in the block.
      bbTransactions :: !(Vector.Vector BlockItem),
      -- |Hash of the transaction outcomes.
      bbTransactionOutcomesHash :: !TransactionOutcomesHash,
      -- |Hash of the block state.
      bbStateHash :: !StateHash
    }
    deriving (Eq, Show)

-- |Flags indicating which optional values are set in a 'BakedBlock'.
data BakedBlockFlags = BakedBlockFlags
    { bbfTimeoutCertificate :: !Bool,
      bbfEpochFinalizationEntry :: !Bool
    }

-- |Get the 'BakedBlockFlags' associated with a 'BakedBlock'.
bakedBlockFlags :: BakedBlock -> BakedBlockFlags
bakedBlockFlags BakedBlock{..} =
    BakedBlockFlags
        { bbfTimeoutCertificate = isPresent bbTimeoutCertificate,
          bbfEpochFinalizationEntry = isPresent bbEpochFinalizationEntry
        }

instance Serialize BakedBlockFlags where
    put BakedBlockFlags{..} = putWord8 bits
      where
        bits = toBit 0 bbfTimeoutCertificate .|. toBit 1 bbfEpochFinalizationEntry
        toBit _ False = 0
        toBit i True = bit i
    get = label "BakedBlockFlags" $ do
        bits <- getWord8
        unless (bits == bits .&. 0b11) $ fail "Invalid BakedBlockFlags."
        return $
            BakedBlockFlags
                { bbfTimeoutCertificate = testBit bits 0,
                  bbfEpochFinalizationEntry = testBit bits 1
                }

-- |Serialize a 'BakedBlock'.
putBakedBlock :: Putter BakedBlock
putBakedBlock bb@BakedBlock{..} = do
    put bbRound
    put bbEpoch
    put bbTimestamp
    put bbBaker
    put bbNonce
    put bbStateHash
    put bbTransactionOutcomesHash
    put bbQuorumCertificate
    put (bakedBlockFlags bb)
    mapM_ put bbTimeoutCertificate
    mapM_ put bbEpochFinalizationEntry
    putWord64be (fromIntegral (Vector.length bbTransactions))
    mapM_ putBlockItemV0 bbTransactions

-- |Deserialize a 'BakedBlock'. The protocol version is used to determine which transaction
-- types are allowed in the block.
getBakedBlock :: SProtocolVersion pv -> TransactionTime -> Get BakedBlock
getBakedBlock spv tt = label "BakedBlock" $ do
    bbRound <- get
    bbEpoch <- get
    bbTimestamp <- get
    bbBaker <- get
    bbNonce <- get
    bbStateHash <- get
    bbTransactionOutcomesHash <- get
    bbQuorumCertificate <- get
    BakedBlockFlags{..} <- get
    bbTimeoutCertificate <-
        if bbfTimeoutCertificate
            then Present <$> get
            else return Absent
    bbEpochFinalizationEntry <-
        if bbfEpochFinalizationEntry
            then Present <$> get
            else return Absent
    numTrans <- getWord64be
    -- We check that there is at least one byte remaining in the serialization per transaction.
    -- This is to prevent a malformed block from causing us to allocate an excessively large vector,
    -- as this could lead to an out-of-memory error. [Note: It seems Vector.replicateM actually
    -- goes via a list in any case, so this may be a non-issue. However, this gives us a bit more
    -- assurance.]
    remBytes <- remaining
    when (fromIntegral remBytes < numTrans) $
        fail $
            "Block should have "
                ++ show numTrans
                ++ " transactions, but only "
                ++ show remBytes
                ++ " bytes remain"
    bbTransactions <- Vector.replicateM (fromIntegral numTrans) (getBlockItemV0 spv tt)
    return BakedBlock{..}

-- |A baked block, together with the block hash and block signature.
--
-- Invariant: @sbHash == getHash sbBlock@.
data SignedBlock = SignedBlock
    { -- |The block contents.
      sbBlock :: !BakedBlock,
      -- |The hash of the block.
      sbHash :: !BlockHash,
      -- |Signature of the baker on the block.
      sbSignature :: !BlockSignature
    }
    deriving (Eq, Show)

instance BakedBlockData SignedBlock where
    blockQuorumCertificate = bbQuorumCertificate . sbBlock
    blockBaker = bbBaker . sbBlock
    blockTimeoutCertificate = bbTimeoutCertificate . sbBlock
    blockEpochFinalizationEntry = bbEpochFinalizationEntry . sbBlock
    blockNonce = bbNonce . sbBlock
    blockSignature = sbSignature

instance BlockData SignedBlock where
    type BakedBlockDataType SignedBlock = SignedBlock
    blockRound = bbRound . sbBlock
    blockEpoch = bbEpoch . sbBlock
    blockTimestamp = bbTimestamp . sbBlock
    blockBakedData = Present
    blockTransactions = Vector.toList . bbTransactions . sbBlock
    blockStateHash = bbStateHash . sbBlock

instance HashableTo BlockHash SignedBlock where
    getHash = sbHash

instance Monad m => MHashableTo m BlockHash SignedBlock

-- |Serialize a 'SignedBlock', including the signature.
putSignedBlock :: Putter SignedBlock
putSignedBlock SignedBlock{..} = do
    putBakedBlock sbBlock
    put sbSignature

-- |Deserialize a 'SignedBlock'. The protocol version is used to determine which transactions types
-- are permitted.
getSignedBlock :: SProtocolVersion pv -> TransactionTime -> Get SignedBlock
getSignedBlock spv tt = do
    sbBlock <- getBakedBlock spv tt
    let sbHash = getHash sbBlock
    sbSignature <- get
    return SignedBlock{..}

-- |The bytes that are signed by a block signature.
-- Note that this concatenates the provided genesis hash with the block hash.
-- The same genesis hash must be provided when signing the block in order to verify the block signature.
-- This function outputs the bytestring consisting of H(genesisBlockHash || blockHash).
blockSignatureMessageBytes ::
    -- |Hash of the genesis block
    BlockHash ->
    -- |Hash of the block
    BlockHash ->
    -- |The H(genesisBlockHash || blockHash) bytestring.
    BS.ByteString
blockSignatureMessageBytes genesisHash bHash = Hash.hashToByteString $! Hash.hashOfHashes (blockHash genesisHash) (blockHash bHash)

-- |Verify that a block is correctly signed by the baker key provided.
-- The hash that is verified is H(genesisBlockHash || blockHash)
verifyBlockSignature ::
    (BakedBlockData b, HashableTo BlockHash b) =>
    -- |The public key of the baker to use for the signature check.
    BakerSignVerifyKey ->
    -- |The genesis block hash
    BlockHash ->
    -- |The data of the block that is signed.
    b ->
    -- |'True' if the signature can be verified otherwise 'False'.
    Bool
verifyBlockSignature key genesisHash b =
    BlockSig.verify
        key
        (blockSignatureMessageBytes genesisHash $! getHash b)
        (blockSignature b)

-- |Sign a block hash as a baker.
-- The hash that is signed is H(genesisBlockHash || blockHash)
signBlockHash ::
    -- |The key to use for signing the block hash.
    BakerSignPrivateKey ->
    -- |The genesis hash
    BlockHash ->
    -- |The block hash
    BlockHash ->
    -- |The resulting block signature
    BlockSignature
signBlockHash privKey genesisHash bh = BlockSig.sign privKey (blockSignatureMessageBytes genesisHash bh)

-- |Sign a block as a baker.
signBlock ::
    -- |The key to use for signing
    BakerSignPrivateKey ->
    -- |The genesis hash
    BlockHash ->
    -- |The baked block
    BakedBlock ->
    -- |The resulting signed block.
    SignedBlock
signBlock privKey genesisHash sbBlock = SignedBlock{..}
  where
    sbHash = getHash sbBlock
    sbSignature = signBlockHash privKey genesisHash sbHash

-- |Message used to generate the block nonce with the VRF.
blockNonceMessage :: LeadershipElectionNonce -> Round -> BS.ByteString
blockNonceMessage leNonce rnd = runPut $ do
    putByteString "NONCE"
    put leNonce
    put rnd

-- |Generate the block nonce.
computeBlockNonce :: LeadershipElectionNonce -> Round -> BakerElectionPrivateKey -> BlockNonce
computeBlockNonce leNonce rnd key = VRF.prove key (blockNonceMessage leNonce rnd)

-- |Verify a block nonce.
verifyBlockNonce :: LeadershipElectionNonce -> Round -> BakerElectionVerifyKey -> BlockNonce -> Bool
verifyBlockNonce leNonce rnd verifKey = VRF.verify verifKey (blockNonceMessage leNonce rnd)

-- |The 'BlockHeader' consists of basic information about the block that is used in the generation
-- of the block hash. This data is near the root of the Merkle tree constructing the block hash.
data BlockHeader = BlockHeader
    { -- |Round number of the block.
      bhRound :: !Round,
      -- |Epoch number of the block.
      bhEpoch :: !Epoch,
      -- |Hash of the parent block.
      bhParent :: !BlockHash
    }
    deriving (Eq)

-- |The block header for a 'BakedBlock'.
bbBlockHeader :: BakedBlock -> BlockHeader
bbBlockHeader BakedBlock{..} =
    BlockHeader
        { bhRound = bbRound,
          bhEpoch = bbEpoch,
          bhParent = qcBlock bbQuorumCertificate
        }

-- |The hash of a 'BlockHeader'. This is combined with the 'BlockQuasiHash' to produce a
-- 'BlockHash'.
newtype BlockHeaderHash = BlockHeaderHash {theBlockHeaderHash :: Hash.Hash}
    deriving (Eq, Ord, Show, Serialize)

instance HashableTo BlockHeaderHash BlockHeader where
    getHash BlockHeader{..} = BlockHeaderHash $ Hash.hash $ runPut $ do
        put bhRound
        put bhEpoch
        put bhParent

instance HashableTo BlockHeaderHash BakedBlock where
    getHash = getHash . bbBlockHeader

-- |Hash of a block's contents. This is combined with the 'BlockHeaderHash' to produce a
-- 'BlockHash'.
newtype BlockQuasiHash = BlockQuasiHash {theBlockQuasiHash :: Hash.Hash}
    deriving (Eq, Ord, Show, Serialize)

-- |Compute the hash from a list of transactions.
computeTransactionsHash :: Vector.Vector BlockItem -> Hash.Hash
computeTransactionsHash bis =
    LFMBT.hashAsLFMBT
        (Hash.hash "")
        (v0TransactionHash . getHash <$> Vector.toList bis)

instance HashableTo BlockQuasiHash BakedBlock where
    getHash BakedBlock{..} = BlockQuasiHash $ Hash.hashOfHashes metaHash dataHash
      where
        metaHash = Hash.hashOfHashes bakerInfoHash certificatesHash
          where
            bakerInfoHash = Hash.hashOfHashes timestampBakerHash nonceHash
              where
                timestampBakerHash = Hash.hash $ runPut $ do
                    put bbTimestamp
                    put bbBaker
                nonceHash = Hash.hash $ encode bbNonce
            certificatesHash = Hash.hashOfHashes qcHash timeoutFinalizationHash
              where
                qcHash = getHash bbQuorumCertificate
                timeoutFinalizationHash = Hash.hashOfHashes timeoutHash finalizationHash
                  where
                    timeoutHash = getHash bbTimeoutCertificate
                    finalizationHash = getHash bbEpochFinalizationEntry
        dataHash = Hash.hashOfHashes transactionsAndOutcomesHash stateHash
          where
            transactionsAndOutcomesHash = Hash.hashOfHashes transactionsHash outcomesHash
              where
                transactionsHash = computeTransactionsHash bbTransactions
                outcomesHash = tohGet bbTransactionOutcomesHash
            stateHash = v0StateHash bbStateHash

-- |Compute the block hash from the header hash and quasi-hash.
computeBlockHash :: BlockHeaderHash -> BlockQuasiHash -> BlockHash
computeBlockHash bhh bqh =
    BlockHash $
        Hash.hashOfHashes
            (theBlockHeaderHash bhh)
            (theBlockQuasiHash bqh)

instance HashableTo BlockHash BakedBlock where
    getHash bb = computeBlockHash (getHash bb) (getHash bb)

-- |A collection of signatures
-- This is a map from 'FinalizerIndex' to the actual signature message.
newtype SignatureMessages a = SignatureMessages
    { smFinIdxToMessage :: Map.Map FinalizerIndex a
    }
    deriving (Eq, Show)

-- |Construct an empty 'SignatureMessages'
emptySignatureMessages :: SignatureMessages a
emptySignatureMessages = SignatureMessages Map.empty

-- |Serialize instance for @SignatureMessages a@.
instance (Serialize a) => Serialize (SignatureMessages a) where
    put (SignatureMessages fiMsgMap) = do
        putWord32be $! fromIntegral $! Map.size fiMsgMap
        putSafeSizedMapOf put put fiMsgMap
    get = do
        count <- getWord32be
        SignatureMessages <$> getSafeSizedMapOf count get get

-- |Configuration information stored for the genesis block.
data GenesisMetadata = GenesisMetadata
    { -- |Core genesis parameters.
      gmParameters :: !CoreGenesisParametersV1,
      -- |Hash of the genesis block.
      gmCurrentGenesisHash :: !BlockHash,
      -- |Hash of the first genesis block.
      gmFirstGenesisHash :: !BlockHash,
      -- |Hash of the genesis block state (after migration).
      gmStateHash :: !StateHash
    }
    deriving (Eq, Show)

instance Serialize GenesisMetadata where
    put GenesisMetadata{..} = do
        put gmParameters
        put gmCurrentGenesisHash
        put gmFirstGenesisHash
        put gmStateHash
    get = do
        gmParameters <- get
        gmCurrentGenesisHash <- get
        gmFirstGenesisHash <- get
        gmStateHash <- get
        return GenesisMetadata{..}

-- |Either a genesis block or a normal block.
-- A normal block MUST have a non-zero round number.
--
-- The genesis block is represented only by the 'GenesisMetadata' and the
-- 'StateHash', which abstract from the genesis data.
data Block (pv :: ProtocolVersion)
    = GenesisBlock !GenesisMetadata
    | NormalBlock !SignedBlock
    deriving (Eq, Show)

instance BlockData (Block pv) where
    type BakedBlockDataType (Block pv) = SignedBlock
    blockRound GenesisBlock{} = 0
    blockRound (NormalBlock b) = blockRound b
    blockEpoch GenesisBlock{} = 0
    blockEpoch (NormalBlock b) = blockEpoch b
    blockTimestamp (GenesisBlock gc) = genesisTime (gmParameters gc)
    blockTimestamp (NormalBlock b) = blockTimestamp b
    blockBakedData GenesisBlock{} = Absent
    blockBakedData (NormalBlock b) = blockBakedData b
    blockTransactions GenesisBlock{} = []
    blockTransactions (NormalBlock b) = blockTransactions b
    blockStateHash (GenesisBlock gc) = gmStateHash gc
    blockStateHash (NormalBlock b) = blockStateHash b

instance HashableTo BlockHash (Block pv) where
    getHash (GenesisBlock gc) = gmCurrentGenesisHash gc
    getHash (NormalBlock b) = getHash b

instance Monad m => MHashableTo m BlockHash (Block pv)

-- |Serialize a 'Block'. This is used for block storage, rather than wire-transmission, as
-- generally genesis blocks should not be transmitted.  For 'NormalBlock's, this is compatible
-- with the serialization of 'SignedBlock'.
putBlock :: Putter (Block pv)
putBlock (GenesisBlock gc) = do
    put (0 :: Round)
    put gc
putBlock (NormalBlock b) = putSignedBlock b

-- |Deserialize a 'Block'. This is used for block storage, rather than wire-transmission, as
-- generally genesis blocks should not be transmitted.  For 'NormalBlock's, this is compatible
-- with the serialization of 'SignedBlock'.
getBlock :: forall pv. (IsProtocolVersion pv) => TransactionTime -> Get (Block pv)
getBlock ts = do
    (r :: Round) <- lookAhead get
    case r of
        0 -> do
            (_ :: Round) <- get
            GenesisBlock <$> get
        _ -> do
            NormalBlock <$> getSignedBlock (protocolVersion @pv) ts

-- |Deserialize a 'Block' where we already know the block hash. This behaves the same as 'getBlock',
-- but avoids having to recompute the block hash.
-- Hence this function does not verify whether the provided hash corresponds the the actual hash
-- of the block.
unsafeGetBlockKnownHash :: forall pv. (IsProtocolVersion pv) => TransactionTime -> BlockHash -> Get (Block pv)
unsafeGetBlockKnownHash ts sbHash = do
    (r :: Round) <- lookAhead get
    case r of
        0 -> do
            (_ :: Round) <- get
            GenesisBlock <$> get
        _ -> do
            sbBlock <- getBakedBlock (protocolVersion @pv) ts
            sbSignature <- get
            return $ NormalBlock SignedBlock{..}
