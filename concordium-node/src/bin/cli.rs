#![recursion_limit = "1024"]
#[cfg(not(target_os = "windows"))]
extern crate grpciounix as grpcio;
#[cfg(target_os = "windows")]
extern crate grpciowin as grpcio;
#[macro_use]
extern crate log;
#[macro_use]
extern crate failure;

// Explicitly defining allocator to avoid future reintroduction of jemalloc
use std::alloc::System;
#[global_allocator]
static A: System = System;

use byteorder::{ByteOrder, NetworkEndian, ReadBytesExt, WriteBytesExt};
use concordium_common::{
    functor::{FilterFunctor, Functorable},
    make_atomic_callback, safe_write, spawn_or_die, write_or_die, UCursor,
};
use concordium_consensus::{
    block::Block,
    consensus,
    finalization::{FinalizationMessage, FinalizationRecord},
};
use env_logger::{Builder, Env};
use failure::Fallible;
use p2p_client::{
    client::utils as client_utils,
    common::{P2PNodeId, PeerType},
    configuration,
    connection::network_handler::message_handler::MessageManager,
    db::P2PDB,
    network::{
        NetworkId, NetworkMessage, NetworkPacket, NetworkPacketType, NetworkRequest,
        NetworkResponse,
    },
    p2p::*,
    rpc::RpcServerImpl,
    stats_engine::StatsEngine,
    stats_export_service::{StatsExportService, StatsServiceMode},
    utils,
};

use std::{
    collections::HashMap,
    fs::OpenOptions,
    io::{Read, Write},
    net::SocketAddr,
    str::{self, FromStr},
    sync::{mpsc, Arc, RwLock},
    thread,
    time::Duration,
};

const PAYLOAD_TYPE_LENGTH: u64 = 2;

fn get_config_and_logging_setup() -> (configuration::Config, configuration::AppPreferences) {
    // Get config and app preferences
    let conf = configuration::parse_config();
    let app_prefs = configuration::AppPreferences::new(
        conf.common.config_dir.to_owned(),
        conf.common.data_dir.to_owned(),
    );

    // Prepare the logger
    let env = if conf.common.trace {
        Env::default().filter_or("MY_LOG_LEVEL", "trace")
    } else if conf.common.debug {
        Env::default().filter_or("MY_LOG_LEVEL", "debug")
    } else {
        Env::default().filter_or("MY_LOG_LEVEL", "info")
    };

    let mut log_builder = Builder::from_env(env);
    if conf.common.no_log_timestamp {
        log_builder.default_format_timestamp(false);
    }
    log_builder.init();

    p2p_client::setup_panics();

    info!(
        "Starting up {} version {}!",
        p2p_client::APPNAME,
        p2p_client::VERSION
    );
    info!(
        "Application data directory: {:?}",
        app_prefs.get_user_app_dir()
    );
    info!(
        "Application config directory: {:?}",
        app_prefs.get_user_config_dir()
    );

    (conf, app_prefs)
}

