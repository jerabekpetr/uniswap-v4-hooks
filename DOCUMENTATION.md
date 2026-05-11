# Technická dokumentace - Uniswap v4 Hooks

> Autor: Petr Jeřábek  
> Verze Solidity: `0.8.30` · EVM: Cancun · Toolchain: Foundry

---

## Obsah

1. [Architektura systému](#1-architektura-systému)
2. [Smart kontrakty](#2-smart-kontrakty)
   - [SentinelJITGuardHook](#sentineljitguardhook)
   - [FlowScoreHook](#flowscorehook)
3. [Hooks - detailní popis](#3-hooks--detailní-popis)
   - [SentinelJITGuardHook](#31-sentineljitguardhook)
   - [FlowScoreHook](#32-flowscorehook)
4. [Baselines](#4-baselines)
5. [Testování](#5-testování)
6. [Deployment](#6-deployment)
7. [Frontend / Simulátor](#7-frontend--simulátor)

---

## 1. Architektura systému

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Uniswap v4 Core                              │
│                                                                     │
│  ┌──────────────────┐       ┌──────────────────────────────────┐    │
│  │   PoolManager    │◄─────►│  PositionManager (ERC-721 NFT)   │    │
│  └────────┬─────────┘       └──────────────────────────────────┘    │
│           │ hook callbacks                                          │
└───────────┼─────────────────────────────────────────────────────────┘
            │
            ├─────────────────────────────────────────┐
            │                                         │
            ▼                                         ▼
┌───────────────────────────┐       ┌────────────────────────────────┐
│   SentinelJITGuardHook    │       │         FlowScoreHook          │
│  afterAddLiquidity        │       │  afterInitialize               │
│  afterRemoveLiquidity     │       │  beforeSwap / afterSwap        │
│  afterSwap                │       │                                │
└───────────────────────────┘       └────────────────────────────────┘
```

### Závislosti knihoven

| Balíček | Použití |
|---------|---------|
| `v4-core` | PoolManager, typy, knihovny |
| `v4-periphery` | PositionManager, BaseHook, HookMiner |
| `hookmate` | IUniswapV4Router04 (swap router) |
| `permit2` | Schvalování tokenů bez on-chain approve |
| `solmate` | MockERC20 pro testy |
| `forge-std` | Test, Script, cheat codes |

---

## 2. Smart kontrakty

### SentinelJITGuardHook

**Soubor:** [src/SentinelJITGuardHook.sol](src/SentinelJITGuardHook.sol)

Hook, který odrazuje od JIT (just-in-time) likviditních útoků tím, že při předčasném výběru likvidity (před uplynutím `GRACE_BLOCKS`) aplikuje adaptivní penalizaci. Penalizované tokeny jsou přes `donate()` vráceny zpět do poolu, kde připadnou aktuálním LP podle účetního modelu Uniswap v4.

#### Konstanty

| Konstanta | Hodnota | Popis |
|-----------|---------|-------|
| `BASE_PENALTY_BPS` | 3 000 (30 %) | Základní penalizace na počátku (blok 0) |
| `MAX_PENALTY_BPS` | 3 000 (30 %) | Horní limit výsledné penalizace |
| `GRACE_BLOCKS` | 20 | Hranice, po které věkový faktor klesne na nulu |

#### Datové struktury

```solidity
struct PositionData {
    uint48  addedAtBlock;      // blok posledního vkladu
    int24   tickLower;         // spodní tick pozice
    int24   tickUpper;         // horní tick pozice
    int24   entryTick;         // tick poolu při vkladu
    uint128 liquidity;         // aktuální sledovaná likvidita
    uint128 cumulativeAdded;   // celkově přidaná likvidita
    uint128 cumulativeRemoved; // celkově odebraná likvidita
}

struct PoolVolatilityState {
    bool    initialized;       // true po prvním swapu
    int24   lastTick;          // tick po posledním swapu
    uint256 sigmaX18;          // EMA absolutního pohybu ticku (×1e18, 80/20 decay)
    uint256 lastUpdatedBlock;  // blok poslední aktualizace
}
```

#### Klíčové funkce

| Funkce | Viditelnost | Popis |
|--------|-------------|-------|
| `_afterAddLiquidity(...)` | `internal override` | Zaznamenává vklad - ukládá addedAtBlock, ticky, likviditu |
| `_afterRemoveLiquidity(...)` | `internal override` | Vypočítá a aplikuje penalizaci; čistí metadata po plném výběru |
| `_afterSwap(...)` | `internal override` | Aktualizuje EMA sigma pro daný pool |
| `positions(poolId, posKey)` | `public` | Vrací PositionData pro danou pozici |
| `volatility(poolId)` | `public` | Vrací PoolVolatilityState pro daný pool |

**Povolené callbacky:**
`afterAddLiquidity`, `afterRemoveLiquidity`, `afterRemoveLiquidityReturnDelta`, `afterSwap`

---

### FlowScoreHook

**Soubor:** [src/FlowScoreHook.sol](src/FlowScoreHook.sol)

Hook, který penalizuje toxický (jednostranný) order flow vyšším poplatkem a odměňuje benigní swappery cashbackem z nashromážděného fee potu. Toxicita se určuje podle toho, zda swap zhoršuje inventářní nevyváženost poolu.

#### Konstanty

| Konstanta | Hodnota | Popis |
|-----------|---------|-------|
| `BASE_FEE` | 3 000 (0,30 %) | Základní LP poplatek |
| `MAX_FEE` | 10 000 (1,00 %) | Maximální poplatek za silně toxický swap |
| `MIN_FEE` | 500 (0,05 %) | Minimální poplatek za benigní swap |
| `MAX_CASHBACK_BPS` | 35 (0,35 %) | Maximální cashback jako procento velikosti swapu |
| `SIZE_SCALE` | 10e18 | Referenční velikost swapu pro normalizaci |

#### Datové struktury

```solidity
struct PoolFlowState {
    int24   emaTick;             // EMA ticku poolu
    int256  signedFlowEma;       // EMA signovaného flow (kladné = zeroForOne tlak)
    int256  inventoryImbalance;  // signovaná nevyváženost zásoby
    uint256 feePot0;             // fee pot v token0
    uint256 feePot1;             // fee pot v token1
    uint256 lastUpdated;         // timestamp posledního swapu
    uint256 imbalanceScale;      // scale konfigurovaný vlastníkem
    uint48  bonusBlock;          // blok posledního cashbacku
    uint256 blockBonusPaid;      // celkový cashback v bonusBlock
}
```

#### Klíčové funkce

| Funkce | Viditelnost | Popis |
|--------|-------------|-------|
| `setImbalanceScale(key, scale)` | `external onlyOwner` | Nastaví sensitivity fee na imbalance pro daný pool |
| `_afterInitialize(...)` | `internal override` | Inicializuje PoolFlowState při vytvoření poolu |
| `_beforeSwap(...)` | `internal override` | Vypočítá toxicitu, nastaví dynamický poplatek, sbírá surcharge (exactInput) |
| `_afterSwap(...)` | `internal override` | Aktualizuje EMA stav, vypořádá odložené příspěvky (exactOutput), vyplácí cashback |
| `_computeToxicity(state, params, pid)` | `internal view` | Vrátí `(toxicityRatio, isToxic)` na základě 3-složkového score |
| `_computeCashbackBps(imbalanceBefore, imbalanceAfter, scale)` | `internal pure` | Cashback BPS úměrný snížení imbalance |
| `flowState(poolId)` | `public` | Vrací celý PoolFlowState |

**Povolené callbacky:**
`afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`

---
## 3. Hooky - detailní popis

### 3.1 SentinelJITGuardHook

#### Ekonomická intuice

JIT (just-in-time) útok spočívá v tom, že útočník přidá úzkou likviditu těsně před velkým swapem (aby zachytil poplatky) a odebere ji ihned po swapu. Tím, že snižuje podíl fee, který by jinak získali pasivní LP.

SentinelJITGuardHook tento vzor finančně trestá adaptivní penalizací složenou z několika faktorů, jejichž součin zajišťuje, že pozice typické pro JIT likviditu nesou vyšší penalizaci, zatímco legitimní LPs s širokými, starými pozicemi nejsou postiženi.

#### Penalizační vzorec

```
penaltyBps = BASE_PENALTY_BPS × ageFactor × widthFactor × activeFactor + volBoostBps
```

| Faktor | Popis |
|--------|-------|
| `ageFactor` | 100 % při věku 0, lineárně klesá na 0 % při `GRACE_BLOCKS` |
| `widthFactor` | 100 % pro šířku ≤ `REFERENCE_WIDTH_TICKS`; šírší pozice mají nižší faktor |
| `activeFactor` | 100 % pokud je tick v rozsahu; 0 % pokud vzdálenost ≥ `ACTIVE_DISTANCE_TICKS` |
| `volBoostBps` | Lineárně až `MAX_VOL_BOOST_BPS` podle EMA sigma poolu |

Procentní penalizace se aplikuje na hodnotu odebírané likvidity. Pokud je penalizace nenulová, nashromážděné fee jsou odebrány celé. Penalizované tokeny jsou odeslány zpět do poolu přes `poolManager.donate()`.

#### Lifecycle callbacků

```
[LP add]
  └─► afterAddLiquidity
        └─► uloží PositionData (addedAtBlock, ticky, likvidita)
            (opakované add resetuje hodiny - addedAtBlock = block.number)

[Swap]
  └─► afterSwap
        └─► aktualizuje EMA sigma (rolling volatility)

[LP remove]
  └─► afterRemoveLiquidity
        ├─► zjistí věk pozice (block.number - addedAtBlock)
        ├─► vypočítá penaltyBps ze 4 faktorů
        ├─► emituje PenaltyDecision (vždy - i při nulové penalizaci)
        ├─► aktualizuje PositionData (nebo maže při plném výběru)
        ├─► pokud penaltyBps > 0: poolManager.donate(penalty0, penalty1)
        └─► vrací hookDelta = (penalty0, penalty1) - LP obdrží o tolik méně
```

#### Anti-gaming mechanismy

- **Opakovaný vklad resetuje čas** - každé `afterAddLiquidity` nastaví `addedAtBlock = block.number`, takže JIT útočník nemůže "stárnout" pozici malými doplňky.
- **Faktor šířky** - JIT útočník typicky používá úzký range; pasivní LP s full-range pozicí má widthFactor blízký nule, tedy téměř nulovou penalizaci i při okamžitém výběru.
- **Faktor vzdálenosti** - Pozice mimo aktivní rozsah (out-of-range) není relevantní pro JIT útok a nemá být trestána.
- **Volatility boost** - Při vysoké volatilitě (kdy jsou JIT zisky největší) je penalizace automaticky vyšší.

---

### 3.2 FlowScoreHook

#### Ekonomická intuice

Toxický order flow poškozuje pasivní LP přes adverse selection. FlowScoreHook:
1. **Detekuje toxicitu** - swap je toxický, pokud zhoršuje inventářní nevyváženost poolu.
2. **Penalizuje** - toxické swapy platí vyšší dynamický poplatek (až 1 %).
3. **Buduje fee pot** - 50 % surchargu (rozdílu nad BASE_FEE) je uloženo do per-pool rezervy.
4. **Odměňuje** - benigní swapy (snižují imbalance) dostávají cashback z fee potu.

#### Composite toxicity score

Score je vážený průměr tří sub-složek (0–100 %):

```
compositeBps = (sizeScore × 40 % + flowScore × 30 % + deviationScore × 30 %)

sizeScore      = min(swapSize / SIZE_SCALE, 1)
flowScore      = EMA signed flow × alignment s aktuálním swapem
deviationScore = |currentTick − emaTick| / DEVIATION_SCALE_TICKS  (capped at 1)

fee = BASE_FEE + (MAX_FEE − BASE_FEE) × toxicityRatio / 100   [toxický swap]
fee = MIN_FEE                                                 [benigní swap]
```

#### Lifecycle callbacků

```
[Pool initialize]
  └─► afterInitialize
        └─► inicializuje PoolFlowState (emaTick = počáteční tick, vše nulové)

[Swap - exactInput]
  └─► beforeSwap
        ├─► _computeToxicity → (ratio, isToxic)
        ├─► emituje SwapFeeDecision
        ├─► pokud toxický: poolManager.take(inputToken, contribution)
        │    → uloží do feePot, nastaví BeforeSwapDelta
        └─► vrátí fee | OVERRIDE_FEE_FLAG

  └─► afterSwap
        ├─► aktualizuje emaTick, signedFlowEma, inventoryImbalance
        ├─► pokud benigní + podmínky anti-gaming splněny:
        │    └─► _computeCashbackBps → cashback = swapSize × cashbackBps
        │         → _settleToPoolManager → vrátí cashback swapperovi
        └─► emituje CashbackPaid

[Swap - exactOutput]
  └─► beforeSwap  → uloží contribution do pendingContribution, nenastavuje BeforeSwapDelta
  └─► afterSwap   → sbírá deferred contribution, pak jako exactInput
```

#### Anti-gaming mechanismy cashbacku

| Mechanismus | Konstanta | Popis |
|-------------|-----------|-------|
| Minimální velikost swapu | `MIN_CASHBACK_TRADE_SIZE = 1e16` | Mikroswappy cashback nedostanou |
| Per-address cooldown | Mapování `lastBonusBlock` | Každá adresa dostane cashback max 1× za blok |
| Per-block cap | `MAX_BLOCK_CASHBACK_BPS_OF_POT = 20 %` | Celkový cashback v jednom bloku nepřekročí 20 % potu |
| Minimální rezerva | `MIN_FEE_POT_RESERVE = 1e15` | Pot nesmí klesnout pod tuto hodnotu |
| Imbalance-proportional | `_computeCashbackBps` | Cashback je vyšší, čím větší imbalanci swap vyřeší |

#### Správa fee potu

- `_increaseFeePot(state, token0, amount)` - přičte do příslušného sub-potu
- `_decreaseFeePot(state, token0, amount)` - odečte, minimum je 0
- `_getFeePot(state, token0)` - čtecí přístup
- Fee poty jsou **per-pool** a **per-token** (feePot0 a feePot1 jsou oddělené)

---

## 4. Baselines

Oba baseline hooky slouží jako jednoduchá referenční implementace v gas benchmarcích a v konceptuálních testech.

### FlatTimelockWithdrawalFeeHook

**Funkce:** Nejjednodušší možná ochrana - každý výběr před vypršením timelocku stojí fixních 30 % vložené likvidity plus veškeré nashromážděné fees.

**Výhody vs. Sentinel:**
- Velmi nízký gas overhead
- Snadná předvídatelnost pro LP

**Nevýhody:**
- Nediskriminuje mezi JIT útočníkem a legitimním LP, který potřebuje likviditu
- Faktor šířky, vzdálenosti ani volatility není zohledněn

### SimpleVolatilityFeeHook

**Funkce:** Při vyšší volatilitě je riziko adverse selection vyšší → pool si účtuje vyšší poplatek.

**Vzorec:**
```
sigmaX18 = (80 × sigmaX18 + 20 × |tickMove| × 1e18) / 100   // 80/20 EMA
fee = BASE_FEE + (MAX_FEE − BASE_FEE) × min(sigmaX18, VOL_SCALE) / VOL_SCALE
```

**Výhody vs. FlowScore:**
- Velmi nízká složitost
- Předvídatelné chování

**Nevýhody:**
- Nezdůrazňuje směr flow - benigní swapy v průběhu volatilního trhu platí stejně jako toxické
- Žádný fee pot, žádný cashback mechanismus

---

## 5. Testování

Testovací sada je implementována ve Foundry (Forge). Všechny testy se spouštějí příkazem `forge test`.

### Přehled testovacích souborů

| Soubor | Typ | Popis |
|--------|-----|-------|
| `test/SentinelJITGuardHook.t.sol` | Unit, Integration, Fuzz | Testy penalizačního hooků |
| `test/FlowScoreHook.t.sol` | Unit, Integration, Fuzz | Testy fee/cashback hooků |
| `test/SentinelJITGuardHook.invariant.t.sol` | Invariant | Invariantní testy Sentinel |
| `test/FlowScoreHook.invariant.t.sol` | Invariant | Invariantní testy FlowScore |
| `test/FlatTimelockBaselineHook.t.sol` | Integration | Testy baseline timelock hooku |
| `test/SimpleVolatilityBaselineHook.t.sol` | Integration | Testy baseline volatility hooku |
| `test/SentinelSimulator.t.sol` | Integration | End-to-end JIT scénáře přes Simulator |
| `test/FlowScoreSimulator.t.sol` | Integration | End-to-end scénáře přes FlowScoreSimulator |
| `test/GasBenchmark.t.sol` | Gas benchmark | Porovnání gas nákladů všech hooků |
| `test/utils/BaseTest.sol` | Pomocný | Základní deploy infrastruktura |
| `test/utils/libraries/EasyPosm.sol` | Pomocný | Obal PositionManageru pro snadnější testy |

### Testovací strategie

#### Unit testy (SentinelJITGuardHook.t.sol, FlowScoreHook.t.sol)

Ověřují konkrétní vlastnosti jednoho kontraktu v izolaci:

- `test_InitialState()` - FlowScore stav po `afterInitialize` je nulový
- `test_PositionTrackedOnAdd()` - Sentinel ukládá `addedAtBlock` správně
- `test_Unit_PoolIsolation()` - data jednoho poolu se neprojeví v jiném
- `test_Unit_FeePot_ScalesWithSwapSize()` - větší toxický swap = více do fee potu
- `test_Unit_NoRebate_EmptyFeePot()` - cashback z prázdného potu je nulový
- `test_FlowScore_SetImbalanceScale_OnlyOwner()` - access control na `setImbalanceScale`

#### Integration testy

End-to-end scénáře zapojující PoolManager, PositionManager a SwapRouter:

- `test_JIT_SameBlock_PenaltyApplied()` - penalizace ve stejném bloku odpovídá `BASE_PENALTY_BPS`
- `test_Sentinel_Penalty_DecreasesWithAge()` - starší pozice nese menší penalizaci
- `test_Sentinel_NarrowRangePenaltyGreaterThanWideRange()` - úzký range penalizován více
- `test_Sentinel_ActiveRangePenaltyGreaterThanInactiveRange()` - in-range více než out-of-range
- `test_Sentinel_HighVolatilityBoost()` - po swapech je sigmaX18 > 0 a volBoostBps > 0
- `test_BenignSwap_GetsCashback()` - po toxickém swapu dostane benigní swap cashback
- `test_FlowScore_PerAddressCooldown_SameBlock()` - druhý cashback stejné adresy ve stejném bloku je blokován
- `test_FlowScore_SplitOrderGaming_CapLimitsExtraction()` - split-order attack je omezen block capem a rezervou
- `test_FlowScore_ExactOutput_BothDirections()` - exactOutput path správně odkládá a následně sbírá surcharge

#### Fuzz testy

Parametrizované testy s náhodným vstupem (256 runs):

- `test_Fuzz_PenaltyNeverExceedsDelta(uint128 liquidity)` - penalizace nepřekročí vloženou likviditu
- `test_Fuzz_NoPenaltyAfterGracePeriod(uint128, uint256)` - full-range LP bez penalizace po uplynutí grace období
- `test_Fuzz_Remove_NoNegativeAccounting(uint128)` - hook nikdy nerevertuje bez ohledu na likviditu
- `test_Fuzz_FeePot_NeverUnderflows(uint256, uint256)` - fee pot nikdy nepodteče
- `test_Fuzz_TotalRebates_NeverExceedSurcharge(uint256, uint256)` - celkový cashback ≤ fee pot

#### Invariantní testy

Fuzzer (64 runs, depth 128) volá handler funkce v náhodném pořadí a po každém volání ověřuje invarianty:

**SentinelJITGuardHookInvariantTest:**
- `invariant_Sentinel_StateSafety` - `cumulativeRemoved ≤ cumulativeAdded`, `liquidity ≤ cumulativeAdded`
- `invariant_Sentinel_PoolIsolation` - klíče jednoho poolu se nevyskytují v jiném
- `invariant_Sentinel_MaxPenaltyBound` - `BASE_PENALTY_BPS ≤ MAX_PENALTY_BPS`

**FlowScoreHookInvariantTest:**
- `invariant_FlowScore_FeePotsNeverUnderflow_AndCapRespected` - fee poty zůstávají ohraničené, block cap a reserve guard jsou dodrženy
- `invariant_FlowScore_SameSenderCannotClaimTwiceSameBlock` - stejná adresa nedostane cashback 2× za blok
- `invariant_FlowScore_OnlyOwnerCanChangeScale` - owner zůstává správně nastaven

#### Gas benchmarky (GasBenchmark.t.sol)

Srovnání gas nákladů operací mezi hooky:

| Test | Co měří |
|------|---------|
| `test_Gas_AddLiquidity_SentinelVsFlatTimelock` | addLiquidity: vanilla vs. Sentinel vs. FlatTimelock |
| `test_Gas_RemoveLiquidity_SentinelVsFlatTimelock` | decreaseLiquidity po 1 bloku |
| `test_Gas_Swap_SentinelVsFlatTimelock` | swap: vanilla vs. Sentinel vs. FlatTimelock |
| `test_Gas_Swap_FlowScoreVsSimpleVolatility` | swap: vanilla vs. FlowScore vs. SimpleVol |
| `test_Gas_AddLiquidity` | Agregovaný benchmark všech 5 variant |

### Pomocné utility

**`test/utils/BaseTest.sol`** - dědí z `Test` a `Deployers`; provádí deployment V4 artefaktů (PoolManager, PositionManager, SwapRouter, Permit2) a přiděluje debug labely.

**`test/utils/libraries/EasyPosm.sol`** - wrapping `IPositionManager` s jednoduchým API: `mint(...)`, `increaseLiquidity(...)`, `decreaseLiquidity(...)`, `burn(...)`. Automaticky schvaluje Permit2 a nastavuje deadline.

---

## 6. Deployment

### Předpoklady

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Klonuj repozitář a inicializuj submoduly
git clone https://github.com/jerabekpetr/uniswap-v4-hooks
cd uniswap-v4-hooks
forge install

# Verifikace
forge build
forge test
```

### Konfigurace (foundry.toml)

```toml
[profile.default]
solc_version   = "0.8.30"
evm_version    = "cancun"
via_ir         = true          # potřeba pro komplexní hooky
ffi            = true          # skripty čtou/zapisují JSON soubory
fs_permissions = [
    {access = "read-write", path = ".forge-snapshots/"},
    {access = "read-write", path = "./frontend/"}
]

[invariant]
runs  = 64
depth = 128
```

### Spuštění testů

```bash
# Všechny testy
forge test

# S výstupem gas hodnot
forge test -vv

# Konkrétní testovací soubor
forge test --match-path test/SentinelJITGuardHook.t.sol

# Konkrétní test
forge test --match-test test_JIT_SameBlock_PenaltyApplied -vvv

# Pouze invariantní testy
forge test --match-path test/*.invariant.t.sol
```

### Automatizovaný start
Oba bash skripty v `scripts/` automatizují celý deployment workflow a pustí frontend demo aplikaci:

```bash
# Spustí Sentinel JIT simulátor (Anvil + deploy + frontend server)
./scripts/start-jit.sh

# Spustí FlowScore simulátor (Anvil + deploy + frontend server)
./scripts/start-flow.sh
```

Skripty:
1. Zastaví případný starý Anvil na portu 8545
2. Spustí nový Anvil (`--silent`)
3. Nasadí V4 infrastrukturu
4. Nasadí hook
5. Nasadí simulátor
6. Spustí Python HTTP server (`frontend/server.py`) na portu 8000

Po spuštění je frontend dostupný podle spuštěného skriptu:
* Sentinel: http://localhost:8000/simulation-sentinel.html
* FlowScore: http://localhost:8000/simulation-flowscore.html

Stisknutím `Ctrl+C` se korektně ukončí jak server, tak Anvil.

---

## 7. Frontend / Simulátor

Webový frontend umožňuje interaktivní vizualizaci JIT útoku a FlowScore mechanismu bez nutnosti psát kód.

### Struktura

```
frontend/
├── simulation-sentinel.html    # Sentinel JIT vizualizace
├── simulation-flowscore.html   # FlowScore vizualizace
├── main.js                     # Logika pro Sentinel simulátor
├── flowscore-main.js           # Logika pro FlowScore simulátor
├── styles.css                  # Sdílené styly
├── server.py                   # Python HTTP server (bez cache)
├── addresses.json              # Vygenerováno deploy skriptem - adresy kontraktů
├── v4-addresses.json           # Vygenerováno 00_DeployV4 - V4 infrastruktura
├── hook-sentinel.json          # Adresa Sentinel hooku
└── hook-flow.json              # Adresa FlowScore hooku
```

### Sentinel JIT Simulátor

**Knihovny:** Viem 2.21, Chart.js, chartjs-plugin-datalabels - vše načítáno z CDN.

**UI ovládání:**
- Slider `passive` - množství tokenů pasivního LP
- Slider `jit` - množství tokenů JIT útočníka
- Slider `swap` - velikost swapu

**Workflow:**

Po kliknutí na „Spustit simulaci“ se paralelně zavolají 3 RPC simulace přes `client.simulateContract()`:

| Scénář | `useHook` | `useJIT` | Popis |
|--------|-----------|----------|-------|
| `noHook+JIT` | `false` | `true` | JIT útok bez ochrany |
| `withHook+JIT` | `true` | `true` | JIT útok s Sentinel hookem |
| `baseline` | `true` | `false` | Referenční scénář, bez útoku |

**Vizualizace:**

- **Graf A (bez hooku):** Sloupcový graf - pasivní LP (zelená) vs. JIT útočník (červená) - bez ochrany
- **Graf B (s hookem):** Složený sloupcový graf - vrstva fees + vrstva penalizace/donace - viditelný přesun hodnoty od JIT útočníka k pasivnímu LP

### FlowScore Simulátor

Vizualizuje fee pot dynamiku a cashback mechanismus:
- Sloupcové grafy porovnávají fee poty před/po sériích swapů
- Sleduje průběh `signedFlowEma`, `inventoryImbalance` a fee rozhodnutí


> **Poznámka:** Frontend komunikuje výhradně přes read-only `eth_call` (simulateContract) - nepodepisuje žádné transakce, nevyžaduje MetaMask ani jiné peněženky.
