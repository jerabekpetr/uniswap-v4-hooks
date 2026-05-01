import {
    createPublicClient,
    createWalletClient,
    defineChain,
    formatUnits,
    http,
    parseAbi,
    parseUnits,
} from 'https://esm.sh/viem@2.21.0';
import { privateKeyToAccount } from 'https://esm.sh/viem@2.21.0/accounts';

const liquidityIn = document.getElementById('liquidity');
const swapAmountIn = document.getElementById('swapAmount');
const liquidityLabel = document.getElementById('liquidityLabel');
const swapAmountLabel = document.getElementById('swapAmountLabel');
const initBtn = document.getElementById('initBtn');
const swap0Btn = document.getElementById('swap0Btn');
const swap1Btn = document.getElementById('swap1Btn');
const statusEl = document.getElementById('status');
const poolShareEl = document.getElementById('poolShare');
const poolReservesEl = document.getElementById('poolReserves');
const feePotBalanceEl = document.getElementById('feePotBalance');
const lastDirectionEl = document.getElementById('lastDirection');
const lastFeeEl = document.getElementById('lastFee');
const lastOutEl = document.getElementById('lastOut');
const lastPotInEl = document.getElementById('lastPotIn');
const lastPotOutEl = document.getElementById('lastPotOut');
const lastNoteEl = document.getElementById('lastNote');

const ANVIL_CHAIN = defineChain({
    id: 31337,
    name: 'Anvil',
    nativeCurrency: { decimals: 18, name: 'Ether', symbol: 'ETH' },
    rpcUrls: { default: { http: ['http://localhost:8545'] } },
});

const SIM_ABI = parseAbi([
    'struct LastSwapInfo { bool exists; bool zeroForOne; bool toxic; uint256 amountIn; uint256 feePaid; uint256 feePotAdded; uint256 feePotUsed; uint256 amountOut; }',
    'function poolInitialized() view returns (bool)',
    'function initializePool(uint256 initialLiquidityPerToken) external',
    'function executeSwap(bool zeroForOne, uint256 amountIn) external returns (LastSwapInfo)',
    'function getPoolSnapshot() external view returns (uint256 reserve0, uint256 reserve1, uint256 share0Bps, uint256 share1Bps, uint256 feePotBalance, LastSwapInfo info)',
]);

const ACCOUNT_PK = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

let publicClient = null;
let walletClient = null;
let simulator = null;

const syncLabels = () => {
    liquidityLabel.textContent = liquidityIn.value;
    swapAmountLabel.textContent = Number(swapAmountIn.value).toFixed(2);
};
[liquidityIn, swapAmountIn].forEach((el) => el.addEventListener('input', syncLabels));
syncLabels();

function setStatus(msg, kind = 'info') {
    statusEl.textContent = msg;
    statusEl.className = 'status ' + (kind === 'error' ? 'error' : kind === 'ok' ? 'ok' : '');
}

function fmtT(v) {
    if (Math.abs(v) < 0.000001) return '≈ 0 T';
    if (Math.abs(v) >= 0.01) return v.toFixed(4) + ' T';
    return v.toFixed(7) + ' T';
}

function fmtU(v) {
    return Number(formatUnits(v, 18));
}

function setBusy(busy) {
    const disabled = busy || !simulator;
    initBtn.disabled = disabled;
    swap0Btn.disabled = disabled;
    swap1Btn.disabled = disabled;
}

async function refreshSnapshot() {
    const [reserve0, reserve1, share0Bps, share1Bps, feePotBalance, info] = await publicClient.readContract({
        address: simulator,
        abi: SIM_ABI,
        functionName: 'getPoolSnapshot',
    });

    const r0 = fmtU(reserve0);
    const r1 = fmtU(reserve1);
    poolShareEl.textContent = `Podíl tokenů: token0 ${Number(share0Bps) / 100}% | token1 ${Number(share1Bps) / 100}%`;
    poolReservesEl.textContent = `Rezervy: token0 ${fmtT(r0)} | token1 ${fmtT(r1)}`;
    feePotBalanceEl.textContent = `Aktuální feePot: ${fmtT(fmtU(feePotBalance))}`;

    if (!info.exists) {
        lastDirectionEl.textContent = 'Směr: -';
        lastFeeEl.textContent = 'Fee zaplaceno: -';
        lastOutEl.textContent = 'Obdržel ze swapu: -';
        lastPotInEl.textContent = 'Do feePotu přibylo: -';
        lastPotOutEl.textContent = 'Z feePotu se vyplatilo: -';
        lastNoteEl.textContent = 'Poznámka: Cashback je jen při benigním swapu.';
        return;
    }

    lastDirectionEl.textContent = `Směr: ${info.zeroForOne ? 'token0 -> token1' : 'token1 -> token0'}`;
    lastFeeEl.textContent = `Fee zaplaceno: ${fmtT(fmtU(info.feePaid))}`;
    lastOutEl.textContent = `Obdržel ze swapu: ${fmtT(fmtU(info.amountOut))}`;
    lastPotInEl.textContent = `Do feePotu přibylo: ${fmtT(fmtU(info.feePotAdded))}`;
    lastPotOutEl.textContent = `Z feePotu se vyplatilo: ${fmtT(fmtU(info.feePotUsed))}`;
    if (info.feePotUsed > 0n) {
        const cashbackPct = info.amountIn > 0n
            ? (Number(info.feePotUsed) / Number(info.amountIn) * 100).toFixed(4)
            : '?';
        lastNoteEl.textContent = `Poznámka: Benigní swap čerpal cashback z feePotu (${cashbackPct} %).`;
    } else if (info.toxic) {
        const amtIn = Number(info.amountIn);
        const feePct = amtIn > 0
            ? (Number(info.feePaid) / amtIn * 100).toFixed(4)
            : '?';
        const feePotPct = amtIn > 0
            ? (Number(info.feePotAdded) / amtIn * 100).toFixed(4)
            : '?';
        const lpPct = amtIn > 0
            ? ((Number(info.feePaid) - Number(info.feePotAdded)) / amtIn * 100).toFixed(4)
            : '?';
        lastNoteEl.textContent = `Poznámka: Swap byl toxický (celkové fee ${feePct} % — z toho do feePotu ${feePotPct} %, LP ${lpPct} %).`;
    } else {
        lastNoteEl.textContent = 'Poznámka: Swap byl benigní, ale feePot byl prázdný nebo cashback vyšel ~0.';
    }
}

