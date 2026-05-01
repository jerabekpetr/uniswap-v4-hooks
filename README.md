# Uniswap v4 Hooks — Bakalářská práce

Dva Uniswap v4 hooky implementované v Solidity s interaktivní frontendovou simulací.

---

## Hooky

### SentinelJITGuardHook

Ochrana proti JIT (Just-In-Time) likviditním útokům. Hook sleduje, ve kterém bloku byla pozice otevřena, a při jejím okamžitém uzavření ve stejném bloku (typický JIT pattern) penalizuje poskytovatele likvidity — odebere část vložených tokenů i nashromážděných poplatků.

**Soubory:** [src/SentinelJITGuardHook.sol](src/SentinelJITGuardHook.sol) · [src/SentinelSimulator.sol](src/SentinelSimulator.sol)

### FlowScoreHook

Dynamický poplatek podle toho, jak swap ovlivňuje rovnováhu poolu (50:50 token0/token1).

- **Toxický swap** (pool se vzdaluje od 50:50): poplatek roste lineárně od BASE\_FEE (0,30 %) až po MAX\_FEE (1,00 %) — čím dál od rovnováhy, tím vyšší penalizace. Část příplatku jde do `feePot`.
- **Benigní swap** (pool se přibližuje k 50:50): poplatek snížen na MIN\_FEE (0,05 %) a navíc cashback z `feePot` úměrný tomu, jak moc byl pool nevyvážený před swapem.

**Soubory:** [src/FlowScoreHook.sol](src/FlowScoreHook.sol) · [src/FlowScoreSimulator.sol](src/FlowScoreSimulator.sol)

---

## Prerekvizity

| Nástroj | Účel | Instalace |
|---|---|---|
| [Foundry](https://getfoundry.sh) | kompilace, testy, lokální chain (`anvil`) | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| [Python 3](https://python.org) | HTTP server pro frontend | součást většiny OS; na Windows `winget install Python.Python.3` |
| [jq](https://jqlang.org) | parsování adres z broadcast JSON | `winget install jqlang.jq` / `brew install jq` / `apt install jq` |
| [Git](https://git-scm.com) | klonování repozitáře | standardně dostupný |

---

## Instalace

```bash
git clone <url-repozitáře>
cd uniswap-v4-hooks
forge install
```

Ověření:

```bash
forge build
forge test
```

---

## Spuštění simulací

Každý hook má připravený skript, který automaticky spustí Anvil, nasadí kontrakty a otevře frontend.

### SentinelJITGuardHook

```bash
./scripts/start-jit.sh
```

Frontend dostupný na `http://localhost:8000/simulation-jit.html`

### FlowScoreHook

```bash
./scripts/start-flow.sh
```

Frontend dostupný na `http://localhost:8000/simulation-flowscore.html`

Ukončení (Ctrl+C) automaticky zastaví i Anvil.

---

## Struktura projektu

```
src/          – zdrojové kódy hooků a simulátorů
test/         – Foundry testy
script/       – deploy skripty (Foundry)
scripts/      – shell skripty pro lokální spuštění
frontend/     – HTML/JS simulace
```
