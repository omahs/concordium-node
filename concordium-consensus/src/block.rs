// https://gitlab.com/Concordium/consensus/globalstate-mockup/blob/master/globalstate/src/Concordium/GlobalState/Block.hs

use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};
use chrono::prelude::Utc;
use failure::Fallible;

use std::io::{Cursor, Read, Write};

use crate::{common::*, parameters::*, transaction::*};

const SLOT: usize = 8;
pub const BLOCK_HASH: usize = SHA256;
const POINTER: usize = BLOCK_HASH;
const BAKER_ID: usize = 8;
const NONCE: usize = BLOCK_HASH + PROOF_LENGTH; // should soon be shorter
const LAST_FINALIZED: usize = BLOCK_HASH;
const PAYLOAD_TYPE: usize = 1;
const UNDEFINED: usize = 8;
const PAYLOAD_SIZE: usize = 2;
const TIMESTAMP: usize = 8;
const SLOT_DURATION: usize = 8;
const BLOCK_BODY: usize = 8;
const SIGNATURE: usize = 64 + 8; // FIXME: unknown 8B prefix
pub const BLOCK_HEIGHT: usize = 8;

macro_rules! get_block_content {
    ($method_name:ident, $content_type:ty, $content_ident:ident, $content_name:expr) => {
        pub fn $method_name(&self) -> $content_type {
            if let BlockData::RegularData(ref data) = self.data {
                data.$content_ident.clone()
            } else {
                panic!("Genesis block has no {}", $content_name)
            }
        }
    }
}

macro_rules! get_block_content_ref {
    ($method_name:ident, $content_type:ty, $content_ident:ident, $content_name:expr) => {
        pub fn $method_name(&self) -> &$content_type {
            if let BlockData::RegularData(ref data) = self.data {
                &data.$content_ident
            } else {
                panic!("Genesis block has no {}", $content_name)
            }
        }
    }
}

#[derive(Debug)]
pub struct Block {
    slot: Slot,
    data: BlockData,
}

impl Block {
    get_block_content!(pointer, BlockHash, pointer, "block pointer");

    get_block_content_ref!(pointer_ref, BlockHash, pointer, "block pointer");

    get_block_content!(baker_id, BakerId, baker_id, "baker");

    get_block_content!(proof, Encoded, proof, "proof");

    get_block_content_ref!(proof_ref, Encoded, proof, "proof");

    get_block_content!(nonce, Encoded, nonce, "nonce");

    get_block_content_ref!(nonce_ref, Encoded, nonce, "nonce");

    get_block_content!(
        last_finalized,
        BlockHash,
        last_finalized,
        "last finalized pointer"
    );

    get_block_content_ref!(
        last_finalized_ref,
        BlockHash,
        last_finalized,
        "last finalized pointer"
    );

    get_block_content_ref!(transactions_ref, Transactions, transactions, "transactions");

    get_block_content!(signature, Encoded, signature, "signature");

    get_block_content_ref!(signature_ref, Encoded, signature, "signature");

    pub fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        debug_deserialization!("Block", bytes);

        let mut cursor = Cursor::new(bytes);

        let slot = NetworkEndian::read_u64(&read_const_sized!(&mut cursor, SLOT));

        let data = match slot {
            0 => BlockData::GenesisData(GenesisData::deserialize(&read_all!(&mut cursor))?),
            _ => BlockData::RegularData(RegularData::deserialize(&read_all!(&mut cursor))?),
        };

        let block = Block { slot, data };

        check_serialization!(block, cursor);

        Ok(block)
    }

    pub fn serialize(&self) -> Vec<u8> {
        debug_serialization!(self);

        let data = match self.data {
            BlockData::GenesisData(ref data) => data.serialize(),
            BlockData::RegularData(ref data) => data.serialize(),
        };

        let mut cursor = create_serialization_cursor(SLOT + data.len());

        let _ = cursor.write_u64::<NetworkEndian>(self.slot);
        let _ = cursor.write_all(&data);

        cursor.into_inner().into_vec()
    }

    pub fn slot_id(&self) -> Slot { self.slot }

    pub fn is_genesis(&self) -> bool { self.slot_id() == 0 }
}

#[derive(Debug)]
pub enum BlockData {
    GenesisData(GenesisData),
    RegularData(RegularData),
}

#[derive(Debug)]
pub struct GenesisData {
    timestamp:               Timestamp,
    slot_duration:           Duration,
    birk_parameters:         BirkParameters,
    finalization_parameters: FinalizationParameters,
}

impl GenesisData {
    pub fn deserialize(_bytes: &[u8]) -> Fallible<Self> {
        unimplemented!() // FIXME
    }

    pub fn serialize(&self) -> Vec<u8> {
        unimplemented!() // FIXME
    }
}

#[derive(Debug)]
pub struct RegularData {
    pointer:        BlockHash,
    baker_id:       BakerId,
    proof:          Encoded,
    nonce:          Encoded,
    last_finalized: BlockHash,
    transactions:   Transactions,
    signature:      Encoded,
}

impl RegularData {
    pub fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        // debug_deserialization!("RegularData", bytes);

        let mut cursor = Cursor::new(bytes);

        let pointer = HashBytes::new(&read_const_sized!(&mut cursor, POINTER));
        let baker_id = NetworkEndian::read_u64(&read_const_sized!(&mut cursor, BAKER_ID));
        let proof = Encoded::new(&read_const_sized!(&mut cursor, PROOF_LENGTH));
        let nonce = Encoded::new(&read_const_sized!(&mut cursor, NONCE));
        let last_finalized = HashBytes::new(&read_const_sized!(&mut cursor, SHA256));
        let payload_size = bytes.len() - cursor.position() as usize - SIGNATURE;
        let transactions = Transactions::deserialize(&read_sized!(&mut cursor, payload_size))?;
        let signature = Encoded::new(&read_const_sized!(&mut cursor, SIGNATURE));

        let data = RegularData {
            pointer,
            baker_id,
            proof,
            nonce,
            last_finalized,
            transactions,
            signature,
        };

        check_serialization!(data, cursor);

        Ok(data)
    }

    pub fn serialize(&self) -> Vec<u8> {
        debug_serialization!(self);

        let transactions = Transactions::serialize(&self.transactions);
        let consts = POINTER + BAKER_ID + PROOF_LENGTH + NONCE + LAST_FINALIZED + SIGNATURE;
        let mut cursor = create_serialization_cursor(consts + transactions.len());

        let _ = cursor.write_all(&self.pointer);
        let _ = cursor.write_u64::<NetworkEndian>(self.baker_id);
        let _ = cursor.write_all(&self.proof);
        let _ = cursor.write_all(&self.nonce);
        let _ = cursor.write_all(&self.last_finalized);
        let _ = cursor.write_all(&transactions);
        let _ = cursor.write_all(&self.signature);

        cursor.into_inner().into_vec()
    }
}

pub type BakerId = u64;

pub type Timestamp = u64;

pub type Duration = u64;

pub type BlockHeight = u64;

pub type BlockHash = HashBytes;

pub struct PendingBlock {
    block:    Block,
    hash:     BlockHash,
    received: Utc,
}

pub struct BlockPointer {
    block:  Block,
    hash:   BlockHash,
    parent: Option<Box<BlockPointer>>,
    height: BlockHeight,
    //    state: BlockState,
    received:          Utc,
    arrived:           Utc,
    transaction_count: u64,
}
