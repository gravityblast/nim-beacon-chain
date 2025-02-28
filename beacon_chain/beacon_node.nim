import
  std_shims/[os_shims, objects], net, sequtils, options, tables,
  chronos, chronicles, confutils,
  spec/[datatypes, digest, crypto, beaconstate, helpers, validator], conf, time,
  state_transition, fork_choice, ssz, beacon_chain_db, validator_pool, extras,
  attestation_pool, block_pool, eth2_network, beacon_node_types,
  mainchain_monitor, trusted_state_snapshots,
  eth/trie/db, eth/trie/backends/rocksdb_backend

const
  topicBeaconBlocks = "ethereum/2.1/beacon_chain/blocks"
  topicAttestations = "ethereum/2.1/beacon_chain/attestations"
  topicfetchBlocks = "ethereum/2.1/beacon_chain/fetch"

# #################################################
# Careful handling of beacon_node <-> sync_protocol
# to avoid recursive dependencies
proc onBeaconBlock*(node: BeaconNode, blck: BeaconBlock) {.gcsafe.}
  # Forward decl for sync_protocol
import sync_protocol
# #################################################

func shortValidatorKey(node: BeaconNode, validatorIdx: int): string =
  ($node.state.data.validator_registry[validatorIdx].pubkey)[0..7]

func slotStart(node: BeaconNode, slot: Slot): Timestamp =
  node.state.data.slotStart(slot)

proc init*(T: type BeaconNode, conf: BeaconNodeConf): Future[BeaconNode] {.async.} =
  new result
  result.config = conf

  result.attachedValidators = ValidatorPool.init
  init result.mainchainMonitor, "", Port(0) # TODO: specify geth address and port

  let trieDB = trieDB newChainDb(string conf.dataDir)
  result.db = BeaconChainDB.init(trieDB)

  # TODO this is problably not the right place to ensure that db is sane..
  # TODO does it really make sense to load from DB if a state snapshot has been
  #      specified on command line? potentially, this should be the other way
  #      around...

  let headBlock = result.db.getHeadBlock()
  if headBlock.isNone():
    let
      tailState = result.config.stateSnapshot.get()
      tailBlock = get_initial_beacon_block(tailState)
      blockRoot = hash_tree_root_final(tailBlock)

    notice "Creating new database from snapshot",
      blockRoot = shortLog(blockRoot),
      stateRoot = shortLog(tailBlock.state_root),
      fork = tailState.fork,
      validators = tailState.validator_registry.len()

    result.db.putState(tailState)
    result.db.putBlock(tailBlock)
    result.db.putTailBlock(blockRoot)
    result.db.putHeadBlock(blockRoot)

  result.blockPool = BlockPool.init(result.db)
  result.attestationPool = AttestationPool.init(result.blockPool)

  result.network = await createEth2Node(Port conf.tcpPort, Port conf.udpPort)

  let state = result.network.protocolState(BeaconSync)
  state.node = result
  state.db = result.db

  let head = result.blockPool.get(result.db.getHeadBlock().get())

  result.state = result.blockPool.loadTailState()

  let addressFile = string(conf.dataDir) / "beacon_node.address"
  result.network.saveConnectionAddressFile(addressFile)

proc connectToNetwork(node: BeaconNode) {.async.} =
  var bootstrapNodes = newSeq[BootstrapAddr]()

  for node in node.config.bootstrapNodes:
    bootstrapNodes.add BootstrapAddr.init(node)

  let bootstrapFile = string node.config.bootstrapNodesFile
  if bootstrapFile.len > 0:
    for ln in lines(bootstrapFile):
      bootstrapNodes.add BootstrapAddr.init(string ln)

  if bootstrapNodes.len > 0:
    info "Connecting to bootstrap nodes", bootstrapNodes
  else:
    info "Waiting for connections"

  await node.network.connectToNetwork(bootstrapNodes)

