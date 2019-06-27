// https://gitlab.com/Concordium/consensus/globalstate-mockup/blob/master/globalstate/src/Concordium/GlobalState/Transactions.hs

use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};
use failure::{ensure, format_err, Fallible};

use std::{
    collections::HashMap,
    convert::TryFrom,
    io::{Cursor, Read, Write},
    mem::size_of,
};

use crate::{block::*, common::*};

const PAYLOAD_MAX_LEN: u32 = 512 * 1024 * 1024; // 512MB

pub type TransactionHash = HashBytes;

#[derive(Debug)]
pub struct TransactionHeader {
    scheme_id:      SchemeId,
    sender_key:     ByteString,
    nonce:          Nonce,
    gas_amount:     Energy,
    finalized_ptr:  BlockHash,
    sender_account: AccountAddress,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for TransactionHeader {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let scheme_id = SchemeId::try_from(read_const_sized!(cursor, 1)[0])?;
        let sender_key = read_bytestring(cursor, "sender key's length")?;

        let nonce_raw = NetworkEndian::read_u64(&read_ty!(cursor, Nonce));
        let nonce = Nonce::try_from(nonce_raw)?;

        let gas_amount = NetworkEndian::read_u64(&read_ty!(cursor, Energy));
        let finalized_ptr = HashBytes::from(read_ty!(cursor, HashBytes));
        let sender_account = AccountAddress::from((&*sender_key, scheme_id));

        let transaction_header = TransactionHeader {
            scheme_id,
            sender_key,
            nonce,
            gas_amount,
            finalized_ptr,
            sender_account,
        };

        Ok(transaction_header)
    }

    fn serialize(&self) -> Box<[u8]> {
        let mut cursor = create_serialization_cursor(
            size_of::<SchemeId>()
                + size_of::<u64>()
                + self.sender_key.len()
                + size_of::<Nonce>()
                + size_of::<Energy>()
                + size_of::<BlockHash>(),
        );

        let _ = cursor.write(&[self.scheme_id as u8]);
        let _ = cursor.write_u64::<NetworkEndian>(self.sender_key.len() as u64);
        let _ = cursor.write_all(&self.sender_key);
        let _ = cursor.write_u64::<NetworkEndian>(self.nonce.0.get());
        let _ = cursor.write_u64::<NetworkEndian>(self.gas_amount);
        let _ = cursor.write_all(&self.finalized_ptr);

        cursor.into_inner()
    }
}

#[derive(Debug)]
pub struct Transaction {
    signature: ByteString,
    header:    TransactionHeader,
    payload:   TransactionPayload,
    hash:      TransactionHash,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for Transaction {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let initial_pos = cursor.position() as usize;
        let signature = read_bytestring(cursor, "transaction signature")?;
        let header = TransactionHeader::deserialize(cursor)?;

        let payload_len = NetworkEndian::read_u32(&read_const_sized!(cursor, 4));
        ensure!(
            payload_len <= PAYLOAD_MAX_LEN,
            "The payload size ({}) exceeds the protocol limit ({})!",
            payload_len,
            PAYLOAD_MAX_LEN,
        );
        let payload = TransactionPayload::deserialize((cursor, payload_len))?;

        let hash = sha256(&cursor.get_ref()[initial_pos..cursor.position() as usize]);

        let transaction = Transaction {
            signature,
            header,
            payload,
            hash,
        };

        check_serialization!(transaction, cursor);

        Ok(transaction)
    }

    fn serialize(&self) -> Box<[u8]> {
        let header = self.header.serialize();
        let payload = self.payload.serialize();

        let mut cursor = create_serialization_cursor(
            size_of::<u64>()
                + self.signature.len()
                + header.len()
                + size_of::<u32>()
                + payload.len(),
        );

        let _ = cursor.write_u64::<NetworkEndian>(self.signature.len() as u64);
        let _ = cursor.write_all(&self.signature);
        let _ = cursor.write_all(&header);
        let _ = cursor.write_u32::<NetworkEndian>(payload.len() as u32);
        let _ = cursor.write_all(&payload);

        cursor.into_inner()
    }
}

#[derive(Debug, Clone, Copy)]
pub enum TransactionType {
    DeployModule = 0,
    InitContract,
    Update,
    Transfer,
    DeployCredentials,
    DeployEncryptionKey,
    AddBaker,
    RemoveBaker,
    UpdateBakerAccount,
    UpdateBakerSignKey,
}

impl TryFrom<u8> for TransactionType {
    type Error = failure::Error;

    fn try_from(id: u8) -> Fallible<Self> {
        match id {
            0 => Ok(TransactionType::DeployModule),
            1 => Ok(TransactionType::InitContract),
            2 => Ok(TransactionType::Update),
            3 => Ok(TransactionType::Transfer),
            4 => Ok(TransactionType::DeployCredentials),
            5 => Ok(TransactionType::DeployEncryptionKey),
            6 => Ok(TransactionType::AddBaker),
            7 => Ok(TransactionType::RemoveBaker),
            8 => Ok(TransactionType::UpdateBakerAccount),
            9 => Ok(TransactionType::UpdateBakerSignKey),
            n => Err(format_err!("Unsupported TransactionType ({})!", n)),
        }
    }
}

pub type TyName = u32;

