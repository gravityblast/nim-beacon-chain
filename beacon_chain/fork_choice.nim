import
  deques,
  spec/[datatypes, crypto]

type
  AttestationCandidate* = object
    validator*: int
    data*: AttestationData
    signature*: ValidatorSig

  AttestationPool* = object
    attestations: Deque[seq[AttestationCandidate]]
    startingSlot: int

proc init*(T: type AttestationPool, startingSlot: int): T =
  result.attestationsPerSlot = initDeque[seq[AttestationCandidate]]()
  result.startingSlot = startingSlot

proc setLen*[T](d: var Deque[T], len: int) =
  # TODO: The upstream `Deque` type should gain a proper resize API
  let delta = len - d.len
  if delta > 0:
    for i in 0 ..< delta:
      var defaultVal: T
      d.addLast(defaultVal)
  else:
    d.shrink(fromLast = delta)

proc add*(pool: var AttestationPool,
          attestation: AttestationCandidate,
          beaconState: BeaconState) =
  # The caller of this function is responsible for ensuring that
  # the attestations will be given in a strictly slot increasing order:
  doAssert attestation.data.slot.int >= pool.startingSlot

  let slotIdxInPool = attestation.data.slot.int - pool.startingSlot
  if slotIdxInPool >= pool.attestations.len:
    pool.attestations.setLen(slotIdxInPool + 1)

  pool.attestations[slotIdxInPool].add attestation

iterator each*(pool: AttestationPool,
               firstSlot, lastSlot: int): AttestationCandidate =
  ## Both indices are treated inclusively
  ## TODO: this should return a lent value
  doAssert firstSlot <= lastSlot
  for idx in countup(max(0, firstSlot - pool.startingSlot),
                     min(pool.attestations.len - 1, lastSlot - pool.startingSlot)):
    for attestation in pool.attestations[idx]:
      yield attestation

proc discardHistoryToSlot*(pool: var AttestationPool, slot: int) =
  ## The index is treated inclusively
  if slot < pool.startingSlot:
    return
  let slotIdx = int(slot - pool.startingSlot)
  pool.attestations.shrink(fromFirst = slotIdx + 1)

func getAttestationCandidate*(attestation: Attestation): AttestationCandidate =
  # TODO: not complete AttestationCandidate object
  result.data = attestation.data
  result.signature = attestation.aggregate_signature

func getLatestAttestation*(pool: AttestationPool, validator: ValidatorRecord) =
  discard

func getLatestAttestationTarget*() =
  discard

func forkChoice*(pool: AttestationPool, oldHead, newBlock: BeaconBlock): bool =
  # This will return true if the new block is accepted over the old head block
  # TODO actual criteria, but something kind of sane to start with
  oldHead.state_root == newBlock.parent_root

