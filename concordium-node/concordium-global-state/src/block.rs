// https://gitlab.com/Concordium/consensus/globalstate-mockup/blob/master/globalstate/src/Concordium/GlobalState/Block.hs

use byteorder::{ByteOrder, NetworkEndian, ReadBytesExt, WriteBytesExt};
use failure::{bail, Fallible};

use std::{
    cmp::Ordering,
    fmt,
    hash::{Hash, Hasher},
    io::{Cursor, Read, Write},
    mem::size_of,
    ops::Deref,
    sync::Arc,
};

use crate::{common::*, parameters::*, transaction::*};

const NONCE: u8 = PROOF_LENGTH as u8;
const TX_ALLOC_LIMIT: usize = 256 * 1024;

pub struct Block {
    pub slot: Slot,
    pub data: BlockData,
}

impl PartialEq for Block {
    fn eq(&self, other: &Self) -> bool { self.pointer() == other.pointer() }
}

impl Eq for Block {}

impl PartialOrd for Block {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.slot().cmp(&other.slot())) }
}

impl Ord for Block {
    fn cmp(&self, other: &Self) -> Ordering { self.slot().cmp(&other.slot()) }
}

impl Block {
    pub fn genesis_data(&self) -> &Encoded {
        match self.data {
            BlockData::Genesis(ref data) => data,
            BlockData::Regular(_) => unreachable!(), // the genesis block is unmistakeable
        }
    }

    pub fn block_data(&self) -> &BakedBlock {
        match self.data {
            BlockData::Genesis(_) => unreachable!(), // the genesis block is unmistakeable
            BlockData::Regular(ref data) => data,
        }
    }

    pub fn pointer(&self) -> Option<&BlockHash> {
        match &self.data {
            BlockData::Genesis(_) => None,
            BlockData::Regular(ref block) => Some(&block.fields.pointer),
        }
    }

    pub fn last_finalized(&self) -> Option<&BlockHash> {
        match &self.data {
            BlockData::Genesis(_) => None,
            BlockData::Regular(ref block) => Some(&block.fields.last_finalized),
        }
    }

    pub fn slot(&self) -> Slot { self.slot }
}

impl<'a, 'b> SerializeToBytes<'a, 'b> for Block {
    type Source = &'a [u8];

    fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        let mut cursor = Cursor::new(bytes);

        let slot = NetworkEndian::read_u64(&read_ty!(&mut cursor, Slot));
        let data = BlockData::deserialize((&mut cursor, slot))?;

        let block = Block { slot, data };

        Ok(block)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_u64::<NetworkEndian>(self.slot)?;
        self.data.serial(target)?;
        Ok(())
    }
}

impl fmt::Debug for Block {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let mut serialized = Vec::new();
        self.serial(&mut serialized).unwrap_or(());

        let hash = if self.slot != 0 {
            format!(
                "block {:?} by baker {}",
                sha256(&serialized),
                self.block_data().fields.baker_id
            )
        } else {
            format!("genesis {:?}", sha256(&serialized))
        };

        write!(f, "{}", hash)
    }
}

