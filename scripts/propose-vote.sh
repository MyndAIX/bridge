#!/bin/bash
# propose-vote.sh — Multi-agent voting via bridge inbox
# Usage: propose-vote.sh "Should we deploy v2?" kilabz antman oracle
#
# Writes a vote request to each agent's inbox.
# Lobster collects responses and counts majority.

set -uo pipefail

PROPOSAL="$1"
shift
VOTERS=("$@")

if [[ -z "$PROPOSAL" || ${#VOTERS[@]} -eq 0 ]]; then
  echo "Usage: propose-vote.sh 'proposal text' agent1 agent2 agent3"
  exit 1
fi

VOTE_ID="VOTE-$(date +%Y%m%d%H%M%S)"
DEADLINE=$(date -v+1H -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -d '+1 hour' -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
RESULTS_DIR="$HOME/.myndaix/bridge/state/votes"
mkdir -p "$RESULTS_DIR"

# Initialize vote tracking
echo "{\"vote_id\":\"$VOTE_ID\",\"proposal\":\"$PROPOSAL\",\"voters\":[\"$(IFS=\",\"; echo "${VOTERS[*]}")\"],\"deadline\":\"$DEADLINE\",\"votes\":{}}" > "$RESULTS_DIR/${VOTE_ID}.json"

for AGENT in "${VOTERS[@]}"; do
  INBOX="$HOME/.myndaix/bridge/inbox/$AGENT"
  mkdir -p "$INBOX"
  
  cat > "$INBOX/${VOTE_ID}-vote-request.md" << VOTEEOF
---
from: lobster
to: $AGENT
type: vote
subject: "$PROPOSAL"
vote_id: $VOTE_ID
deadline: $DEADLINE
tier: auto
---

# Vote Request: $VOTE_ID

**Proposal:** $PROPOSAL

**Your vote:** Reply with one of:
- \`approve\` — with 1-2 sentence rationale
- \`reject\` — with 1-2 sentence rationale

**Deadline:** $DEADLINE

Write your response to:
\`~/.myndaix/bridge/inbox/lobster/${AGENT}-${VOTE_ID}-vote.md\`

Keep it short. One vote, one rationale.
VOTEEOF

  echo "Vote request sent to $AGENT"
done

echo ""
echo "Vote ID: $VOTE_ID"
echo "Voters: ${VOTERS[*]}"
echo "Deadline: $DEADLINE"
echo "Track: cat $RESULTS_DIR/${VOTE_ID}.json"
