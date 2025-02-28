import
  confutils,
  ../beacon_chain/[extras, ssz],
  ../beacon_chain/spec/[beaconstate, datatypes, digest, validator],
  ../tests/testutil

proc stateSize(deposits: int, maxContent = false) =
  var state = get_genesis_beacon_state(
    makeInitialDeposits(
      deposits, {skipValidation}), 0, Eth1Data(), {skipValidation})

  if maxContent:
    # TODO verify this is correct, but generally we collect up to two epochs
    #      of attestations, and each block has a cap on the number of
    #      attestations it may hold, so we'll just add so many of them
    state.latest_attestations.setLen(MAX_ATTESTATIONS * SLOTS_PER_EPOCH * 2)
    let
      crosslink_committees = get_crosslink_committees_at_slot(state, 0.Slot)
      validatorsPerCommittee =
        len(crosslink_committees[0].committee) # close enough..
    for a in state.latest_attestations.mitems():
      a.aggregation_bitfield.setLen(validatorsPerCommittee)
  echo "Validators: ", deposits, ", total: ", SSZ.encode(state).len

dispatch(stateSize)