fn setup_baker_guards(
    baker: &mut Option<consensus::ConsensusContainer>,
    node: &P2PNode,
    conf: &configuration::Config,
) {
    if let Some(ref mut baker) = baker {
        let mut _baker_clone = baker.to_owned();
        let mut _node_ref = node.clone();
        let _network_id = NetworkId::from(conf.common.network_ids[0].to_owned()); // defaulted so there's always first()
        spawn_or_die!("Process baker blocks output", move || loop {
            match _baker_clone.out_queue().recv_block() {
                Ok(block) => {
                    let bytes = block.serialize();
                    let mut out_bytes = Vec::with_capacity(2 + bytes.len());
                    match out_bytes
                        .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_BLOCK)
                    {
                        Ok(_) => {
                            out_bytes.extend(&*bytes);
                            match &_node_ref.send_message(None, _network_id, None, out_bytes, true)
                            {
                                Ok(_) => info!(
                                    "Broadcasted block {}/{}",
                                    block.slot_id(),
                                    block.baker_id()
                                ),
                                Err(_) => error!("Couldn't broadcast block!"),
                            }
                        }
                        Err(_) => error!("Can't write type to packet"),
                    }
                }
                _ => error!("Error receiving block from baker"),
            }
        });
        let _baker_clone_2 = baker.to_owned();
        let mut _node_ref_2 = node.clone();
        spawn_or_die!("Process baker finalization output", move || loop {
            match _baker_clone_2.out_queue().recv_finalization() {
                Ok(msg) => {
                    let bytes = msg.serialize();
                    let mut out_bytes = Vec::with_capacity(2 + bytes.len());
                    match out_bytes
                        .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_FINALIZATION)
                    {
                        Ok(_) => {
                            out_bytes.extend(&*bytes);
                            match &_node_ref_2.send_message(
                                None,
                                _network_id,
                                None,
                                out_bytes,
                                true,
                            ) {
                                Ok(_) => info!("Broadcasted finalization packet"),
                                Err(_) => error!("Couldn't broadcast finalization packet!"),
                            }
                        }
                        Err(_) => error!("Can't write type to packet"),
                    }
                }
                _ => error!("Error receiving finalization packet from baker"),
            }
        });
        let _baker_clone_3 = baker.to_owned();
        let mut _node_ref_3 = node.clone();
        spawn_or_die!("Process baker finalization records output", move || loop {
            match _baker_clone_3.out_queue().recv_finalization_record() {
                Ok(rec) => {
                    let bytes = rec.serialize();
                    let mut out_bytes = Vec::with_capacity(2 + bytes.len());
                    match out_bytes.write_u16::<NetworkEndian>(
                        consensus::PACKET_TYPE_CONSENSUS_FINALIZATION_RECORD,
                    ) {
                        Ok(_) => {
                            out_bytes.extend(&*bytes);
                            match &_node_ref_3.send_message(
                                None,
                                _network_id,
                                None,
                                out_bytes,
                                true,
                            ) {
                                Ok(_) => info!("Broadcasted finalization record"),
                                Err(_) => error!("Couldn't broadcast finalization record!"),
                            }
                        }
                        Err(_) => error!("Can't write type to packet"),
                    }
                }
                _ => error!("Error receiving finalization record from baker"),
            }
        });
        let _baker_clone_4 = baker.to_owned();
        let mut _node_ref_4 = node.clone();
        spawn_or_die!("Process baker catch-up requests", move || loop {
            match _baker_clone_4.out_queue().recv_catchup() {
                Ok(msg) => {
                    let (receiver_id, serialized_bytes) = match msg {
                        consensus::CatchupRequest::BlockByHash(receiver_id, bytes) => {
                            let mut inner_out_bytes = Vec::with_capacity(2 + bytes.len());
                            inner_out_bytes
                                .write_u16::<NetworkEndian>(
                                    consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_BLOCK_BY_HASH,
                                )
                                .expect("Can't write to buffer");
                            inner_out_bytes.extend(bytes);
                            (P2PNodeId(receiver_id), inner_out_bytes)
                        }
                        consensus::CatchupRequest::FinalizationRecordByHash(receiver_id, bytes) => {
                            let mut inner_out_bytes = Vec::with_capacity(2 + bytes.len());
                            inner_out_bytes.write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_RECORD_BY_HASH).expect("Can't write to buffer");
                            inner_out_bytes.extend(bytes);
                            (P2PNodeId(receiver_id), inner_out_bytes)
                        }
                        consensus::CatchupRequest::FinalizationRecordByIndex(
                            receiver_id,
                            index,
                        ) => {
                            let mut inner_out_bytes = Vec::with_capacity(10);
                            inner_out_bytes.write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_RECORD_BY_INDEX).expect("Can't write to buffer");
                            inner_out_bytes
                                .write_u64::<NetworkEndian>(index)
                                .expect("Can't write to buffer");
                            (P2PNodeId(receiver_id), inner_out_bytes)
                        }
                    };
                    match &_node_ref_4.send_message(
                        Some(receiver_id),
                        _network_id,
                        None,
                        serialized_bytes,
                        false,
                    ) {
                        Ok(_) => info!(
                            "Sent the consensus catch-up request to the peer {}",
                            receiver_id
                        ),
                        Err(_) => error!(
                            "Couldn't send the consensus catch-up request to the peer {}",
                            receiver_id
                        ),
                    }
                }
                Err(_) => error!("Can't read from queue"),
            }
        });
        let _baker_clone_5 = baker.to_owned();
        let mut _node_ref_5 = node.clone();
        spawn_or_die!(
            "Process outbound baker catch-up finalization messages",
            move || loop {
                match _baker_clone_5.out_queue().recv_finalization_catchup() {
                    Ok((receiver_id_raw, msg)) => {
                        let receiver_id = P2PNodeId(receiver_id_raw);
                        let bytes = &*msg.serialize();
                        let mut out_bytes = Vec::with_capacity(2 + bytes.len());
                        out_bytes
                            .write_u16::<NetworkEndian>(
                                consensus::PACKET_TYPE_CONSENSUS_FINALIZATION,
                            )
                            .expect("Can't write to buffer");
                        out_bytes.extend(bytes);
                        match &_node_ref_5.send_message(
                            Some(receiver_id),
                            _network_id,
                            None,
                            out_bytes,
                            false,
                        ) {
                            Ok(_) => info!(
                                "Sent the consensus catch-up request to the peer {}",
                                receiver_id
                            ),
                            Err(_) => error!(
                                "Couldn't send the consensus catch-up request to the peer {}",
                                receiver_id
                            ),
                        }
                    }
                    Err(_) => error!("Can't read from queue"),
                }
            }
        );
    }
}

