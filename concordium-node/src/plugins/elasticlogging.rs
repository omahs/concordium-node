use consensus_rust::transferlog::{TransactionLogMessage, TransferLogType};
use elastic::{client::Client, http::sender::SyncSender, prelude::*};
use failure::Fallible;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(ElasticType, Serialize, Deserialize, Debug)]
#[elastic(index = "index_transfer_log")]
struct TransferLogEvent {
    #[elastic(id)]
    pub id: String,
    pub message_type: String,
    pub timestamp: Date<DefaultDateMapping<EpochMillis>>,
    pub block_hash: String,
    pub slot: String,
    pub transaction_hash: Option<String>,
    pub amount: Option<String>,
    pub from_account: Option<String>,
    pub to_account: Option<String>,
    pub from_contract: Option<String>,
    pub to_contract: Option<String>,
    pub baker_id: Option<String>,
    pub json_payload: Option<String>,
}

pub fn log_transfer_event(url: &str, msg: TransactionLogMessage) -> Fallible<()> {
    let client = create_client(url)?;
    let doc = match msg {
        TransactionLogMessage::DirectTransfer(
            block_hash,
            slot,
            transaction_hash,
            amount,
            from_account,
            to_account,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::DirectTransfer.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           Some(amount.to_string()),
            from_account:     Some(from_account.to_string()),
            to_account:       Some(to_account.to_string()),
            from_contract:    None,
            to_contract:      None,
            baker_id:         None,
            json_payload:     None,
        },
        TransactionLogMessage::TransferFromAccountToContract(
            block_hash,
            slot,
            transaction_hash,
            amount,
            account_address,
            contract_address,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::TransferFromAccountToContract.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           Some(amount.to_string()),
            from_account:     Some(account_address.to_string()),
            to_account:       None,
            from_contract:    None,
            to_contract:      Some(contract_address.to_string()),
            baker_id:         None,
            json_payload:     None,
        },
        TransactionLogMessage::TransferFromContractToAccount(
            block_hash,
            slot,
            transaction_hash,
            amount,
            contract_address,
            account_address,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::TransferFromContractToAccount.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           Some(amount.to_string()),
            from_account:     None,
            to_account:       Some(account_address.to_string()),
            from_contract:    Some(contract_address.to_string()),
            to_contract:      None,
            baker_id:         None,
            json_payload:     None,
        },
        TransactionLogMessage::TransferFromContractToContract(
            block_hash,
            slot,
            transaction_hash,
            amount,
            from_contract,
            to_contract,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::TransferFromContractToAccount.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           Some(amount.to_string()),
            from_account:     None,
            to_account:       None,
            from_contract:    Some(from_contract.to_string()),
            to_contract:      Some(to_contract.to_string()),
            baker_id:         None,
            json_payload:     None,
        },
        TransactionLogMessage::ExecutionCost(
            block_hash,
            slot,
            transaction_hash,
            amount,
            from_account,
            baker_id,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::ExecutionCost.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           Some(amount.to_string()),
            from_account:     Some(from_account.to_string()),
            to_account:       None,
            from_contract:    None,
            to_contract:      None,
            baker_id:         Some(baker_id.to_string()),
            json_payload:     None,
        },
        TransactionLogMessage::IdentityCredentialsDeployed(
            block_hash,
            slot,
            transaction_hash,
            from_account,
            to_account,
            json_payload,
        ) => TransferLogEvent {
            id:               Uuid::new_v4().to_string(),
            message_type:     TransferLogType::ExecutionCost.to_string(),
            timestamp:        Date::now(),
            block_hash:       block_hash.to_string(),
            slot:             slot.to_string(),
            transaction_hash: Some(transaction_hash.to_string()),
            amount:           None,
            from_account:     Some(from_account.to_string()),
            to_account:       Some(to_account.to_string()),
            from_contract:    None,
            to_contract:      None,
            baker_id:         None,
            json_payload:     Some(json_payload),
        },
        TransactionLogMessage::BlockReward(block_hash, slot, amount, baker_id, baker_address) => {
            TransferLogEvent {
                id:               Uuid::new_v4().to_string(),
                message_type:     TransferLogType::BlockReward.to_string(),
                timestamp:        Date::now(),
                block_hash:       block_hash.to_string(),
                slot:             slot.to_string(),
                transaction_hash: None,
                amount:           Some(amount.to_string()),
                from_account:     None,
                to_account:       Some(baker_address.to_string()),
                from_contract:    None,
                to_contract:      None,
                baker_id:         Some(baker_id.to_string()),
                json_payload:     None,
            }
        }
    };
    if let Err(e) = client.document::<TransferLogEvent>().put_mapping().send() {
        bail!("Elastic Search could not update mappings in document due to {}", e);
    }
    if let Err(e) = client.document().index(doc).send() {
        bail!("Elastic Search could not insert document into index due to {}", e);
    }
    Ok(())
}

pub fn create_transfer_index(url: &str) -> Fallible<()> {
    let client = create_client(url)?;
    match client.index(TransferLogEvent::static_index()).exists().send() {
        Ok(res) => {
            if !res.exists() {
                if let Err(e) = client.index(TransferLogEvent::static_index()).create().send() {
                    bail!("Elastic Search could not create needed index due to {}", e);
                }
            } else {
                info!("Elastic Search index already exists, reusing");
            }
            Ok(())
        }
        Err(e) => bail!("Elastic Search rejected query {}", e),
    }
}

fn create_client(url: &str) -> Fallible<Client<SyncSender>> {
    match SyncClientBuilder::new().static_node(url).build() {
        Ok(client) => Ok(client),
        Err(e) => bail!("Can't open Elastic Search client due to {}", e),
    }
}