proc sync*(node: BeaconNode): Future[bool] {.async.} =
  if node.state.data.slotDistanceFromNow() > WEAK_SUBJECTVITY_PERIOD.int64:
    # node.state.data = await obtainTrustedStateSnapshot(node.db)
    return false
  else:
    # TODO waiting for genesis should probably be moved elsewhere.. it has
    #      little to do with syncing..
    let t = now()
    if t < node.state.data.genesis_time * 1000:
      notice "Waiting for genesis",
        fromNow = int(node.state.data.genesis_time * 1000 - t) div 1000
      await sleepAsync int(node.state.data.genesis_time * 1000 - t)

    let
      targetSlot = node.state.data.getSlotFromTime()

    # TODO: change this to a full sync / block download
    info "Syncing state from remote peers",
      finalized_epoch = humaneEpochNum(node.state.data.finalized_epoch),
      target_slot_epoch = humaneEpochNum(targetSlot.slot_to_epoch)

    # TODO: sync is called at the beginning of the program, but doing this kind
    #       of catching up here is wrong - if we fall behind on processing
    #       for whatever reason, we want to be safe against the damage that
    #       might cause regardless if we just started or have been running for
    #       long. A classic example where this might happen is when the
    #       computer goes to sleep - when waking up, we'll be in the middle of
    #       processing, but behind everyone else.
    # TOOD we now detect during epoch scheduling if we're very far behind -
    #      that would potentially be a good place to run the sync (?)
    # while node.beaconState.finalized_epoch < targetSlot.slot_to_epoch:
    #   var (peer, changeLog) = await node.network.getValidatorChangeLog(
    #     node.beaconState.validator_registry_delta_chain_tip)

    #   if peer == nil:
    #     error "Failed to sync with any peer"
    #     return false

    #   if applyValidatorChangeLog(changeLog, node.beaconState):
    #     node.db.persistState(node.beaconState)
    #     node.db.persistBlock(changeLog.signedBlock)
    #   else:
    #     warn "Ignoring invalid validator change log", sentFrom = peer

  return true

template findIt(s: openarray, predicate: untyped): int =
  var res = -1
  for i, it {.inject.} in s:
    if predicate:
      res = i
      break
  res

proc addLocalValidators*(node: BeaconNode) =
  for privKey in node.config.validators:
    let
      pubKey = privKey.pubKey()

    let idx = node.state.data.validator_registry.findIt(it.pubKey == pubKey)
    if idx == -1:
      warn "Validator not in registry", pubKey
    else:
      debug "Attaching validator", validator = shortValidatorKey(node, idx),
                                   idx, pubKey
      node.attachedValidators.addLocalValidator(idx, pubKey, privKey)

  info "Local validators attached ", count = node.attachedValidators.count

proc getAttachedValidator(node: BeaconNode, idx: int): AttachedValidator =
  let validatorKey = node.state.data.validator_registry[idx].pubkey
  return node.attachedValidators.getValidator(validatorKey)

proc updateHead(node: BeaconNode): BlockRef =
  # TODO move all of this logic to BlockPool
  let
    justifiedHead = node.blockPool.latestJustifiedBlock()

  # TODO slot number is wrong here, it should be the start of the epoch that
  #      got finalized:
  #      https://github.com/ethereum/eth2.0-specs/issues/768
  node.blockPool.updateState(node.state, justifiedHead, justifiedHead.slot)

  let newHead = lmdGhost(node.attestationPool, node.state.data, justifiedHead)
  node.blockPool.updateHead(node.state, newHead)
  newHead