#[derive(Debug)]
pub enum TransactionPayload {
    DeployModule(Encoded),
    InitContract {
        amount:   Amount,
        module:   HashBytes,
        contract: TyName,
        param:    Encoded,
    },
    Update {
        amount:  Amount,
        address: ContractAddress,
        message: Encoded,
    },
    Transfer {
        target_scheme:  SchemeId,
        target_address: AccountAddress,
        amount:         Amount,
    },
    DeployCredentials,
    DeployEncryptionKey,
    AddBaker,
    RemoveBaker,
    UpdateBakerAccount,
    UpdateBakerSignKey,
}

impl TransactionPayload {
    pub fn transaction_type(&self) -> TransactionType {
        use TransactionPayload::*;

        match self {
            DeployModule(_) => TransactionType::DeployModule,
            InitContract { .. } => TransactionType::InitContract,
            Update { .. } => TransactionType::Update,
            Transfer { .. } => TransactionType::Transfer,
            DeployCredentials => TransactionType::DeployCredentials,
            DeployEncryptionKey => TransactionType::DeployEncryptionKey,
            AddBaker => TransactionType::AddBaker,
            RemoveBaker => TransactionType::RemoveBaker,
            UpdateBakerAccount => TransactionType::UpdateBakerAccount,
            UpdateBakerSignKey => TransactionType::UpdateBakerSignKey,
        }
    }
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for TransactionPayload {
    type Source = (&'a mut Cursor<&'b [u8]>, u32);

    fn deserialize((cursor, len): Self::Source) -> Fallible<Self> {
        let variant = TransactionType::try_from(read_ty!(cursor, TransactionType)[0])?;

        match variant {
            TransactionType::DeployModule => {
                let module = Encoded::new(&read_sized!(cursor, len - 1));
                Ok(TransactionPayload::DeployModule(module))
            }
            TransactionType::InitContract => {
                let amount = NetworkEndian::read_u64(&read_ty!(cursor, Amount));
                let module = HashBytes::from(read_ty!(cursor, HashBytes));
                let contract = NetworkEndian::read_u32(&read_ty!(cursor, TyName));

                let non_param_len = sum_ty_lens!(TransactionType, Amount, HashBytes, TyName);
                ensure!(
                    len as usize >= non_param_len,
                    "malformed transaction param!"
                );
                let param_size = len as usize - non_param_len;
                let param = Encoded::new(&read_sized!(cursor, param_size));

                Ok(TransactionPayload::InitContract {
                    amount,
                    module,
                    contract,
                    param,
                })
            }
            TransactionType::Update => {
                let amount = NetworkEndian::read_u64(&read_ty!(cursor, Amount));
                let address = ContractAddress::deserialize(cursor)?;

                let non_message_len = sum_ty_lens!(TransactionType, Amount, ContractAddress);
                ensure!(
                    len as usize >= non_message_len,
                    "malformed transaction message!"
                );
                let msg_size = len as usize - non_message_len;
                let message = Encoded::new(&read_sized!(cursor, msg_size));

                Ok(TransactionPayload::Update {
                    amount,
                    address,
                    message,
                })
            }
            TransactionType::Transfer => {
                let target_scheme = SchemeId::try_from(read_ty!(cursor, SchemeId)[0])?;
                let target_address = AccountAddress(read_ty!(cursor, AccountAddress));
                let amount = NetworkEndian::read_u64(&read_ty!(cursor, Amount));

                Ok(TransactionPayload::Transfer {
                    target_scheme,
                    target_address,
                    amount,
                })
            }
            _ => unimplemented!("Deserialization of {:?} is not implemented yet!", variant),
        }
    }

    fn serialize(&self) -> Box<[u8]> {
        // FIXME: tweak based on the smallest possible size or trigger from within
        // branches
        let mut cursor = Cursor::new(Vec::with_capacity(16));
        let transaction_type = self.transaction_type();
        let _ = cursor.write(&[transaction_type as u8]);

        match self {
            TransactionPayload::DeployModule(module) => {
                let _ = cursor.write_all(&module);
            }
            TransactionPayload::InitContract {
                amount,
                module,
                contract,
                param,
            } => {
                let _ = cursor.write_u64::<NetworkEndian>(*amount);
                let _ = cursor.write_all(&*module);
                let _ = cursor.write_u32::<NetworkEndian>(*contract);
                let _ = cursor.write_all(&*param);
            }
            TransactionPayload::Update {
                amount,
                address,
                message,
            } => {
                let _ = cursor.write_u64::<NetworkEndian>(*amount);
                let _ = cursor.write_all(&address.serialize());
                let _ = cursor.write_all(&*message);
            }
            TransactionPayload::Transfer {
                target_scheme,
                target_address,
                amount,
            } => {
                let _ = cursor.write(&[*target_scheme as u8]);
                let _ = cursor.write_all(&target_address.0);
                let _ = cursor.write_u64::<NetworkEndian>(*amount);
            }
            _ => unimplemented!(
                "Serialization of {:?} is not implemented yet!",
                transaction_type
            ),
        }

        cursor.into_inner().into_boxed_slice()
    }
}

#[derive(Debug)]
pub struct AccountNonFinalizedTransactions {
    map:        Vec<Vec<Transaction>>, // indexed by Nonce
    next_nonce: Nonce,
}

#[derive(Debug, Default)]
pub struct TransactionTable {
    map: HashMap<TransactionHash, (Transaction, Slot)>,
    non_finalized_transactions: HashMap<AccountAddress, AccountNonFinalizedTransactions>,
}

pub type PendingTransactionTable = HashMap<AccountAddress, (Nonce, Nonce)>;
