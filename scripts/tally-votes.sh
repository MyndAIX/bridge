#!/bin/bash
# tally-votes.sh — Count votes from a proposal
# Usage: tally-votes.sh VOTE-20260405120000

set -uo pipefail

VOTE_ID="${1:?Usage: tally-votes.sh VOTE-ID}"
RESULTS_DIR="$HOME/.myndaix/bridge/state/votes"
VOTE_FILE="$RESULTS_DIR/${VOTE_ID}.json"
LOBSTER_INBOX="$HOME/.myndaix/bridge/inbox/lobster"

if [[ ! -f "$VOTE_FILE" ]]; then
  echo "Vote not found: $VOTE_ID"
  exit 1
fi

APPROVE=0
REJECT=0
MISSING=0
TOTAL=0

PROPOSAL=$(python3 -c "import json; print(json.load(open('$VOTE_FILE'))['proposal'])")
VOTERS=$(python3 -c "import json; print(' '.join(json.load(open('$VOTE_FILE'))['voters']))")

echo "=== Vote Tally: $VOTE_ID ==="
echo "Proposal: $PROPOSAL"
echo ""

for AGENT in $VOTERS; do
  TOTAL=$((TOTAL + 1))
  RESPONSE="$LOBSTER_INBOX/${AGENT}-${VOTE_ID}-vote.md"
  
  if [[ -f "$RESPONSE" ]]; then
    VOTE=$(grep -i "approve\|reject" "$RESPONSE" | head -1 | tr '[:upper:]' '[:lower:]')
    if echo "$VOTE" | grep -qi "approve"; then
      echo "  $AGENT: APPROVE"
      APPROVE=$((APPROVE + 1))
    else
      echo "  $AGENT: REJECT"
      REJECT=$((REJECT + 1))
    fi
  else
    echo "  $AGENT: NO RESPONSE"
    MISSING=$((MISSING + 1))
  fi
done

echo ""
echo "Result: $APPROVE approve / $REJECT reject / $MISSING missing"

THRESHOLD=$(( (TOTAL + 1) / 2 ))
if [[ $APPROVE -ge $THRESHOLD ]]; then
  echo "DECISION: APPROVED (majority)"
elif [[ $REJECT -ge $THRESHOLD ]]; then
  echo "DECISION: REJECTED (majority)"
else
  echo "DECISION: NO QUORUM (need $THRESHOLD votes)"
fi