fn instantiate_node(
    conf: &configuration::Config,
    app_prefs: &mut configuration::AppPreferences,
    stats_export_service: &Option<Arc<RwLock<StatsExportService>>>,
) -> (P2PNode, mpsc::Receiver<Arc<NetworkMessage>>) {
    let (pkt_in, pkt_out) = mpsc::channel::<Arc<NetworkMessage>>();
    let node_id = conf.common.id.clone().map_or(
        app_prefs.get_config(configuration::APP_PREFERENCES_PERSISTED_NODE_ID),
        |id| {
            if !app_prefs.set_config(
                configuration::APP_PREFERENCES_PERSISTED_NODE_ID,
                Some(id.clone()),
            ) {
                error!("Failed to persist own node id");
            };
            Some(id)
        },
    );
    let arc_stats_export_service = if let Some(ref service) = stats_export_service {
        Some(Arc::clone(service))
    } else {
        None
    };

    let broadcasting_checks = Arc::new(FilterFunctor::new("Broadcasting_checks"));

    // Thread #1: Read P2PEvents from P2PNode
    let node = if conf.common.debug {
        let (sender, receiver) = mpsc::channel();
        let _guard = spawn_or_die!("Log loop", move || loop {
            if let Ok(msg) = receiver.recv() {
                info!("{}", msg);
            }
        });
        P2PNode::new(
            node_id,
            &conf,
            pkt_in,
            Some(sender),
            PeerType::Node,
            arc_stats_export_service,
            Arc::clone(&broadcasting_checks),
        )
    } else {
        P2PNode::new(
            node_id,
            &conf,
            pkt_in,
            None,
            PeerType::Node,
            arc_stats_export_service,
            Arc::clone(&broadcasting_checks),
        )
    };
    (node, pkt_out)
}

fn start_tps_test(conf: &configuration::Config, node: &P2PNode) {
    if let Some(ref tps_test_recv_id) = conf.cli.tps.tps_test_recv_id {
        let mut _id_clone = tps_test_recv_id.to_owned();
        let mut _dir_clone = conf.cli.tps.tps_test_data_dir.to_owned();
        let mut _node_ref = node.clone();
        let _network_id = NetworkId::from(conf.common.network_ids[0].to_owned());
        spawn_or_die!("TPS processing", move || {
            let mut done = false;
            while !done {
                // Test if we have any peers yet. Otherwise keep trying until we do
                let node_list = _node_ref.get_peer_stats(&[_network_id]);
                if !node_list.is_empty() {
                    let test_messages = utils::get_tps_test_messages(_dir_clone.clone());
                    for message in test_messages {
                        let out_bytes_len = message.len();
                        let to_send = P2PNodeId::from_str(&_id_clone).ok();
                        match _node_ref.send_message(to_send, _network_id, None, message, false) {
                            Ok(_) => {
                                info!("Sent TPS test bytes of len {}", out_bytes_len);
                            }
                            Err(_) => error!("Couldn't send TPS test message!"),
                        }
                    }
                    done = true;
                }
            }
            thread::park();
        });
    }
}

