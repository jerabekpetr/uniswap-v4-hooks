import {
    createPublicClient,
    http,
    parseAbi,
    parseUnits,
    formatUnits,
    defineChain,
} from 'https://esm.sh/viem@2.21.0';

// ---- UI refs ----
const passiveIn = document.getElementById('passive');
const jitIn = document.getElementById('jit');
const swapIn = document.getElementById('swap');
const passiveLabel = document.getElementById('passiveLabel');
const passiveTotalLabel = document.getElementById('passiveTotalLabel');
const jitLabel = document.getElementById('jitLabel');
const jitTotalLabel = document.getElementById('jitTotalLabel');
const swapLabel = document.getElementById('swapLabel');
const runBtn = document.getElementById('runBtn');
const statusEl = document.getElementById('status');
const baselineEl = document.getElementById('baseline');
const canvasA = document.getElementById('chartA');
const canvasB = document.getElementById('chartB');

// ---- Wire slider labels ----
const syncLabels = () => {
    passiveLabel.textContent = passiveIn.value;
    passiveTotalLabel.textContent = String(Number(passiveIn.value) * 2);
    jitLabel.textContent = jitIn.value;
    jitTotalLabel.textContent = String(Number(jitIn.value) * 2);
    swapLabel.textContent = swapIn.value;
};
[passiveIn, jitIn, swapIn].forEach(el => el.addEventListener('input', syncLabels));
syncLabels();

// ---- Constants ----
const ANVIL_CHAIN = defineChain({
    id: 31337,
    name: 'Anvil',
    nativeCurrency: { decimals: 18, name: 'Ether', symbol: 'ETH' },
    rpcUrls: { default: { http: ['http://localhost:8545'] } },
});

const SIMULATOR_ABI = parseAbi([
    'struct ScenarioResult { int256 passiveLPDelta0; int256 passiveLPDelta1; int256 jitDelta0; int256 jitDelta1; uint256 swapAmountOut; }',
    'function runScenario(uint256 passiveToken0, uint256 passiveToken1, uint256 jitToken0, uint256 jitToken1, uint256 swapAmountIn, bool useHook, bool useJIT) external returns (ScenarioResult)',
]);

// ---- Register datalabels plugin ----
if (typeof ChartDataLabels !== 'undefined') Chart.register(ChartDataLabels);

// ---- State ----
let client = null;
let addresses = null;
let chartA = null;
let chartB = null;

// ---- Status helpers ----
function setStatus(msg, kind = 'info') {
    statusEl.textContent = msg;
    statusEl.className = 'status ' + (kind === 'error' ? 'error' : kind === 'ok' ? 'ok' : '');
}

// ---- Init ----
async function init() {
    try {
        const res = await fetch('./addresses.json', { cache: 'no-store' });
        if (!res.ok) throw new Error('addresses.json nenalezen — spusť nejprve deploy skript');
        addresses = await res.json();

        if (addresses.chainId !== 31337)
            throw new Error(`chainId mismatch: ${addresses.chainId} (očekáván 31337)`);

        client = createPublicClient({ chain: ANVIL_CHAIN, transport: http() });

        const chainId = await client.getChainId();
        if (chainId !== 31337) throw new Error('Anvil neběží na localhost:8545');

        const code = await client.getCode({ address: addresses.simulator });
        if (!code || code === '0x') throw new Error('Simulator na uvedené adrese nemá bytecode');

        setStatus('Připraveno. Posuň slidery a klikni.', 'ok');
        runBtn.disabled = false;
    } catch (err) {
        setStatus('Chyba: ' + err.message, 'error');
        console.error(err);
    }
}

runBtn.addEventListener('click', () => runSimulation());

async function runSimulation() {
    if (!client || !addresses) return;
    runBtn.disabled = true;
    setStatus('Spouštím 3 scénáře…', 'info');

    try {
        const passive = parseUnits(passiveIn.value, 18);
        const jit = parseUnits(jitIn.value, 18);
        const swapSize = parseUnits(swapIn.value, 18);

        const call = (useHook, useJIT, jitAmount) => client.simulateContract({
            address: addresses.simulator,
            abi: SIMULATOR_ABI,
            functionName: 'runScenario',
            args: [passive, passive, jitAmount, jitAmount, swapSize, useHook, useJIT],
        });

        const noHookJit   = await call(false, true,  jit).catch(e => { throw Object.assign(e, {_which: 'noHook+JIT'}); });
        const withHookJit = await call(true,  true,  jit).catch(e => { throw Object.assign(e, {_which: 'withHook+JIT'}); });
        const baseline    = await call(true,  false, 0n) .catch(e => { throw Object.assign(e, {_which: 'baseline'}); });

        const fmt = (v) => Number(formatUnits(v, 18));
        const sumDelta = (r, prefix) => fmt(r.result[`${prefix}Delta0`] + r.result[`${prefix}Delta1`]);

        const cols = {
            lpNoHook:    sumDelta(noHookJit,   'passiveLP'),
            jitNoHook:   sumDelta(noHookJit,   'jit'),
            lpWithHook:  sumDelta(withHookJit, 'passiveLP'),
            jitWithHook: sumDelta(withHookJit, 'jit'),
        };
        const baselinePassive = sumDelta(baseline, 'passiveLP');

        baselineEl.textContent =
            `Referenční hodnota (bez JIT útoku): pasivní LP vydělá ≈ ${fmtT(baselinePassive)} na fees.`;

        renderCharts(cols);
        setStatus('Hotovo.', 'ok');
    } catch (err) {
        const which = err._which ? ` [${err._which}]` : '';
        const reason = err.cause?.reason || err.cause?.message || err.details || err.shortMessage || err.message;
        console.error('REVERT' + which, err);
        setStatus(`Simulace selhala${which}: ${reason}`, 'error');
    } finally {
        runBtn.disabled = false;
    }
}

