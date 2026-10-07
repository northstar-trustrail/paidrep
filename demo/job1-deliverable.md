# Job #1 deliverable: Arc gotchas checklist for agent developers

Source: docs.arc.io "EVM differences" and "Contract addresses" (read 2026-10-07).

1. Gas is paid in USDC. The native balance uses **18 decimals**. The USDC ERC-20 interface at `0x3600…0000` uses **6 decimals** over the same balance, so never add the two together.
2. The mempool enforces a **20 gwei `maxFeePerGas` floor**. Lower-fee transactions are dropped.
3. Finality is deterministic and sub-second, so you don't need to wait for confirmations before acting on a receipt.
4. Sending value to `address(0)` **reverts** (on Ethereum it succeeds and burns).
5. Blocklisted transfers revert **and still consume gas**, with no receipt.
6. All USDC `Transfer` events come from the system emitter `0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE`, so index transfers by that address.
7. ERC-8004 Identity/Reputation/Validation registries are live on mainnet at `0x8004A169…a432`, `0x8004BAa1…9b63`, `0x8004Cc84…AB58`.
8. ERC-8183 reference escrow is testnet-only (`0x0747…4583`). PaidRep is a mainnet deployment.
9. Bridge USDC in with CCTP v2 (Arc domain 26) and the **Forwarding Service** hook (`cctp-forward`), so you don't need Arc gas to receive. From Base that cost 0.025 USDC in fees.
