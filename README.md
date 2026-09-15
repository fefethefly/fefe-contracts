# FEFE Contracts

**One brain. Many lives. / 同一颗脑，无数种活法。**

Open-source Solidity contracts powering [fefe.market](https://fefe.market) on Robinhood Chain. This repository is published so that anyone can read, verify, and test the exact code that markets on fefe.market run on — before the official FEFE token goes live.

> FEFE / 飞飞是 fefe.market 在 Robinhood Chain 上的官方 Memestock。本仓库开源 fefe.market 市场所使用的全部链上合约与测试，供社区审查与验证。

## What lives here

| Area | Contents |
|---|---|
| `src/v3/` | Current launch system: launchpads, bonding curve, meme token, fee vault, deployers |
| `src/v3/uniswap/` | Uniswap v4 integration: fee hook, graduation handler, swap adapters, router |
| `src/fefe/` | Official FEFE token mechanics (anchor) |
| `src/v2/`, `src/` | Earlier generations kept for history and migration reference |
| `test/` | Foundry test suites — 233 unit tests plus mainnet-fork tests |
| `script/` | Deployment scripts used for the actual deployments listed below |
| `lib/` | Vendored dependencies (forge-std, OpenZeppelin Contracts) for reproducible builds |

### Core components

- **`LaunchpadV3`** — one transaction creates the token (CREATE2, sender-bound salt), the fee vault, and the bonding curve, plus an optional tax-free creator first buy. Quote asset may be ETH or any tokenized stock. Token init code is constant, so creators can mine a vanity address client-side that nobody else can ever deploy to.
- **`DirectLaunchpadV3`** — direct-to-pool launch: 100% of supply is minted to the graduation handler and a Uniswap v4 pool is locked forever at the virtual-quote price. No creation fee, no protocol share, no LP fee.
- **`BondingCurveV3`** — constant-product curve priced in any quote asset, with creator-configurable anti-snipe, an Nth-buy jackpot, and buy/sell taxes.
- **`MemeTokenV3`** — fixed-supply meme token with a multi-asset dividend tracker that streams a stock basket to holders. Deployed with an empty constructor so the CREATE2 init code hash is constant.
- **`FeeVaultV3`** — every unit of tax splits four ways: creator, stock-basket dividends, jackpot, buyback-and-burn.
- **`BarkHookV3`** — Uniswap v4 hook that charges creator-configured taxes plus the per-token protocol share on graduated pools. Fees are taken as swap deltas, never as fee-on-transfer.
- **`UniswapV4GraduationHandlerV3` / `UniswapV4SwapAdapterV3`** — curve graduation into Uniswap v4 and swap routing.
- **`FefeSink`** — collects protocol fees and permissionlessly buys the official FEFE token to burn. The official FEFE book sets `protocolFeeBps = 0`, so the sink is not fed by the official market.
- **`FefeAnchor` / `FefeBuybackHookV3`** — mechanics for the official FEFE token. The official token contract will be announced at unveil; this repository already contains everything that governs it.

## Deployments

All addresses below were verified on-chain (`eth_getCode`) against the public RPCs at publication time. Deployment scripts and pinned codehash checks in `test/` reproduce these deployments.

### Robinhood Chain mainnet (chain ID 4663)

Deployer: [`0x6abe094242e4b92c9856ee3c0f9838533a9df81f`](https://robinhoodchain.blockscout.com/address/0x6abe094242e4b92c9856ee3c0f9838533a9df81f) · Explorer: [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com)

| Contract | Address |
|---|---|
| `LaunchpadV3` | [`0x3cb03a559f83f8ff59af48c043491a3728fdd396`](https://robinhoodchain.blockscout.com/address/0x3cb03a559f83f8ff59af48c043491a3728fdd396) |
| `BarkHookV3` | [`0x9753a4d8df2e7542d0d0b16c36153dfba8f420cc`](https://robinhoodchain.blockscout.com/address/0x9753a4d8df2e7542d0d0b16c36153dfba8f420cc) |
| `FefeSink` | [`0x02d5c85fb1c8a0901c70e5a7e2ee1e169f4f6948`](https://robinhoodchain.blockscout.com/address/0x02d5c85fb1c8a0901c70e5a7e2ee1e169f4f6948) |
| `UniswapV4GraduationHandlerV3` | [`0xb93b42d0eb3ff418dd070a7f239f3922d0ef4011`](https://robinhoodchain.blockscout.com/address/0xb93b42d0eb3ff418dd070a7f239f3922d0ef4011) |
| `UniswapV4SwapAdapterV3` | [`0xbd4556fc59c980542ecd50095bb8396643df05cd`](https://robinhoodchain.blockscout.com/address/0xbd4556fc59c980542ecd50095bb8396643df05cd) |

### Robinhood Chain testnet (chain ID 46630)

Explorer: [explorer.testnet.chain.robinhood.com](https://explorer.testnet.chain.robinhood.com)

| Contract | Address |
|---|---|
| `LaunchpadV3` | [`0x71d493380c5d2518da244367057a074f28b6137a`](https://explorer.testnet.chain.robinhood.com/address/0x71d493380c5d2518da244367057a074f28b6137a) |
| `BarkHookV3` | [`0x36444ca7748c4692d6b22312630dc8d8e03520cc`](https://explorer.testnet.chain.robinhood.com/address/0x36444ca7748c4692d6b22312630dc8d8e03520cc) |
| `UniswapV4GraduationHandlerV3` | [`0xfd4593e8b913bd4941066e6707230ea0d90560d6`](https://explorer.testnet.chain.robinhood.com/address/0xfd4593e8b913bd4941066e6707230ea0d90560d6) |
| `UniswapV4SwapAdapterV3` | [`0x749d5ee410497fb98d40c316b770778c6a371feb`](https://explorer.testnet.chain.robinhood.com/address/0x749d5ee410497fb98d40c316b770778c6a371feb) |

## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies are vendored in `lib/`, so no network install is needed.

```sh
forge build

# Unit tests (no network access required) — the same suite CI runs
forge test --no-match-path 'test/{*Fork*,BarkTestnetSeederV3*}.t.sol'

# Mainnet-fork tests use the public Robinhood Chain RPC by default
forge test --match-path 'test/*Fork*'
```

### Reproducible bytecode

`foundry.toml` pins `solc 0.8.28`, `optimizer_runs = 200`, `bytecode_hash = "none"` and `cbor_metadata = false` for the default profile: `MemeTokenV3` addresses are mined client-side from a constant creation-code hash, so the compiled code — not comments or metadata — determines the deployable address. Building this repository reproduces the deployed bytecode exactly.

## Security

- No secrets in this repository: deployment keys are read from the environment (`$DEPLOYER_KEY`) by the scripts in `script/`, never hardcoded.
- Foundry fork tests pin the codehashes of the external contracts they integrate with (Uniswap v4 periphery), so any change in dependencies breaks the build.
- These contracts are not yet covered by a third-party audit. This repository is published so anyone can review them; audit reports will be linked here when available.

To report a vulnerability, please open a **private security advisory** via this repository's *Security* tab (see [SECURITY.md](SECURITY.md)) rather than opening a public issue.

## License

The contracts in this repository are released under the [MIT License](LICENSE). Vendored dependencies in `lib/` keep their own licenses (forge-std: MIT/Apache-2.0, OpenZeppelin Contracts: MIT).

## Disclaimer

Tokens launched through or traded against these contracts are not cash, equity, or vault claims. Markets on fefe.market reference real-world assets; the tokens themselves carry no redemption right against any underlying. Nothing here is financial advice.
