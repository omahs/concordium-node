// https://gitlab.com/Concordium/consensus/globalstate-mockup/blob/master/globalstate/src/Concordium/GlobalState/Parameters.hs

use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};

use failure::Fallible;

use std::{
    collections::HashMap,
    io::{Cursor, Read},
    mem::size_of,
};

use concordium_common::blockchain_types::BakerId;

use crate::common::*;

pub type BakerSignVerifyKey = ByteString;
pub type BakerSignPrivateKey = Encoded;
pub type BakerElectionVerifyKey = Encoded;
pub type BakerElectionPrivateKey = Encoded;
pub type LotteryPower = f64;
pub type ElectionDifficulty = f64;

pub type VoterId = u64;
pub type VoterVerificationKey = ByteString;
pub type VoterVRFPublicKey = Encoded;
pub type VoterSignKey = Encoded;
pub type VoterPower = u64;

pub const BAKER_VRF_KEY: u8 = 32;
const BAKER_SIGN_KEY: u8 = 2 + 32;
const BAKER_INFO: u8 = BAKER_VRF_KEY
    + BAKER_SIGN_KEY
    + size_of::<LotteryPower>() as u8
    + size_of::<AccountAddress>() as u8;

const VOTER_SIGN_KEY: u8 = 2 + 32;
const VOTER_VRF_KEY: u8 = 32;
pub const VOTER_INFO: u8 = VOTER_SIGN_KEY + VOTER_VRF_KEY + size_of::<VoterPower>() as u8;
const ELGAMAL_GENERATOR: u8 = 48;
const MAX_BAKER_ALLOC: usize = 512;

#[derive(Debug)]
pub struct Bakers {
    baker_map:         HashMap<BakerId, BakerInfo>,
    bakers_by_key:     HashMap<(BakerSignVerifyKey, BakerElectionVerifyKey), Box<[BakerId]>>,
    baker_total_stake: Amount,
    next_baker_id:     BakerId,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for Bakers {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let baker_map = read_hashmap!(
            cursor,
            (
                NetworkEndian::read_u64(&read_ty!(cursor, BakerId)),
                BakerInfo::deserialize(&read_const_sized!(cursor, BAKER_INFO))?
            ),
            8,
            MAX_BAKER_ALLOC
        );
        let bakers_by_key = read_hashmap!(
            cursor,
            (
                (
                    read_bytestring_short_length(cursor)?,
                    Encoded::new(&read_const_sized!(cursor, BAKER_VRF_KEY))
                ),
                read_multiple!(
                    cursor,
                    NetworkEndian::read_u64(&read_ty!(cursor, BakerId)),
                    8,
                    MAX_BAKER_ALLOC
                )
            ),
            8,
            MAX_BAKER_ALLOC
        );

        let baker_total_stake = NetworkEndian::read_u64(&read_ty!(cursor, Amount));
        let next_baker_id = NetworkEndian::read_u64(&read_ty!(cursor, BakerId));

        let params = Bakers {
            baker_map,
            bakers_by_key,
            baker_total_stake,
            next_baker_id,
        };

        Ok(params)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_u64::<NetworkEndian>(self.baker_map.len() as u64)?;
        for (id, info) in self.baker_map.iter() {
            target.write_u64::<NetworkEndian>(*id)?;
            info.serial(target)?;
        }

        target.write_u64::<NetworkEndian>(self.bakers_by_key.len() as u64)?;
        for ((bsk, bvk), bakerids) in self.bakers_by_key.iter() {
            write_bytestring_short_length(target, bsk)?;
            target.write_all(bvk)?;
            target.write_u64::<NetworkEndian>(bakerids.len() as u64)?;
            for id in bakerids.iter() {
                target.write_u64::<NetworkEndian>(*id)?;
            }
        }

        target.write_u64::<NetworkEndian>(self.baker_total_stake)?;
        target.write_u64::<NetworkEndian>(self.next_baker_id)?;

        Ok(())
    }
}

#[derive(Debug)]
pub struct BirkParameters {
    election_nonce:      ByteString,
    election_difficulty: ElectionDifficulty,
    pub bakers:          Bakers,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for BirkParameters {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let election_nonce = read_bytestring(cursor)?;
        let election_difficulty = NetworkEndian::read_f64(&read_ty!(cursor, ElectionDifficulty));
        let bakers = Bakers::deserialize(cursor)?;

        let params = BirkParameters {
            election_nonce,
            election_difficulty,
            bakers,
        };

        Ok(params)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        write_bytestring(target, &self.election_nonce)?;
        target.write_f64::<NetworkEndian>(self.election_difficulty)?;
        self.bakers.serial(target)?;

        Ok(())
    }
}

#[derive(Debug)]
pub struct CryptographicParameters {
    pub elgamal_generator:        ByteString,
    pub attribute_commitment_key: ByteString,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for CryptographicParameters {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(mut cursor: Self::Source) -> Fallible<Self> {
        let elgamal_generator = Encoded::new(&read_const_sized!(&mut cursor, ELGAMAL_GENERATOR));
        let attribute_commitment_key = read_bytestring_medium(&mut cursor)?;

        let crypto_params = CryptographicParameters {
            elgamal_generator,
            attribute_commitment_key,
        };

        Ok(crypto_params)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_all(&self.elgamal_generator)?;
        target.write_u32::<NetworkEndian>(self.attribute_commitment_key.len() as u32)?;
        target.write_all(&self.attribute_commitment_key)?;

        Ok(())
    }
}

#[derive(Debug)]
pub struct BakerInfo {
    election_verify_key:  BakerElectionVerifyKey,
    signature_verify_key: BakerSignVerifyKey,
    lottery_power:        LotteryPower,
    account_address:      AccountAddress,
}

impl<'a, 'b> SerializeToBytes<'a, 'b> for BakerInfo {
    type Source = &'a [u8];

    fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        let mut cursor = Cursor::new(bytes);

        let election_verify_key = Encoded::new(&read_const_sized!(&mut cursor, BAKER_VRF_KEY));
        let signature_verify_key = read_bytestring_short_length(&mut cursor)?;
        let lottery_power = NetworkEndian::read_f64(&read_ty!(cursor, LotteryPower));
        let account_address = AccountAddress(read_ty!(cursor, AccountAddress));

        let info = BakerInfo {
            election_verify_key,
            signature_verify_key,
            lottery_power,
            account_address,
        };

        Ok(info)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_all(&self.election_verify_key)?;
        write_bytestring_short_length(target, &self.signature_verify_key)?;
        target.write_f64::<NetworkEndian>(self.lottery_power)?;
        target.write_all(&self.account_address.0)?;

        Ok(())
    }
}

#[derive(Debug)]
pub struct VoterInfo {
    pub signature_verify_key: VoterVerificationKey,
    election_verify_key:      VoterVRFPublicKey,
    voting_power:             VoterPower,
}

impl<'a, 'b> SerializeToBytes<'a, 'b> for VoterInfo {
    type Source = &'a [u8];

    fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        let mut cursor = Cursor::new(bytes);

        let signature_verify_key = read_bytestring_short_length(&mut cursor)?;
        let election_verify_key = Encoded::new(&read_const_sized!(&mut cursor, VOTER_VRF_KEY));
        let voting_power = NetworkEndian::read_u64(&read_ty!(cursor, VoterPower));

        let info = VoterInfo {
            signature_verify_key,
            election_verify_key,
            voting_power,
        };

        Ok(info)
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        write_bytestring_short_length(target, &self.signature_verify_key)?;
        target.write_all(&self.election_verify_key)?;
        target.write_u64::<NetworkEndian>(self.voting_power)?;

        Ok(())
    }
}