proc makeAttestation(node: BeaconNode,
                     validator: AttachedValidator,
                     slot: Slot,
                     shard: uint64,
                     committeeLen: int,
                     indexInCommittee: int) {.async.} =
  doAssert node != nil
  doAssert validator != nil

  # It's time to make an attestation. To do so, we must determine what we
  # consider to be the head block - this is done by the fork choice rule.
  # TODO this lazy update of the head is good because it delays head resolution
  #      until the very latest moment - on the other hand, if it takes long, the
  #      attestation might be late!
  let
    head = node.updateHead()

  if slot + MIN_ATTESTATION_INCLUSION_DELAY < head.slot:
    # What happened here is that we're being really slow or there's something
    # really fishy going on with the slot - let's not send out any attestations
    # just in case...
    # TODO is this the right cutoff?
    notice "Skipping attestation, head is too recent",
      headSlot = humaneSlotNum(head.slot),
      slot = humaneSlotNum(slot)
    return

  let attestationHead = head.findAncestorBySlot(slot)
  if head != attestationHead:
    # In rare cases, such as when we're busy syncing or just slow, we'll be
    # attesting to a past state - we must then recreate the world as it looked
    # like back then
    notice "Attesting to a state in the past, falling behind?",
      headSlot = humaneSlotNum(head.slot),
      attestationHeadSlot = humaneSlotNum(attestationHead.slot),
      attestationSlot = humaneSlotNum(slot)

  # We need to run attestations exactly for the slot that we're attesting to.
  # In case blocks went missing, this means advancing past the latest block
  # using empty slots as fillers.
  node.blockPool.updateState(node.state, attestationHead, slot)

  # Check pending attestations - maybe we found some blocks for them
  node.attestationPool.resolve(node.state.data)

  let
    attestationData =
      makeAttestationData(node.state.data, shard, node.state.blck.root)

    # Careful - after await. node.state (etc) might have changed in async race
    validatorSignature = await validator.signAttestation(attestationData)

  var aggregationBitfield = repeat(0'u8, ceil_div8(committeeLen))
  bitSet(aggregationBitfield, indexInCommittee)

  var attestation = Attestation(
    data: attestationData,
    aggregate_signature: validatorSignature,
    aggregation_bitfield: aggregationBitfield,
    # Stub in phase0
    custody_bitfield: newSeq[byte](aggregationBitfield.len)
  )

  # TODO what are we waiting for here? broadcast should never block, and never
  #      fail...
  await node.network.broadcast(topicAttestations, attestation)

  info "Attestation sent",
    slot = humaneSlotNum(attestationData.slot),
    shard = attestationData.shard,
    validator = shortValidatorKey(node, validator.idx),
    signature = shortLog(validatorSignature),
    beaconBlockRoot = shortLog(attestationData.beacon_block_root)

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  slot: Slot) {.async.} =
  doAssert node != nil
  doAssert validator != nil
  doAssert validator.idx < node.state.data.validator_registry.len

  # To propose a block, we should know what the head is, because that's what
  # we'll be building the next block upon..
  let head = node.updateHead()

  if head.slot > slot:
    notice "Skipping proposal, we've already selected a newer head",
      headSlot = humaneSlotNum(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = humaneSlotNum(slot)

  if head.slot == slot:
    # Weird, we should never see as head the same slot as we're proposing a
    # block for - did someone else steal our slot? why didn't we discard it?
    warn "Found head at same slot as we're supposed to propose for!",
      headSlot = humaneSlotNum(head.slot),
      headBlockRoot = shortLog(head.root)
    # TODO investigate how and when this happens.. maybe it shouldn't be an
    #      assert?
    doAssert false, "head slot matches proposal slot (!)"
    # return

  # There might be gaps between our proposal and what we think is the head -
  # make sure the state we get takes that into account: we want it to point
  # to the slot just before our proposal.
  node.blockPool.updateState(node.state, head, slot - 1)

  # To create a block, we'll first apply a partial block to the state, skipping
  # some validations.
  var blockBody = BeaconBlockBody(
    attestations: node.attestationPool.getAttestationsForBlock(slot))

  var newBlock = BeaconBlock(
    slot: slot,
    parent_root: node.state.blck.root,
    randao_reveal: validator.genRandaoReveal(node.state.data, slot),
    eth1_data: node.mainchainMonitor.getBeaconBlockRef(),
    body: blockBody,
    signature: ValidatorSig(), # we need the rest of the block first!
    )

  let ok =
    updateState(
        node.state.data, node.state.blck.root, newBlock, {skipValidation})
  doAssert ok # TODO: err, could this fail somehow?
  node.state.root = hash_tree_root_final(node.state.data)

  newBlock.state_root = node.state.root

  let proposal = Proposal(
    slot: slot.uint64,
    shard: BEACON_CHAIN_SHARD_NUMBER,
    block_root: Eth2Digest(data: signed_root(newBlock, "signature")),
    signature: ValidatorSig(),
  )
  newBlock.signature =
    await validator.signBlockProposal(node.state.data.fork, proposal)

  # TODO what are we waiting for here? broadcast should never block, and never
  #      fail...
  await node.network.broadcast(topicBeaconBlocks, newBlock)

  info "Block proposed",
    slot = humaneSlotNum(slot),
    stateRoot = shortLog(newBlock.state_root),
    parentRoot = shortLog(newBlock.parent_root),
    validator = shortValidatorKey(node, validator.idx),
    idx = validator.idx

proc scheduleBlockProposal(node: BeaconNode,
                           slot: Slot,
                           validator: AttachedValidator) =
  # TODO:
  # This function exists only to hide a bug with Nim's closures.
  # If you inline it in `scheduleEpochActions`, you'll see the
  # internal `doAssert` starting to fail.
  doAssert validator != nil

  let
    at = node.slotStart(slot)
    now = fastEpochTime()

  if now > at:
    warn "Falling behind on block proposals", at, now, slot

  info "Scheduling block proposal",
    validator = shortValidatorKey(node, validator.idx),
    idx = validator.idx,
    slot = humaneSlotNum(slot),
    fromNow = (at - now) div 1000

  addTimer(at) do (x: pointer) {.gcsafe.}:
    # TODO timers are generally not accurate / guaranteed to fire at the right
    #      time - need to guard here against early / late firings
    doAssert validator != nil
    asyncCheck proposeBlock(node, validator, slot)

proc scheduleAttestation(node: BeaconNode,
                         validator: AttachedValidator,
                         slot: Slot,
                         shard: uint64,
                         committeeLen: int,
                         indexInCommittee: int) =
  # TODO:
  # This function exists only to hide a bug with Nim's closures.
  # If you inline it in `scheduleEpochActions`, you'll see the
  # internal `doAssert` starting to fail.
  doAssert validator != nil

  let
    at = node.slotStart(slot)
    now = fastEpochTime()

  if now > at:
    warn "Falling behind on attestations", at, now, slot

  debug "Scheduling attestation",
    validator = shortValidatorKey(node, validator.idx),
    fromNow = (at - now) div 1000,
    slot = humaneSlotNum(slot),
    shard

  addTimer(at) do (p: pointer) {.gcsafe.}:
    doAssert validator != nil
    asyncCheck makeAttestation(node, validator, slot,
                               shard, committeeLen, indexInCommittee)

proc scheduleEpochActions(node: BeaconNode, epoch: Epoch) =
  ## This schedules the required block proposals and
  ## attestations from our attached validators.
  doAssert node != nil
  doAssert epoch >= GENESIS_EPOCH,
    "Epoch: " & $epoch & ", humane epoch: " & $humaneEpochNum(epoch)

  # In case some late blocks dropped in..
  let head = node.updateHead()

  # Sanity check - verify that the current head block is not too far behind
  # TODO what if the head block is too far ahead? that would be.. weird.
  if head.slot.slot_to_epoch() + 1 < epoch:
    # We're hopelessly behind!
    #
    # There's a few ways this can happen:
    #
    # * we receive no attestations or blocks for an extended period of time
    # * all the attestations we receive are bogus - maybe we're connected to
    #   the wrong network?
    # * we just started and still haven't synced
    #
    # TODO make an effort to find other nodes and sync? A worst case scenario
    #      here is that the network stalls because nobody is sending out
    #      attestations because nobody is scheduling them, in a vicious
    #      circle
    # TODO diagnose the various scenarios and do something smart...

    let
      expectedSlot = node.state.data.getSlotFromTime()
      nextSlot = expectedSlot + 1
      at = node.slotStart(nextSlot)

    notice "Delaying epoch scheduling, head too old - scheduling new attempt",
      headSlot = humaneSlotNum(head.slot),
      expectedEpoch = humaneEpochNum(epoch),
      expectedSlot = humaneSlotNum(expectedSlot),
      fromNow = (at - fastEpochTime()) div 1000

    addTimer(at) do (p: pointer):
      node.scheduleEpochActions(nextSlot.slot_to_epoch())
    return


  updateState(node.blockPool, node.state, head, epoch.get_epoch_start_slot())

  # TODO: is this necessary with the new shuffling?
  #       see get_beacon_proposer_index
  var nextState = node.state.data

  # TODO we don't need to do anything at slot 0 - what about slots we missed
  #      if we got delayed above?
  let start = if epoch == GENESIS_EPOCH: 1.uint64 else: 0.uint64

  for i in start ..< SLOTS_PER_EPOCH:
    let slot = (epoch * SLOTS_PER_EPOCH + i).Slot
    nextState.slot = slot # ugly trick, see get_beacon_proposer_index

    block: # Schedule block proposals
      let proposerIdx = get_beacon_proposer_index(nextState, slot)
      let validator = node.getAttachedValidator(proposerIdx)

      if validator != nil:
        # TODO:
        # Warm-up the proposer earlier to try to obtain previous
        # missing blocks if necessary
        scheduleBlockProposal(node, slot, validator)

    block: # Schedule attestations
      for crosslink_committee in get_crosslink_committees_at_slot(
          nextState, slot):
        for i, validatorIdx in crosslink_committee.committee:
          let validator = node.getAttachedValidator(validatorIdx)
          if validator != nil:
            scheduleAttestation(
              node, validator, slot, crosslink_committee.shard,
              crosslink_committee.committee.len, i)

  let
    # TODO we need to readjust here for wall clock time, in case computer
    #      goes to sleep for example, so that we don't walk epochs one by one
    #      to catch up.. we should also check the current head most likely to
    #      see if we're suspiciously off, in terms of wall clock vs head time.
    nextEpoch = epoch + 1
    at = node.slotStart(nextEpoch.get_epoch_start_slot())

  info "Scheduling next epoch update",
    fromNow = (at - fastEpochTime()) div 1000,
    epoch = humaneEpochNum(nextEpoch)

  addTimer(at) do (p: pointer):
    node.scheduleEpochActions(nextEpoch)

proc fetchBlocks(node: BeaconNode, roots: seq[Eth2Digest]) =
  if roots.len == 0: return

  # TODO shouldn't send to all!
  # TODO should never fail - asyncCheck is wrong here..
  asyncCheck node.network.broadcast(topicfetchBlocks, roots)

proc onFetchBlocks(node: BeaconNode, roots: seq[Eth2Digest]) =
  # TODO placeholder logic for block recovery
  debug "fetchBlocks received",
    roots = roots.len
  for root in roots:
    if (let blck = node.db.getBlock(root); blck.isSome()):
      # TODO should never fail - asyncCheck is wrong here..
      # TODO should obviously not spam, but rather send it back to the requester
      asyncCheck node.network.broadcast(topicBeaconBlocks, blck.get())

proc scheduleSlotStartActions(node: BeaconNode, slot: Slot) =
  # TODO in this setup, we retry fetching blocks at the beginning of every slot,
  #      hoping that we'll get some before it's time to attest or propose - is
  #      there a better time to do this?
  let missingBlocks = node.blockPool.checkUnresolved()
  node.fetchBlocks(missingBlocks)

  let
    nextSlot = slot + 1
    at = node.slotStart(nextSlot)

  info "Scheduling next slot start action block",
    fromNow = (at - fastEpochTime()) div 1000,
    slot = humaneSlotNum(nextSlot)

  addTimer(at) do (p: pointer):
    node.scheduleSlotStartActions(nextSlot)

proc onAttestation(node: BeaconNode, attestation: Attestation) =
  # We received an attestation from the network but don't know much about it
  # yet - in particular, we haven't verified that it belongs to particular chain
  # we're on, or that it follows the rules of the protocol
  debug "Attestation received",
    slot = humaneSlotNum(attestation.data.slot),
    shard = attestation.data.shard,
    beaconBlockRoot = shortLog(attestation.data.beacon_block_root),
    justifiedEpoch = humaneEpochNum(attestation.data.justified_epoch),
    justifiedBlockRoot = shortLog(attestation.data.justified_block_root),
    signature = shortLog(attestation.aggregate_signature)

  node.attestationPool.add(node.state.data, attestation)

proc onBeaconBlock(node: BeaconNode, blck: BeaconBlock) =
  # We received a block but don't know much about it yet - in particular, we
  # don't know if it's part of the chain we're currently building.
  let blockRoot = hash_tree_root_final(blck)
  debug "Block received",
    blockRoot = shortLog(blockRoot),
    slot = humaneSlotNum(blck.slot),
    stateRoot = shortLog(blck.state_root),
    parentRoot = shortLog(blck.parent_root),
    signature = shortLog(blck.signature),
    proposer_slashings = blck.body.proposer_slashings.len,
    attester_slashings = blck.body.attester_slashings.len,
    attestations = blck.body.attestations.len,
    deposits = blck.body.deposits.len,
    voluntary_exits = blck.body.voluntary_exits.len,
    transfers = blck.body.transfers.len

  if not node.blockPool.add(node.state, blockRoot, blck):
    # TODO the fact that add returns a bool that causes the parent block to be
    #      pre-emptively fetched is quite ugly - fix.
    node.fetchBlocks(@[blck.parent_root])

  # The block we received contains attestations, and we might not yet know about
  # all of them. Let's add them to the attestation pool - in case they block
  # is not yet resolved, neither will the attestations be!
  for attestation in blck.body.attestations:
    # TODO attestation pool needs to be taught to deal with overlapping
    #      attestations!
    discard # node.onAttestation(attestation)

proc run*(node: BeaconNode) =
  waitFor node.network.subscribe(topicBeaconBlocks) do (blck: BeaconBlock):
    node.onBeaconBlock(blck)

  waitFor node.network.subscribe(topicAttestations) do (attestation: Attestation):
    node.onAttestation(attestation)

  waitFor node.network.subscribe(topicfetchBlocks) do (roots: seq[Eth2Digest]):
    node.onFetchBlocks(roots)

  let nowSlot = node.state.data.getSlotFromTime()

  node.scheduleEpochActions(nowSlot.slot_to_epoch())
  node.scheduleSlotStartActions(nowSlot)

  runForever()

var gPidFile: string
proc createPidFile(filename: string) =
  createDir splitFile(filename).dir
  writeFile filename, $getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = removeFile gPidFile

when isMainModule:
  let config = load BeaconNodeConf
  if config.logLevel != LogLevel.NONE:
    setLogLevel(config.logLevel)

  case config.cmd
  of createChain:
    createStateSnapshot(
      config.validatorsDir.string, config.numValidators, config.firstValidator,
      config.genesisOffset, config.outputStateFile.string)
    quit 0

  of noCommand:
    waitFor synchronizeClock()
    createPidFile(config.dataDir.string / "beacon_node.pid")

    var node = waitFor BeaconNode.init(config)

    dynamicLogScope(node = node.config.tcpPort - 50000):
      # TODO: while it's nice to cheat by waiting for connections here, we
      #       actually need to make this part of normal application flow -
      #       losing all connections might happen at any time and we should be
      #       prepared to handle it.
      waitFor node.connectToNetwork()

      if not waitFor node.sync():
        quit 1

      info "Starting beacon node",
        slotsSinceFinalization = node.state.data.slotDistanceFromNow(),
        stateSlot = humaneSlotNum(node.state.data.slot),
        SHARD_COUNT,
        SLOTS_PER_EPOCH,
        SECONDS_PER_SLOT,
        SPEC_VERSION

      node.addLocalValidators()
      node.run()