fn setup_process_output(
    node: &P2PNode,
    db: &P2PDB,
    conf: &configuration::Config,
    rpc_serv: &Option<RpcServerImpl>,
    baker: &mut Option<consensus::ConsensusContainer>,
    pkt_out: mpsc::Receiver<Arc<NetworkMessage>>,
) {
    let mut _node_self_clone = node.clone();
    let mut _db = db.clone();

    let _no_trust_bans = conf.common.no_trust_bans;
    let _no_trust_broadcasts = conf.connection.no_trust_broadcasts;
    let mut _rpc_clone = rpc_serv.clone();
    let _desired_nodes_clone = conf.connection.desired_nodes;
    let _test_runner_url = conf.cli.test_runner_url.clone();
    let mut _baker_pkt_clone = baker.clone();
    let _tps_test_enabled = conf.cli.tps.enable_tps_test;
    let mut _stats_engine = StatsEngine::new(conf.cli.tps.tps_stats_save_amount);
    let mut _msg_count = 0;
    let _tps_message_count = conf.cli.tps.tps_message_count;
    let _network_id = NetworkId::from(conf.common.network_ids[0].to_owned()); // defaulted so there's always first()
    let _guard_pkt = spawn_or_die!("Higher queue processing", move || {
        fn send_msg_to_baker(
            node: &mut P2PNode,
            baker_ins: &mut Option<consensus::ConsensusContainer>,
            peer_id: P2PNodeId,
            network_id: NetworkId,
            mut msg: UCursor,
        ) -> Fallible<()> {
            if let Some(ref mut baker) = baker_ins {
                ensure!(
                    msg.len() >= msg.position() + PAYLOAD_TYPE_LENGTH,
                    "Message needs at least {} bytes",
                    PAYLOAD_TYPE_LENGTH
                );

                let consensus_type = msg.read_u16::<NetworkEndian>()?;
                let view = msg.read_all_into_view()?;
                let content = &view.as_slice()[PAYLOAD_TYPE_LENGTH as usize..];

                match consensus_type {
                    consensus::PACKET_TYPE_CONSENSUS_BLOCK => send_block_to_baker(baker, peer_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_TRANSACTION => send_transaction_to_baker(baker, peer_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_FINALIZATION => send_finalization_message_to_baker(baker, peer_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_FINALIZATION_RECORD => send_finalization_record_to_baker(baker, peer_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_BLOCK_BY_HASH => send_catchup_request_block_by_bash_baker(baker, node, peer_id, network_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_RECORD_BY_HASH => send_catchup_request_finalization_record_by_bash_baker(baker, node, peer_id, network_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_RECORD_BY_INDEX => send_catchup_request_finalization_record_by_index_to_baker(baker, node, peer_id, network_id, &content[..]),
                    consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_BY_POINT => send_catchup_finalization_messages_by_point_to_baker(baker, peer_id, &content[..]),
                    _ => {
                        error!("Couldn't read bytes properly for type");
                        Ok(())
                    }
                }
            } else {
                Ok(())
            }
        }

        loop {
            if let Ok(full_msg) = pkt_out.recv() {
                match *full_msg {
                    NetworkMessage::NetworkRequest(
                        NetworkRequest::BanNode(ref peer, peer_to_ban),
                        ..
                    ) => {
                        utils::ban_node(
                            &mut _node_self_clone,
                            peer,
                            peer_to_ban,
                            &_db,
                            _no_trust_bans,
                        );
                    }
                    NetworkMessage::NetworkRequest(
                        NetworkRequest::UnbanNode(ref peer, peer_to_ban),
                        ..
                    ) => {
                        utils::unban_node(
                            &mut _node_self_clone,
                            peer,
                            peer_to_ban,
                            &_db,
                            _no_trust_bans,
                        );
                    }
                    NetworkMessage::NetworkResponse(
                        NetworkResponse::PeerList(ref peer, ref peers),
                        ..
                    ) => {
                        debug!("Received PeerList response, attempting to satisfy desired peers");
                        let mut new_peers = 0;
                        let peer_count = _node_self_clone
                            .get_peer_stats(&[])
                            .iter()
                            .filter(|x| x.peer_type == PeerType::Node)
                            .count();
                        for peer_node in peers {
                            info!(
                                "Peer {}/{}/{} sent us peer info for {}/{}/{}",
                                peer.id(),
                                peer.ip(),
                                peer.port(),
                                peer_node.id(),
                                peer_node.ip(),
                                peer_node.port()
                            );
                            if _node_self_clone
                                .connect(PeerType::Node, peer_node.addr, Some(peer_node.id()))
                                .map_err(|e| error!("{}", e))
                                .is_ok()
                            {
                                new_peers += 1;
                            }
                            if new_peers + peer_count as u8 >= _desired_nodes_clone {
                                break;
                            }
                        }
                    }
                    NetworkMessage::NetworkPacket(ref pac, ..) => {
                        match pac.packet_type {
                            NetworkPacketType::DirectMessage(..) => {
                                if _tps_test_enabled {
                                    _stats_engine.add_stat(pac.message.len() as u64);
                                    _msg_count += 1;

                                    if _msg_count == _tps_message_count {
                                        info!(
                                            "TPS over {} messages is {}",
                                            _tps_message_count,
                                            _stats_engine.calculate_total_tps_average()
                                        );
                                        _msg_count = 0;
                                        _stats_engine.clear();
                                    }
                                }
                                if let Some(ref mut rpc) = _rpc_clone {
                                    rpc.queue_message(&full_msg)
                                        .unwrap_or_else(|e| error!("Couldn't queue message {}", e));
                                }
                                info!(
                                    "DirectMessage/{}/{} with size {} received",
                                    pac.network_id,
                                    pac.message_id,
                                    pac.message.len()
                                );
                            }
                            NetworkPacketType::BroadcastedMessage => {
                                if let Some(ref mut rpc) = _rpc_clone {
                                    rpc.queue_message(&full_msg)
                                        .unwrap_or_else(|e| error!("Couldn't queue message {}", e));
                                }
                                if let Some(ref testrunner_url) = _test_runner_url {
                                    send_packet_to_testrunner(
                                        &_node_self_clone,
                                        testrunner_url,
                                        pac,
                                    );
                                };
                            }
                        };
                        if let Err(e) = send_msg_to_baker(
                            &mut _node_self_clone,
                            &mut _baker_pkt_clone,
                            pac.peer.id(),
                            _network_id,
                            pac.message.clone(),
                        ) {
                            error!("Send network message to baker has failed: {:?}", e);
                        }
                    }
                    NetworkMessage::NetworkRequest(NetworkRequest::Retransmit(..), ..) => {
                        panic!("Not implemented yet");
                    }
                    _ => {}
                }
            }
        }
    });

    info!(
        "Concordium P2P layer. Network disabled: {}",
        conf.cli.no_network
    );
}

fn send_transaction_to_baker(
    baker: &mut consensus::ConsensusContainer,
    peer_id: P2PNodeId,
    content: &[u8],
) -> Fallible<()> {
    baker.send_transaction(content);
    info!(
        "Sent a transaction from the network peer {} to the consensus layer",
        peer_id
    );
    Ok(())
}

fn send_finalization_record_to_baker(
    baker: &mut consensus::ConsensusContainer,
    peer_id: P2PNodeId,
    content: &[u8],
) -> Fallible<()> {
    match baker
        .send_finalization_record(peer_id.as_raw(), &FinalizationRecord::deserialize(content)?)
    {
        0i64 => info!(
            "Sent finalization record from the network peer {} to baker",
            peer_id
        ),
        err_code => error!(
            "Can't send finalization record from the network peer {} to baker due to error code \
             #{}",
            peer_id, err_code
        ),
    }
    Ok(())
}

fn send_finalization_message_to_baker(
    baker: &mut consensus::ConsensusContainer,
    peer_id: P2PNodeId,
    content: &[u8],
) -> Fallible<()> {
    baker.send_finalization(
        peer_id.as_raw(),
        &FinalizationMessage::deserialize(content)?,
    );
    info!(
        "Sent finalization message from the network peer {} to consensus layer",
        peer_id
    );
    Ok(())
}

fn send_block_to_baker(
    baker: &mut consensus::ConsensusContainer,
    peer_id: P2PNodeId,
    content: &[u8],
) -> Fallible<()> {
    let block = Block::deserialize(content)?;
    match baker.send_block(peer_id.as_raw(), &block) {
        0i64 => info!("Sent block from the network peer {} to baker", peer_id),
        err_code => error!(
            "Can't send block from the network peer {} to baker due to error code #{}",
            peer_id, err_code,
        ),
    }
    Ok(())
}

// Upon handshake completion we ask the consensus layer for a finalization point
// we want to catchup from. This information is relayed to the peer we just
// connected to, which will then emit all finalizations past this point.
fn send_catchup_finalization_messages_by_point_to_baker(
    baker: &mut consensus::ConsensusContainer,
    peer_id: P2PNodeId,
    content: &[u8],
) -> Fallible<()> {
    match baker.get_finalization_messages(&content[..], peer_id.as_raw())? {
        0i64 => info!(
            "Successfully requested finalization messages for requested point for the network \
             peer {} from consensus",
            peer_id
        ),
        err_code => error!(
            "Could not request finalization messages from point for the network peer {} from \
             consensus due to error code {}",
            peer_id, err_code
        ),
    }
    Ok(())
}

// This function requests the finalization record for a certain finalization
// index (this function is triggered by consensus on another peer actively asks
// the p2p layer to request this for it)
fn send_catchup_request_finalization_record_by_index_to_baker(
    baker: &mut consensus::ConsensusContainer,
    node: &mut P2PNode,
    peer_id: P2PNodeId,
    network_id: NetworkId,
    content: &[u8],
) -> Fallible<()> {
    debug!("Got consensus catch-up request for finalization record by index");
    let index = NetworkEndian::read_u64(&content[..8]);
    let res = baker.get_indexed_finalization(index)?;
    if NetworkEndian::read_u64(&res[..8]) > 0 {
        let mut out_bytes = Vec::with_capacity(2 + res.len());
        out_bytes
            .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_FINALIZATION_RECORD)
            .expect("Can't write to buffer");
        out_bytes.extend(res);
        match &node.send_message(Some(peer_id), network_id, None, out_bytes, true) {
            Ok(_) => info!(
                "Responded to a catchu-request from the network peer {}",
                peer_id
            ),
            Err(_) => error!(
                "Couldn't respond to a catch-up request from the network peer {}!",
                peer_id
            ),
        }
    } else {
        error!(
            "Consensus doesn't have the finalization record the network peer {} requested",
            peer_id
        );
    }
    Ok(())
}

fn send_catchup_request_finalization_record_by_bash_baker(
    baker: &mut consensus::ConsensusContainer,
    node: &mut P2PNode,
    peer_id: P2PNodeId,
    network_id: NetworkId,
    content: &[u8],
) -> Fallible<()> {
    debug!("Got consensus catch-up request for finalization record by the hash");
    let res = baker.get_block_finalization(&content[..])?;
    if NetworkEndian::read_u64(&res[..8]) > 0 {
        let mut out_bytes = Vec::with_capacity(2 + res.len());
        out_bytes
            .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_FINALIZATION_RECORD)
            .expect("Can't write to buffer");
        out_bytes.extend(res);
        match &node.send_message(Some(peer_id), network_id, None, out_bytes, true) {
            Ok(_) => info!(
                "Responded to a catch-up request from the network peer {}",
                peer_id
            ),
            Err(_) => error!(
                "Couldn't respond to a catch-up request from the network peer {}!",
                peer_id
            ),
        }
    } else {
        error!(
            "Consensus doesn't have the finalization record the network peer {} requested",
            peer_id
        );
    }
    Ok(())
}

fn send_catchup_request_block_by_bash_baker(
    baker: &mut consensus::ConsensusContainer,
    node: &mut P2PNode,
    peer_id: P2PNodeId,
    network_id: NetworkId,
    content: &[u8],
) -> Fallible<()> {
    let res = baker.get_block(&content[..])?;
    if NetworkEndian::read_u64(&res[..8]) > 0 {
        let mut out_bytes = Vec::with_capacity(2 + res.len());
        out_bytes
            .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_BLOCK)
            .expect("Can't write to buffer");
        out_bytes.extend(res);
        match &node.send_message(Some(peer_id), network_id, None, out_bytes, true) {
            Ok(_) => info!(
                "Responded to a catch-up request from the network peer {}",
                peer_id
            ),
            Err(_) => error!(
                "Couldn't respond to a catch-up request from the network peer {}!",
                peer_id
            ),
        }
    } else {
        error!(
            "Consensus doesn't have the block the network peer {} requested",
            peer_id
        );
    }
    Ok(())
}

fn main() -> Fallible<()> {
    let (conf, mut app_prefs) = get_config_and_logging_setup();
    if conf.common.print_config {
        // Print out the configuration
        info!("{:?}", conf);
    }

    // Retrieving bootstrap nodes
    let dns_resolvers =
        utils::get_resolvers(&conf.connection.resolv_conf, &conf.connection.dns_resolver);
    for resolver in &dns_resolvers {
        debug!("Using resolver: {}", resolver);
    }
    let bootstrap_nodes = utils::get_bootstrap_nodes(
        conf.connection.bootstrap_server.clone(),
        &dns_resolvers,
        conf.connection.dnssec_disabled,
        &conf.connection.bootstrap_node,
    );

    // Create the database
    let mut db_path = app_prefs.get_user_app_dir();
    db_path.push("p2p.db");
    let db = P2PDB::new(db_path.as_path());

    // Instantiate stats export engine
    let stats_export_service =
        client_utils::instantiate_stats_export_engine(&conf, StatsServiceMode::NodeMode)
            .unwrap_or_else(|e| {
                error!(
                    "I was not able to instantiate an stats export service: {}",
                    e
                );
                None
            });

    info!("Debugging enabled: {}", conf.common.debug);

    // Instantiate the p2p node
    let (mut node, pkt_out) = instantiate_node(&conf, &mut app_prefs, &stats_export_service);

    // Banning nodes in database
    match db.get_banlist() {
        Some(nodes) => {
            info!("Found existing banlist, loading up!");
            for n in nodes {
                node.ban_node(n);
            }
        }
        None => {
            warn!("Couldn't find existing banlist. Creating new!");
            db.create_banlist();
        }
    };

    #[cfg(feature = "instrumentation")]
    // Start push gateway to prometheus
    client_utils::start_push_gateway(&conf.prometheus, &stats_export_service, node.id())?;

    // Start the P2PNode
    //
    // Thread #3: P2P event loop
    node.spawn();

    // Connect to nodes (args and bootstrap)
    if !conf.cli.no_network {
        info!("Concordium P2P layer, Network disabled");
        create_connections_from_config(&conf.connection, &dns_resolvers, &mut node);
        if !conf.connection.no_bootstrap_dns {
            info!("Attempting to bootstrap");
            bootstrap(&bootstrap_nodes, &mut node);
        }
    }

    let mut baker = if conf.cli.baker.baker_id.is_some() {
        // Wait until we have at least a certain percentage of peers out of desired
        // before starting the baker
        let needed_peers = (f64::from(conf.connection.desired_nodes)
            * (f64::from(conf.cli.baker.baker_min_peer_satisfaction_percentage) / 100.0))
            .floor();

        let network_ids: Vec<NetworkId> = conf
            .common
            .network_ids
            .iter()
            .map(|x| NetworkId::from(x.to_owned()))
            .collect();

        let mut peer_count_opt = Some(
            node.get_peer_stats(&network_ids)
                .iter()
                .filter(|x| x.peer_type == PeerType::Node)
                .count(),
        );

        while let Some(peer_count) = peer_count_opt {
            if peer_count < needed_peers as usize {
                // Sleep until we've gotten more peers
                info!(
                    "Waiting for {} peers before starting baker. Currently have {}",
                    needed_peers, peer_count,
                );

                thread::sleep(Duration::from_secs(5));

                peer_count_opt = Some(
                    node.get_peer_stats(&network_ids)
                        .iter()
                        .filter(|x| x.peer_type == PeerType::Node)
                        .count(),
                );
            } else {
                peer_count_opt = None;
            }
        }

        // We've gotten enough peers. We'll let it start the baker now.
        info!("We've gotten enough peers. Beginning baker startup!");
        // Starting baker
        start_baker(&conf.cli.baker, &app_prefs)
    } else {
        None
    };

    if let Some(ref baker) = baker {
        // Register handler for sending out a consensus catch-up request after handshake
        // by finalization point.
        let cloned_handshake_response_node = Arc::new(RwLock::new(node.clone()));
        let baker_clone = baker.clone();
        let message_handshake_response_handler = &node.message_handler();
        safe_write!(message_handshake_response_handler)?.add_response_callback(make_atomic_callback!(
            move |msg: &NetworkResponse| {
                if let NetworkResponse::Handshake(ref remote_peer, ref nets, _) = msg {
                    if let Some(net) = nets.iter().next() {
                        let mut locked_cloned_node = write_or_die!(cloned_handshake_response_node);
                        if let Ok(bytes) = baker_clone.get_finalization_point() {
                            let mut out_bytes = Vec::with_capacity(2+bytes.len());
                            match out_bytes
                                .write_u16::<NetworkEndian>(consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_BY_POINT)
                                {
                                    Ok(_) => {
                                        out_bytes.extend(&bytes);
                                        match locked_cloned_node.send_message(Some(remote_peer.id()), *net, None, out_bytes, false)
                                        {
                                            Ok(_) => info!(
                                                "Sent request for the current round finalization messages by point to {}",
                                                remote_peer.id()
                                            ),
                                            Err(_) => error!("Couldn't send catch-up request for finalization messages by point!"),
                                        }
                                    }
                                    Err(_) => error!("Can't write type to packet {}", consensus::PACKET_TYPE_CONSENSUS_CATCHUP_REQUEST_FINALIZATION_BY_POINT),
                                }
                        }
                    } else {
                        error!("Handshake without network, so can't ask for finalization messages");
                    }
                }
                Ok(())
            }
        ));
    }

    // Starting rpc server
    let mut rpc_serv = if !conf.cli.rpc.no_rpc_server {
        let mut serv = RpcServerImpl::new(node.clone(), db.clone(), baker.clone(), &conf.cli.rpc);
        serv.start_server()?;
        Some(serv)
    } else {
        None
    };

    // Connect outgoing messages to be forwarded into the baker and RPC streams.
    //
    // Thread #4: Read P2PNode output
    setup_process_output(&node, &db, &conf, &rpc_serv, &mut baker, pkt_out);

    // Create listeners on baker output to forward to P2PNode
    //
    // Threads #5, #6, #7, #8, #9
    setup_baker_guards(&mut baker, &node, &conf);

    // TPS test
    start_tps_test(&conf, &node);

    // Wait for node closing
    node.join().expect("Node thread panicked!");

    // Close rpc server if present
    if let Some(ref mut serv) = rpc_serv {
        serv.stop_server()?;
    }

    // Close baker if present
    if let Some(ref mut baker_ref) = baker {
        if let Some(baker_id) = conf.cli.baker.baker_id {
            baker_ref.stop_baker(baker_id)
        };
        consensus::ConsensusContainer::stop_haskell();
    }

    // Close stats server export if present
    client_utils::stop_stats_export_engine(&conf, &stats_export_service);

    Ok(())
}

fn start_baker(
    conf: &configuration::BakerConfig,
    app_prefs: &configuration::AppPreferences,
) -> Option<consensus::ConsensusContainer> {
    conf.baker_id.and_then(|baker_id| {
        // Check for invalid configuration
        if baker_id > conf.baker_num_bakers {
            // Baker ID is higher than amount of bakers in the network. Bail!
            error!("Baker ID is higher than amount of bakers in the network! Disabling baking");
            return None;
        }

        info!("Starting up baker thread");
        consensus::ConsensusContainer::start_haskell();
        match get_baker_data(app_prefs, conf) {
            Ok((genesis, private_data)) => {
                let mut consensus_runner = consensus::ConsensusContainer::new(genesis);
                consensus_runner.start_baker(baker_id, private_data);
                Some(consensus_runner)
            }
            Err(_) => {
                error!("Can't read needed data...");
                None
            }
        }
    })
}

fn bootstrap(bootstrap_nodes: &Result<Vec<SocketAddr>, &'static str>, node: &mut P2PNode) {
    match bootstrap_nodes {
        Ok(nodes) => {
            for &addr in nodes {
                info!("Found bootstrap node: {}", addr);
                node.connect(PeerType::Bootstrapper, addr, None)
                    .unwrap_or_else(|e| error!("{}", e));
            }
        }
        Err(e) => error!("Couldn't retrieve bootstrap node list! {:?}", e),
    };
}

fn create_connections_from_config(
    conf: &configuration::ConnectionConfig,
    dns_resolvers: &[String],
    node: &mut P2PNode,
) {
    for connect_to in &conf.connect_to {
        match utils::parse_host_port(&connect_to, &dns_resolvers, conf.dnssec_disabled) {
            Ok(addrs) => {
                for addr in addrs {
                    info!("Connecting to peer {}", &connect_to);
                    node.connect(PeerType::Node, addr, None)
                        .unwrap_or_else(|e| error!("{}", e));
                }
            }
            Err(err) => error!("{}", err),
        }
    }
}

#[cfg(feature = "instrumentation")]
fn send_packet_to_testrunner(node: &P2PNode, test_runner_url: &str, pac: &NetworkPacket) {
    debug!("Sending information to test runner");
    match reqwest::get(&format!(
        "{}/register/{}/{}",
        test_runner_url,
        node.id(),
        pac.message_id
    )) {
        Ok(ref mut res) if res.status().is_success() => {
            info!("Registered packet received with test runner")
        }
        _ => error!("Couldn't register packet received with test runner"),
    }
}

#[cfg(not(feature = "instrumentation"))]
fn send_packet_to_testrunner(_: &P2PNode, _: &str, _: &NetworkPacket) {}

fn _send_retransmit_packet(
    node: &mut P2PNode,
    receiver: P2PNodeId,
    network_id: NetworkId,
    message_id: &str,
    payload_type: u16,
    data: &[u8],
) {
    let mut out_bytes = Vec::with_capacity(2 + data.len());
    match out_bytes.write_u16::<NetworkEndian>(payload_type as u16) {
        Ok(_) => {
            out_bytes.extend(data);
            match node.send_message(
                Some(receiver),
                network_id,
                Some(message_id.to_owned()),
                out_bytes,
                false,
            ) {
                Ok(_) => debug!("Retransmitted packet of type {}", payload_type),
                Err(_) => error!("Couldn't retransmit packet of type {}!", payload_type),
            }
        }
        Err(_) => error!("Can't write payload type, so failing retransmit of packet"),
    }
}

fn get_baker_data(
    app_prefs: &configuration::AppPreferences,
    conf: &configuration::BakerConfig,
) -> Fallible<(Vec<u8>, Vec<u8>)> {
    let mut genesis_loc = app_prefs.get_user_app_dir();
    genesis_loc.push("genesis.dat");

    let mut private_loc = app_prefs.get_user_app_dir();

    if let Some(baker_id) = conf.baker_id {
        private_loc.push(format!("baker_private_{}.dat", baker_id))
    };

    let (generated_genesis, generated_private_data) =
        if !genesis_loc.exists() || !private_loc.exists() {
            consensus::ConsensusContainer::generate_data(conf.baker_num_bakers)?
        } else {
            (vec![], HashMap::new())
        };

    let given_genesis = if !genesis_loc.exists() {
        match OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&genesis_loc)
        {
            Ok(mut file) => match file.write_all(&generated_genesis) {
                Ok(_) => generated_genesis,
                Err(_) => bail!("Couldn't write out genesis data"),
            },
            Err(_) => bail!("Couldn't open up genesis file for writing"),
        }
    } else {
        match OpenOptions::new().read(true).open(&genesis_loc) {
            Ok(mut file) => {
                let mut read_data = vec![];
                match file.read_to_end(&mut read_data) {
                    Ok(_) => read_data.clone(),
                    Err(_) => bail!("Couldn't read genesis file properly"),
                }
            }
            _ => bail!("Unexpected"),
        }
    };

    let given_private_data = if !private_loc.exists() {
        match OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&private_loc)
        {
            Ok(mut file) => {
                if let Some(baker_id) = conf.baker_id {
                    match file.write_all(&generated_private_data[&(baker_id as i64)]) {
                        Ok(_) => generated_private_data[&(baker_id as i64)].to_owned(),
                        Err(_) => bail!("Couldn't write out private baker data"),
                    }
                } else {
                    bail!("Couldn't write out private baker data");
                }
            }
            Err(_) => bail!("Couldn't open up private baker file for writing"),
        }
    } else {
        match OpenOptions::new().read(true).open(&private_loc) {
            Ok(mut file) => {
                let mut read_data = vec![];
                match file.read_to_end(&mut read_data) {
                    Ok(_) => read_data,
                    Err(_) => bail!("Couldn't open up private baker file for reading"),
                }
            }
            _ => bail!("Unexpected"),
        }
    };
    Ok((given_genesis, given_private_data))
}
