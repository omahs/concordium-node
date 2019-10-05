use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};
use digest::Digest;
use failure::{format_err, Fallible};

use std::{
    convert::TryFrom,
    fmt,
    io::{Cursor, Read, Write},
    ops::Deref,
};

pub use concordium_common::{blockchain_types::*, read_ty, HashBytes, SerializeToBytes, SHA256};
pub use ec_vrf_ed25519 as vrf;
pub use ec_vrf_ed25519::{Proof, Sha256, PROOF_LENGTH};
pub use eddsa_ed25519 as sig;

#[derive(Debug)]
pub struct Account {
    address:           AccountAddress,
    nonce:             Nonce,
    amount:            Amount,
    encrypted_amounts: Box<[ByteString]>,
    encryption_key:    Option<ByteString>,
    verification_key:  ByteString,
    signature_scheme:  SchemeId,
    credentials:       Box<[Encoded]>,
    stake_delegate:    Option<BakerId>,
    instances:         Box<[ContractAddress]>,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for Account {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let address = AccountAddress(read_ty!(cursor, AccountAddress));

        let nonce_raw = NetworkEndian::read_u64(&read_ty!(cursor, Nonce));
        let nonce = Nonce::try_from(nonce_raw)?;

        let amount = NetworkEndian::read_u64(&read_ty!(cursor, Amount));

        let encrypted_amounts = read_multiple!(cursor, read_bytestring(cursor)?, 8, 256);

        let encryption_key = read_maybe!(cursor, read_bytestring(cursor)?);

        let verification_key = read_bytestring_short_length(cursor)?;

        let signature_scheme = SchemeId::try_from(read_ty!(cursor, SchemeId)[0])?;

        let credentials = read_multiple!(cursor, read_bytestring(cursor)?, 8, 256);

        let stake_delegate =
            read_maybe!(cursor, NetworkEndian::read_u64(&read_ty!(cursor, BakerId)));

        let instances = read_multiple!(cursor, ContractAddress::deserialize(cursor)?, 8, 256);

        let account = Account {
            address,
            nonce,
            amount,
            encrypted_amounts,
            encryption_key,
            verification_key,
            signature_scheme,
            credentials,
            stake_delegate,
            instances,
        };

        Ok(account)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_all(&self.address.0)?;
        target.write_u64::<NetworkEndian>(self.nonce.0)?;
        target.write_u64::<NetworkEndian>(self.amount)?;
        write_multiple!(target, self.encrypted_amounts, write_bytestring);
        write_maybe!(target, self.encryption_key, write_bytestring);
        write_bytestring_short_length(target, &self.verification_key)?;
        target.write_u8(self.signature_scheme as u8)?;
        write_multiple!(target, self.credentials, write_bytestring);

        if let Some(baker_id) = self.stake_delegate {
            target.write_u8(1)?;
            target.write_u64::<NetworkEndian>(baker_id)?;
        } else {
            target.write_u8(0)?;
        }

        target.write_u64::<NetworkEndian>(self.instances.len() as u64)?;
        for instance in &*self.instances {
            instance.serial(target)?;
        }

        Ok(())
    }
}

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct Nonce(pub u64);

impl TryFrom<u64> for Nonce {
    type Error = failure::Error;

    fn try_from(raw: u64) -> Fallible<Self> {
        if raw != 0 {
            Ok(Nonce(raw))
        } else {
            Err(format_err!("A zero nonce was received!"))
        }
    }
}

impl fmt::Debug for Nonce {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{}", self.0) }
}

impl fmt::Display for Nonce {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{:?}", self) }
}

pub type Incarnation = u64;

#[derive(Debug, PartialEq, Eq, Hash, Clone)]
pub struct SessionId {
    genesis_block: BlockHash,
    incarnation:   u64,
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{}", self.incarnation) }
}

impl<'a, 'b> SerializeToBytes<'a, 'b> for SessionId {
    type Source = &'a [u8];

    fn deserialize(bytes: Self::Source) -> Fallible<Self> {
        let mut cursor = Cursor::new(bytes);

        let genesis_block = HashBytes::from(read_ty!(&mut cursor, HashBytes));
        let incarnation = NetworkEndian::read_u64(&read_ty!(&mut cursor, Incarnation));

        let sess = SessionId {
            genesis_block,
            incarnation,
        };

        Ok(sess)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_all(&self.genesis_block)?;
        target.write_u64::<NetworkEndian>(self.incarnation)?;

        Ok(())
    }
}

// a type used for objects we only need to store, but not handle
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Encoded(Box<[u8]>);

impl Encoded {
    pub fn new(bytes: &[u8]) -> Self { Encoded(Box::from(bytes)) }
}

impl From<Box<[u8]>> for Encoded {
    fn from(bytes: Box<[u8]>) -> Self { Encoded(bytes) }
}

impl Deref for Encoded {
    type Target = [u8];

    fn deref(&self) -> &Self::Target { &self.0 }
}

impl fmt::Debug for Encoded {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?} ({}B)", sha256(&self.0), self.0.len())
    }
}

// we don't need to handle it in any special way for now, but we might like to
// know that it's prefixed with a u64 length of the rest of it
pub type ByteString = Encoded;

pub fn read_bytestring_short_length(input: &mut Cursor<&[u8]>) -> Fallible<ByteString> {
    let object_length = safe_get_len!(input, 2, 1024);

    Ok(Encoded(read_sized!(input, object_length)))
}

pub fn read_bytestring_medium(input: &mut Cursor<&[u8]>) -> Fallible<ByteString> {
    let object_length = safe_get_len!(input, 4, 4 * 1024);

    Ok(Encoded(read_sized!(input, object_length)))
}

pub fn read_bytestring(input: &mut Cursor<&[u8]>) -> Fallible<ByteString> {
    let object_length = safe_get_len!(input, 8, 64 * 1024);

    Ok(Encoded(read_sized!(input, object_length)))
}

pub fn write_bytestring_short_length<T: Write>(target: &mut T, bytes: &[u8]) -> Fallible<()> {
    target.write_u16::<NetworkEndian>(bytes.len() as u16)?;
    target.write_all(&bytes)?;

    Ok(())
}

pub fn write_bytestring<T: Write>(target: &mut T, bytes: &[u8]) -> Fallible<()> {
    target.write_u64::<NetworkEndian>(bytes.len() as u64)?;
    target.write_all(&bytes)?;

    Ok(())
}

pub fn serialize_list<'a, 'b, T: SerializeToBytes<'a, 'b>>(
    list: &'a [T],
) -> Fallible<Vec<Box<[u8]>>> {
    let mut ret = Vec::new();
    for elem in list {
        let mut e = Vec::new();
        elem.serial(&mut e)?;
        ret.push(e.into_boxed_slice());
    }

    Ok(ret)
}

pub fn list_len<T: AsRef<[u8]>>(list: &[T]) -> usize {
    list.iter().map(|elem| elem.as_ref().len()).sum()
}

pub fn sha256(bytes: &[u8]) -> HashBytes { HashBytes::new(&Sha256::digest(bytes)) }