#!/usr/bin/env bash
# Deploy ERC-8183 escrow (UUPS proxy) + PaidReputationHook to Arc mainnet.
# env: PRIVATE_KEY (deployer = admin = treasury), ARC_RPC (default https://rpc.mainnet.arc.io)
set -euo pipefail
RPC=${ARC_RPC:-https://rpc.mainnet.arc.io}
USDC=0x3600000000000000000000000000000000000000      # Arc USDC ERC-20 interface (6 decimals)
IDENTITY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432  # ERC-8004 IdentityRegistry (Arc mainnet)
REPUTATION=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63 # ERC-8004 ReputationRegistry (Arc mainnet)
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
dep() { local c=$1; shift; forge create "$c" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --json ${1:+--constructor-args} "$@" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"; }
IMPL=$(dep contracts/ERC8183.sol:ERC8183)
INIT=$(cast calldata "initialize(address,address)" "$ME" "$ME")
PROXY=$(dep lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy "$IMPL" "$INIT")
HOOK=$(dep contracts/hooks/PaidReputationHook.sol:PaidReputationHook "$PROXY" "$IDENTITY" "$REPUTATION" 6)
cast send "$PROXY" "setPaymentTokenAllowed(address,bool)" "$USDC" true --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$PROXY" "setHookWhitelist(address,bool)" "$HOOK" true --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
mkdir -p deployments
cat > deployments/arc-mainnet.json <<JSON
{
  "chainId": 5042,
  "escrow": "$PROXY",
  "escrowImplementation": "$IMPL",
  "hook": "$HOOK",
  "usdc": "$USDC",
  "identityRegistry": "$IDENTITY",
  "reputationRegistry": "$REPUTATION",
  "admin": "$ME"
}
JSON
cat deployments/arc-mainnet.json