#[derive(Debug)]
pub enum BlockData {
    Genesis(Encoded),
    Regular(BakedBlock),
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for BlockData {
    type Source = (&'a mut Cursor<&'b [u8]>, Slot);

    fn deserialize((cursor, slot): Self::Source) -> Fallible<Self> {
        if slot == 0 {
            let mut buffer = Vec::new();
            let _ = cursor.read_to_end(&mut buffer);
            Ok(BlockData::Genesis(Encoded::new(&buffer.into_boxed_slice())))

        // let timestamp = NetworkEndian::read_u64(&read_ty!(cursor, Timestamp));
        // let slot_duration = NetworkEndian::read_u64(&read_ty!(cursor, Duration));
        // let birk_parameters = BirkParameters::deserialize(cursor)?;
        // let baker_accounts =
        //     read_multiple!(cursor, "baker accounts", Account::deserialize(cursor)?,
        // 8); let finalization_parameters = read_multiple!(
        //     cursor,
        //     "finalization parameters",
        //     VoterInfo::deserialize(&read_const_sized!(cursor, VOTER_INFO))?,
        //     8
        // );
        // let finalization_minimum_skip = NetworkEndian::read_u64(&read_ty!(cursor,
        // BlockHeight)); let cryptographic_parameters =
        // CryptographicParameters::deserialize(cursor)?; let mut buffer =
        // Vec::new(); cursor.read_to_end(&mut buffer)?;
        // let identity_providers = Encoded::new(&buffer);

        // let data = BlockData::Genesis(GenesisData {
        //     timestamp,
        //     slot_duration,
        //     birk_parameters,
        //     baker_accounts,
        //     finalization_parameters,
        //     finalization_minimum_skip,
        //     cryptographic_parameters,
        //     identity_providers,
        // });

        // check_partial_serialization!(data, *cursor.get_ref());

        // Ok(data)
        } else {
            let pointer = HashBytes::from(read_ty!(cursor, BlockHash));
            let baker_id = NetworkEndian::read_u64(&read_ty!(cursor, BakerId));
            let proof = Encoded::new(&read_const_sized!(cursor, PROOF_LENGTH));
            let nonce = Encoded::new(&read_const_sized!(cursor, NONCE));
            let last_finalized = HashBytes::from(read_ty!(cursor, BlockHash));
            let transactions = read_multiple!(
                cursor,
                FullTransaction::deserialize(cursor)?,
                8,
                TX_ALLOC_LIMIT
            );
            let signature = read_bytestring_short_length(cursor)?;
            let txs = serialize_list(&transactions)?;
            let mut transactions = vec![];
            write_multiple!(&mut transactions, txs, Write::write_all);
            let data = BlockData::Regular(BakedBlock {
                fields: Arc::new(BlockFields {
                    pointer,
                    baker_id,
                    proof,
                    nonce,
                    last_finalized,
                }),
                transactions: Encoded::new(&transactions.into_boxed_slice()),
                signature,
            });

            Ok(data)
        }
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        match self {
            BlockData::Genesis(ref data) => {
                target.write_all(data)?;
                // let birk_params = BirkParameters::serialize(&data.birk_parameters);
                // let cryptographic_parameters =
                //     CryptographicParameters::serialize(&data.cryptographic_parameters);
                // let baker_accounts = serialize_list(&data.baker_accounts);
                // let finalization_params = serialize_list(&data.finalization_parameters);

                // let size = size_of::<Timestamp>()
                //     + size_of::<Duration>()
                //     + birk_params.len()
                //     + size_of::<u64>()
                //     + list_len(&baker_accounts)
                //     + size_of::<u64>()
                //     + list_len(&finalization_params)
                //     + size_of::<u64>()
                //     + size_of::<u32>()
                //     + data.cryptographic_parameters.elgamal_generator.len()
                //     + data.cryptographic_parameters.attribute_commitment_key.len()
                //     + data.identity_providers.len();
                // let mut cursor = create_serialization_cursor(size);

                // let _ = cursor.write_u64::<NetworkEndian>(data.timestamp);
                // let _ = cursor.write_u64::<NetworkEndian>(data.slot_duration);
                // let _ = cursor.write_all(&birk_params);
                // write_multiple!(&mut cursor, baker_accounts, Write::write_all);
                // write_multiple!(&mut cursor, finalization_params, Write::write_all);
                // let _ = cursor.write_u64::<NetworkEndian>(data.finalization_minimum_skip);
                // let _ = cursor.write_all(&cryptographic_parameters);
                // let _ = cursor.write_all(&data.identity_providers);
            }
            BlockData::Regular(ref data) => {
                target.write_all(&data.fields.pointer)?;
                target.write_u64::<NetworkEndian>(data.fields.baker_id)?;
                target.write_all(&data.fields.proof)?;
                target.write_all(&data.fields.nonce)?;
                target.write_all(&data.fields.last_finalized)?;
                target.write_all(data.transactions.deref())?;
                write_bytestring_short_length(target, &data.signature)?;
            }
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct BakedBlock {
    pub fields:       Arc<BlockFields>,
    pub transactions: Encoded,
    pub signature:    Encoded,
}

#[derive(Debug)]
pub struct BlockFields {
    pub pointer:        BlockHash,
    pub baker_id:       BakerId,
    pub proof:          Encoded,
    pub nonce:          Encoded,
    pub last_finalized: BlockHash,
}

#[derive(Debug)]
pub struct GenesisData {
    timestamp:                   Timestamp,
    slot_duration:               Duration,
    birk_parameters:             BirkParameters,
    baker_accounts:              Box<[Account]>,
    pub finalization_parameters: Box<[VoterInfo]>,
    finalization_minimum_skip:   BlockHeight,
    cryptographic_parameters:    CryptographicParameters,
    identity_providers:          Encoded,
}

pub type Timestamp = u64;

pub type Duration = u64;

pub type BlockHeight = u64;

pub type Delta = u64;

#[derive(Debug)]
pub struct PendingBlock {
    pub hash:  BlockHash,
    pub block: Arc<Block>,
}

fn hash_without_timestamps(block: &Block) -> Fallible<BlockHash> {
    let mut target = Vec::new();

    target.write_u64::<NetworkEndian>(block.slot)?;

    match block.data {
        BlockData::Regular(ref data) => {
            fn transform_txs(source: &[u8]) -> Fallible<Vec<Box<[u8]>>> {
                let mut cursor_txs = Cursor::new(source);
                let txs = read_multiple!(
                    &mut cursor_txs,
                    FullTransaction::deserialize(&mut cursor_txs)?,
                    8,
                    TX_ALLOC_LIMIT
                );

                let mut ret = Vec::new();
                for tx in txs.iter() {
                    let mut bare_tx = Vec::new();
                    tx.bare_transaction.serial(&mut bare_tx)?;
                    ret.push(bare_tx.into_boxed_slice());
                }

                Ok(ret)
            }

            let transactions = transform_txs(data.transactions.deref())?;

            target.write_all(&data.fields.pointer)?;
            target.write_u64::<NetworkEndian>(data.fields.baker_id)?;
            target.write_all(&data.fields.proof)?;
            target.write_all(&data.fields.nonce)?;
            target.write_all(&data.fields.last_finalized)?;
            write_multiple!(&mut target, transactions, Write::write_all);
            write_bytestring_short_length(&mut target, &data.signature)?;
        }
        _ => unreachable!("GenesisData will never be transformed into a Pending Block"),
    };

    Ok(sha256(&target))
}

impl PendingBlock {
    pub fn new(bytes: &[u8]) -> Fallible<Self> {
        let block = Block::deserialize(bytes)?;
        Ok(Self {
            hash:  hash_without_timestamps(&block)?,
            block: Arc::new(block),
        })
    }
}

impl PartialEq for PendingBlock {
    fn eq(&self, other: &Self) -> bool { self.hash == other.hash }
}

impl Eq for PendingBlock {}

impl Hash for PendingBlock {
    fn hash<H: Hasher>(&self, state: &mut H) { self.hash.hash(state) }
}

pub struct BlockPtr {
    pub hash:                    BlockHash,
    pub block:                   Arc<Block>,
    pub height:                  BlockHeight,
    pub transaction_count:       u64,
    pub transaction_energy_cost: u64,
    pub transaction_size:        u64,
}

impl BlockPtr {
    pub fn genesis(genesis_bytes: &[u8]) -> Fallible<Self> {
        let mut cursor = Cursor::new(genesis_bytes);
        let genesis_data = BlockData::deserialize((&mut cursor, 0)).expect("Invalid genesis data");
        let genesis_block = Block {
            slot: 0,
            data: genesis_data,
        };

        let mut genesis_block_hash = Vec::new();
        genesis_block.serial(&mut genesis_block_hash)?;
        let genesis_block_hash = sha256(&genesis_block_hash);

        Ok(Self {
            hash:                    genesis_block_hash,
            block:                   Arc::new(genesis_block),
            height:                  0,
            transaction_count:       0,
            transaction_energy_cost: 0,
            transaction_size:        0,
        })
    }

    pub fn new(pb: &PendingBlock, height: BlockHeight) -> Fallible<Self> {
        fn get_tx_count_energy(mut cursor: Cursor<&[u8]>) -> Fallible<(u64, u64)> {
            let txs = read_multiple!(
                cursor,
                FullTransaction::deserialize(&mut cursor)?,
                8,
                TX_ALLOC_LIMIT
            );

            Ok((
                txs.len() as u64,
                txs.iter()
                    .map(|x| x.bare_transaction.header.gas_amount)
                    .sum(),
            ))
        }

        if let BlockData::Regular(ref bblock) = pb.block.data {
            let cursor = Cursor::new(bblock.transactions.deref());
            if let Ok((tx_count, energy)) = get_tx_count_energy(cursor) {
                Ok(Self {
                    hash: pb.hash.clone(),
                    block: pb.block.clone(),
                    height,
                    transaction_count: tx_count,
                    transaction_energy_cost: energy,
                    transaction_size: bblock.transactions.deref().len() as u64
                        - (size_of::<u64>() as u64 * tx_count as u64),
                })
            } else {
                bail!(
                    "Couldn't read txs of a pending block {:?} when creating a block pointer",
                    pb
                )
            }
        } else {
            bail!("Tried to create block pointer from a pending block containing genesis data")
        }
    }

    pub fn serialize_to_disk_format(&self) -> Fallible<Vec<u8>> {
        let mut buffer = Vec::new();

        self.block.serial(&mut buffer)?;
        buffer.write_u64::<NetworkEndian>(self.height)?;

        Ok(buffer)
    }
}

impl PartialEq for BlockPtr {
    fn eq(&self, other: &Self) -> bool { self.hash == other.hash }
}

impl Eq for BlockPtr {}

impl PartialOrd for BlockPtr {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.height.cmp(&other.height)) }
}

impl Ord for BlockPtr {
    fn cmp(&self, other: &Self) -> Ordering { self.height.cmp(&other.height) }
}

impl fmt::Debug for BlockPtr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{:?}", self.hash) }
}

impl Serial for BlockPtr {
    fn deserial<R: ReadBytesExt>(_source: &mut R) -> Fallible<Self> {
        unimplemented!("BlockPtr is not to be deserialized directly")
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> { self.block.serial(target) }
}