// ---- Formatting ----
function fmtT(v) {
    if (Math.abs(v) < 0.000001) return '≈ 0 T';
    if (Math.abs(v) >= 0.01)    return v.toFixed(4) + ' T';
    return v.toFixed(7) + ' T';
}

function barLabel(v) {
    return (v >= 0 ? 'vyděláno: ' : 'ztráta: ') + fmtT(Math.abs(v));
}

// ---- Shared chart axis options ----
function yAxis() {
    return {
        title: { display: true, text: 'tokeny (token0 + token1)' },
        grid:  { color: (ctx) => ctx.tick?.value === 0 ? '#555' : '#eee' },
    };
}

// ---- Chart A: bez hooku ----
function renderChartA(cols) {
    const data = {
        labels: ['Pasivní LP', 'JIT útočník'],
        datasets: [{
            data: [cols.lpNoHook, cols.jitNoHook],
            backgroundColor: ['rgba(16,185,129,0.8)', 'rgba(239,68,68,0.8)'],
            borderColor:     ['rgba(16,185,129,1)',   'rgba(239,68,68,1)'],
            borderWidth: 1,
        }],
    };
    const options = {
        responsive: true,
        maintainAspectRatio: false,
        layout: { padding: { top: 32 } },
        plugins: {
            legend: { display: false },
            tooltip: { callbacks: { label: (ctx) => barLabel(ctx.parsed.y) } },
            datalabels: {
                anchor: (ctx) => Number(ctx.dataset.data[ctx.dataIndex]) >= 0 ? 'end' : 'start',
                align:  (ctx) => Number(ctx.dataset.data[ctx.dataIndex]) >= 0 ? 'top' : 'bottom',
                formatter: (v) => barLabel(v),
                font: { size: 11, weight: 'bold' },
                color: '#333',
                clamp: false,
            },
        },
        scales: { y: yAxis() },
    };

    if (chartA) { chartA.data = data; chartA.options = options; chartA.update(); }
    else { chartA = new Chart(canvasA, { type: 'bar', data, options }); }
}

// ---- Chart B: s hookem — stacked (fee vrstva + donate/penalizace vrstva) ----
function renderChartB(cols) {
    // Decompose: fee = co by každý dostal bez hooku (stejný swap)
    // donate   = extra co LP dostane navíc díky penalizaci JITu
    // penalty  = co JIT ztratí navíc oproti situaci bez hooku
    const lpFee      = cols.lpNoHook;
    const jitFee     = cols.jitNoHook;
    const lpDonate   = cols.lpWithHook - cols.lpNoHook;
    const jitPenalty = cols.jitWithHook - cols.jitNoHook;

    const data = {
        labels: ['Pasivní LP', 'JIT útočník'],
        datasets: [
            {
                label: 'Poplatky (fees)',
                data: [lpFee, jitFee],
                backgroundColor: ['rgba(16,185,129,0.9)', 'rgba(239,68,68,0.9)'],
                borderColor:     ['rgba(16,185,129,1)',   'rgba(239,68,68,1)'],
                borderWidth: 1,
                datalabels: {
                    anchor: (ctx) => Number(ctx.dataset.data[ctx.dataIndex]) >= 0 ? 'end' : 'start',
                    align:  (ctx) => Number(ctx.dataset.data[ctx.dataIndex]) >= 0 ? 'top' : 'bottom',
                    formatter: (v) => 'fee: ' + fmtT(v),
                    font: { size: 10, weight: 'bold' },
                    color: '#555',
                    offset: 4,
                },
            },
            {
                label: 'Penalizace JIT',
                data: [lpDonate, jitPenalty],
                backgroundColor: ['rgba(5,150,105,0.75)', 'rgba(153,27,27,0.75)'],
                borderColor:     ['rgba(5,150,105,1)',    'rgba(153,27,27,1)'],
                borderWidth: 1,
                datalabels: {
                    anchor: 'center',
                    align: 'center',
                    formatter: (v, ctx) => {
                        const prefix = ctx.dataIndex === 0 ? 'donate: +' : 'penalizace: ';
                        return prefix + fmtT(Math.abs(v));
                    },
                    font: { size: 11, weight: 'bold' },
                    color: '#fff',
                    display: (ctx) => Math.abs(Number(ctx.dataset.data[ctx.dataIndex])) > 0.0001,
                },
            },
        ],
    };

    const options = {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
            legend: { display: true, position: 'top', labels: { boxWidth: 14, font: { size: 11 } } },
            tooltip: {
                callbacks: {
                    label: (ctx) => {
                        const v = ctx.parsed.y;
                        const prefix = ctx.dataset.label;
                        return `${prefix}: ${barLabel(v)}`;
                    },
                },
            },
            datalabels: {},
        },
        scales: {
            x: { stacked: true },
            y: { stacked: true, ...yAxis() },
        },
    };

    if (chartB) { chartB.data = data; chartB.options = options; chartB.update(); }
    else { chartB = new Chart(canvasB, { type: 'bar', data, options }); }
}

function renderCharts(cols) {
    renderChartA(cols);
    renderChartB(cols);
}

init();
