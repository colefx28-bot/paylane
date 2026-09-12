# Paylane

Trustless escrow infrastructure for the agent economy. Non-custodial USDC settlement between AI agents on Base.

## Why This Matters

AI agents are starting to transact with each other — buying data, paying for compute,
settling API calls, coordinating multi-agent workflows. None of that works today without
a trust layer, because agents can't rely on reputation, legal recourse, or chargebacks
the way humans do. Someone has to hold the money honestly while the work gets verified.

**Paylane is that layer.** A non-custodial escrow primitive built specifically for
machine-speed, machine-to-machine payments:

- **Signed intents, not blind trust** — every deal is an EIP-712 signed commitment from
  the paying agent. The contract verifies the signature on-chain before moving a single
  token. No off-chain trust assumption, no custodian holding funds on your behalf.
- **Two settlement modes** — instant (`fundAndSettle`) for atomic, verified-on-completion
  payments, or held escrow (`fund` → `release`) for work that needs a verification window
  before funds move.
- **Built for the rails that matter** — USDC-native, deployed on Base, designed to slot
  into the x402 / agentic-payment stack Coinbase and others are actively building toward.

**Status: live on Base Sepolia testnet.** Contract deployed, full lifecycle (fund, settle,
release, refund) tested end-to-end with real signed transactions — not just unit tests.
Mainnet deployment and security review are the next milestones.

This is early — one contract, no volume, no users yet. What exists is a working,
tested, non-custodial primitive for a payments category that doesn't have an obvious
default winner yet. That's the bet.

## Proof of Work

| Action | Transaction |
|---|---|
| Contract deploy | [`0xc41df935...`](https://sepolia.basescan.org/tx/0xc41df93597b0d7551f5d20e385524a3110db0726c6d06230d39d6c257975d4af) |
| Instant settlement (`fundAndSettle`) | [`0x688e487c...`](https://sepolia.basescan.org/tx/0x688e487c946f2a4cc42f9c9e9aa991ca280994657bd815210edfd5cd55805212) |
| Held escrow (`fund`) | [`0x5421de1b...`](https://sepolia.basescan.org/tx/0x5421de1bf63511bd9565fcd948c2a34e55e365bccba66f0ab128419a1ff8105a) |
| Escrow release | [`0x6ff6482e...`](https://sepolia.basescan.org/tx/0x6ff6482e97ed5415f5bbbb2a6c86017664825837806dda9ed2dab6313efce270) |

**Contract:** `0xe088BF7A912D546fc250c74535E5Ee66d19b8F2d` (Base Sepolia)

## Architecture

- `EscrowVault.sol` — core contract: EIP-712 signed deal intents, tiered fee structure (2.5% under 10 USDC, 1% above), reentrancy-guarded, pausable
- Full test suite including adversarial reentrancy simulation (`MaliciousReentrantToken.sol`)