async function sendTx(functionName, args) {
    const hash = await walletClient.writeContract({
        address: simulator,
        abi: SIM_ABI,
        functionName,
        args,
        chain: ANVIL_CHAIN,
        account: walletClient.account,
    });
    await publicClient.waitForTransactionReceipt({ hash });
}

async function init() {
    try {
        const res = await fetch('./addresses.json', { cache: 'no-store' });
        if (!res.ok) throw new Error('addresses.json nenalezen');
        const addresses = await res.json();
        simulator = addresses.simulator;

        publicClient = createPublicClient({ chain: ANVIL_CHAIN, transport: http() });
        walletClient = createWalletClient({
            chain: ANVIL_CHAIN,
            transport: http(),
            account: privateKeyToAccount(ACCOUNT_PK),
        });

        const chainId = await publicClient.getChainId();
        if (chainId !== 31337) throw new Error('Anvil neběží na localhost:8545');

        const code = await publicClient.getCode({ address: simulator });
        if (!code || code === '0x') throw new Error('Simulator na uvedené adrese nemá bytecode');

        const isInitialized = await publicClient.readContract({
            address: simulator,
            abi: SIM_ABI,
            functionName: 'poolInitialized',
        });

        if (isInitialized) {
            initBtn.disabled = true;
            swap0Btn.disabled = false;
            swap1Btn.disabled = false;
            await refreshSnapshot();
            setStatus('Pool je připraven, můžeš swapovat.', 'ok');
        } else {
            initBtn.disabled = false;
            swap0Btn.disabled = true;
            swap1Btn.disabled = true;
            setStatus('Klikni na Inicializovat pool.', 'ok');
        }
    } catch (err) {
        setStatus('Chyba: ' + err.message, 'error');
        console.error(err);
    }
}

initBtn.addEventListener('click', async () => {
    if (!simulator) return;
    setBusy(true);
    setStatus('Inicializuju pool…');
    try {
        const initialLiquidity = parseUnits(liquidityIn.value, 18);
        await sendTx('initializePool', [initialLiquidity]);
        initBtn.disabled = true;
        swap0Btn.disabled = false;
        swap1Btn.disabled = false;
        await refreshSnapshot();
        setStatus('Pool inicializován.', 'ok');
    } catch (err) {
        const reason = err.cause?.reason || err.cause?.message || err.details || err.shortMessage || err.message;
        setStatus(`Inicializace selhala: ${reason}`, 'error');
        console.error(err);
    } finally {
        setBusy(false);
    }
});

swap0Btn.addEventListener('click', async () => {
    setBusy(true);
    setStatus('Provádím swap token0 -> token1…');
    try {
        const amountIn = parseUnits(swapAmountIn.value, 18);
        await sendTx('executeSwap', [true, amountIn]);
        await refreshSnapshot();
        setStatus('Swap hotov.', 'ok');
    } catch (err) {
        const reason = err.cause?.reason || err.cause?.message || err.details || err.shortMessage || err.message;
        setStatus(`Swap selhal: ${reason}`, 'error');
        console.error(err);
    } finally {
        setBusy(false);
    }
});

swap1Btn.addEventListener('click', async () => {
    setBusy(true);
    setStatus('Provádím swap token1 -> token0…');
    try {
        const amountIn = parseUnits(swapAmountIn.value, 18);
        await sendTx('executeSwap', [false, amountIn]);
        await refreshSnapshot();
        setStatus('Swap hotov.', 'ok');
    } catch (err) {
        const reason = err.cause?.reason || err.cause?.message || err.details || err.shortMessage || err.message;
        setStatus(`Swap selhal: ${reason}`, 'error');
        console.error(err);
    } finally {
        setBusy(false);
    }
});

init();
