/*!
 * components/tax-calculator.js
 * 遺產稅與預留稅源槓桿試算器（原生 JS、零依賴）
 * ---------------------------------------------------------------------------
 * 用法：
 *   <div id="taxCalcMount"></div>
 *   <script src="./components/tax-calculator.js"></script>
 *   <script>EstateTaxCalculator.mount(document.getElementById('taxCalcMount'));</script>
 *
 * 計算結果會以 CustomEvent('estate:tax-change') 廣播，供頁面彙整摘要／匯出 PDF。
 */
(function (global) {
  'use strict';

  var STORE_KEY = 'estate_planning_tax_v1';

  /* ---------- 現行遺產稅常數（單位：元） ---------- */
  var CONST = {
    EXEMPT: 13330000, // 免稅額 1,333 萬
    SPOUSE: 5530000, // 配偶扣除額 553 萬
    CHILD: 560000, // 直系血親卑親屬每人 56 萬
    PARENT: 1380000, // 父母每人 138 萬
    FUNERAL: 1380000, // 喪葬費扣除額 138 萬
    TIER1_CAP: 50000000, // 5,000 萬
    TIER2_CAP: 100000000, // 1 億
    RATE1: 0.1,
    RATE2: 0.15,
    RATE3: 0.2,
    SALE_COST_RATE: 0.06, // 不動產處分成本假設：仲介＋代書＋稅費約 6%
    AMT_DEATH_EXEMPT: 37400000, // 所得基本稅額條例 §12：每申報戶全年死亡給付 3,740 萬
    AMT_BASE_EXEMPT: 7500000, // 所得基本稅額條例 §13：基本所得額免稅額 750 萬
    AMT_RATE: 0.2 // 基本稅額稅率 20%
  };

  var DEFAULTS = {
    assets: 60000000, // 6,000 萬
    realEstateRatio: 60,
    spouse: true,
    children: 2,
    parents: 0,
    funeral: true,
    insurance: 3000000, // 300 萬
    premium: 150000, // 年繳保費 15 萬
    beneficiaryNamed: true, // 受益人已指定（姓名、順位、比例）
    amtApplies: true // 受益人≠要保人 → 死亡給付計入基本所得額，適用 3,740 萬額度
  };

  var MAX = { assets: 30000, insurance: 20000, premium: 500 };

  /* ---------- 小工具 ---------- */
  function clamp(n, min, max) {
    return Math.min(max, Math.max(min, n));
  }

  function toNumber(v, fallback) {
    var n = Number(v);
    return isFinite(n) ? n : fallback;
  }

  function toWan(amount) {
    return Math.round(amount / 10000);
  }

  function fmt(n) {
    return Math.round(toNumber(n, 0)).toLocaleString('zh-TW');
  }

  function fmtWan(amount, digits) {
    var d = typeof digits === 'number' ? digits : 1;
    return (amount / 10000).toLocaleString('zh-TW', { maximumFractionDigits: d });
  }

  function pct(ratio) {
    var v = ratio * 100;
    return (v >= 100 ? v.toFixed(0) : v.toFixed(1).replace(/\.0$/, '')) + '%';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- 純計算（可獨立測試） ---------- */
  function calculate(input) {
    var s = {};
    Object.keys(DEFAULTS).forEach(function (k) {
      s[k] = input && input[k] !== undefined ? input[k] : DEFAULTS[k];
    });

    var assets = Math.max(0, toNumber(s.assets, DEFAULTS.assets));
    var insurance = Math.max(0, toNumber(s.insurance, DEFAULTS.insurance));
    var premium = Math.max(0, toNumber(s.premium, DEFAULTS.premium));
    var spouse = s.spouse ? CONST.SPOUSE : 0;
    var childrenCount = clamp(Math.round(toNumber(s.children, 0)), 0, 10);
    var parentsCount = clamp(Math.round(toNumber(s.parents, 0)), 0, 2);
    var children = childrenCount * CONST.CHILD;
    var parents = parentsCount * CONST.PARENT;
    var funeral = s.funeral ? CONST.FUNERAL : 0;
    var deduction = spouse + children + parents + funeral;

    var beneficiaryNamed = s.beneficiaryNamed !== false;
    /* 未指定受益人時，死亡給付歸入遺產，無「受益人≠要保人」適用問題 */
    var amtApplies = beneficiaryNamed && s.amtApplies !== false;
    var insuranceInEstate = beneficiaryNamed ? 0 : insurance;
    var estateAssets = assets + insuranceInEstate;

    function taxOn(total) {
      var net = Math.max(0, total - CONST.EXEMPT - deduction);
      var tier1 = Math.min(net, CONST.TIER1_CAP);
      var tier2 = Math.min(
        Math.max(net - CONST.TIER1_CAP, 0),
        CONST.TIER2_CAP - CONST.TIER1_CAP
      );
      var tier3 = Math.max(net - CONST.TIER2_CAP, 0);
      var parts = [
        { label: '10%', rate: CONST.RATE1, base: tier1, tax: tier1 * CONST.RATE1 },
        { label: '15%', rate: CONST.RATE2, base: tier2, tax: tier2 * CONST.RATE2 },
        { label: '20%', rate: CONST.RATE3, base: tier3, tax: tier3 * CONST.RATE3 }
      ];
      var tax = parts.reduce(function (sum, p) {
        return sum + p.tax;
      }, 0);
      return { net: net, tax: tax, tiers: parts };
    }

    var main = taxOn(estateAssets);
    var namedOn = taxOn(assets);
    var unnamedOn = taxOn(assets + insurance);
    var net = main.net;
    var tax = main.tax;
    var parts = main.tiers;
    var estateTaxSaving = unnamedOn.tax - namedOn.tax;

    /* 最低稅負：受益人≠要保人時，死亡給付每申報戶 3,740 萬內免計入基本所得額 */
    var amtIncluded = amtApplies
      ? Math.max(0, insurance - CONST.AMT_DEATH_EXEMPT)
      : 0;
    var amtBase = Math.max(0, amtIncluded - CONST.AMT_BASE_EXEMPT);
    var amtTax = amtBase * CONST.AMT_RATE;
    var amtQuotaRate = amtApplies ? insurance / CONST.AMT_DEATH_EXEMPT : 0;
    var amtRemain = amtApplies
      ? Math.max(0, CONST.AMT_DEATH_EXEMPT - insurance)
      : 0;

    /* 稅源覆蓋以「合計稅負＝遺產稅＋基本稅額」計算，否則會低估實際缺口 */
    var totalTax = tax + amtTax;
    var coverage = totalTax > 0 ? insurance / totalTax : insurance > 0 ? 1 : 0;
    var gap = Math.max(0, totalTax - insurance);
    var surplus = Math.max(0, insurance - totalTax);
    var leverage = premium > 0 ? insurance / premium : 0;

    var ratio = clamp(toNumber(s.realEstateRatio, DEFAULTS.realEstateRatio), 0, 100);
    var realEstate = assets * (ratio / 100);
    var saleCost = realEstate * CONST.SALE_COST_RATE;
    var leverageSaving = premium > 0 ? saleCost - premium : 0;

    return {
      inputs: {
        assets: assets,
        insurance: insurance,
        premium: premium,
        spouse: !!s.spouse,
        children: childrenCount,
        parents: parentsCount,
        funeral: !!s.funeral,
        realEstateRatio: ratio,
        beneficiaryNamed: beneficiaryNamed,
        amtApplies: amtApplies
      },
      exempt: CONST.EXEMPT,
      deduction: deduction,
      deductionDetail: {
        spouse: spouse,
        children: children,
        parents: parents,
        funeral: funeral
      },
      net: net,
      tax: tax,
      effectiveRate: net > 0 ? tax / net : 0,
      tiers: parts,
      insurance: insurance,
      estateAssets: estateAssets,
      insuranceInEstate: insuranceInEstate,
      estateTaxIfNamed: namedOn.tax,
      estateTaxIfUnnamed: unnamedOn.tax,
      estateTaxSaving: estateTaxSaving,
      amtIncluded: amtIncluded,
      amtBase: amtBase,
      amtTax: amtTax,
      amtQuotaRate: amtQuotaRate,
      amtRemain: amtRemain,
      amtDeathExempt: CONST.AMT_DEATH_EXEMPT,
      amtBaseExempt: CONST.AMT_BASE_EXEMPT,
      amtRate: CONST.AMT_RATE,
      /* 基本稅額公式拆解，供畫面顯示（超額 → 扣 750 萬 → ×20%） */
      amtFormula: { excess: amtIncluded, base: amtBase, rate: CONST.AMT_RATE },
      estateTax: tax,
      totalTax: totalTax,
      /* 同一筆金額的兩種安排：留現金（全數計入遺產） vs 指定受益人壽險 */
      compare: {
        amount: insurance,
        cashTax: unnamedOn.tax,
        insuredTax: totalTax,
        diff: unnamedOn.tax - totalTax
      },
      coverage: coverage,
      gap: gap,
      surplus: surplus,
      premium: premium,
      leverage: leverage,
      realEstate: realEstate,
      saleCost: saleCost,
      saleCostRate: CONST.SALE_COST_RATE,
      leverageSaving: leverageSaving,
      totalAfterTax: assets + insurance - tax - amtTax
    };
  }

  /* ---------- 版面（分塊組合，方便維護） ---------- */
  var HTML_ASSETS =
    '<section class="fcard">' +
    '<header class="fc-head">' +
    '<div><h3 class="fc-title">01 · 預估資產總額</h3>' +
    '<p class="fc-hint">不動產公告現值 ＋ 股票 ＋ 現金</p></div>' +
    '<span class="fc-badge" id="tx-assetsBadge">6,000 萬</span>' +
    '</header>' +
    '<div class="money-row">' +
    '<input type="range" class="rng" id="tx-assets" min="0" max="30000" step="100" value="6000" ' +
    'aria-label="預估資產總額，單位萬元">' +
    '<div class="money-box"><input type="number" class="money-num" id="tx-assetsNum" min="0" ' +
    'max="30000" step="100" value="6000" inputmode="numeric" aria-label="預估資產總額，單位萬元">' +
    '<span class="money-unit">萬元</span></div>' +
    '</div>' +
    '<div class="chips" data-quick="assets">' +
    '<button type="button" class="chip" data-value="3000">3,000 萬</button>' +
    '<button type="button" class="chip" data-value="6000">6,000 萬</button>' +
    '<button type="button" class="chip" data-value="10000">1 億</button>' +
    '<button type="button" class="chip" data-value="20000">2 億</button>' +
    '</div>' +
    '<div class="sub-field">' +
    '<label class="sub-label" for="tx-reRatio">不動產占比 <b id="tx-reRatioVal">60%</b></label>' +
    '<input type="range" class="rng rng-sm" id="tx-reRatio" min="0" max="100" step="5" value="60" ' +
    'aria-label="不動產占資產比例">' +
    '</div>' +
    '</section>';

  var HTML_DED =
    '<section class="fcard">' +
    '<header class="fc-head">' +
    '<div><h3 class="fc-title">02 · 免稅與扣除額</h3>' +
    '<p class="fc-hint">依現行遺產稅制估算，可快速勾選</p></div>' +
    '<span class="fc-badge fc-badge-dim" id="tx-dedBadge">1,471 萬</span>' +
    '</header>' +
    '<div class="ded-fixed"><span>免稅額（單身）</span><b>1,333 萬</b></div>' +
    '<label class="ded-row ded-check">' +
    '<span class="ded-name">配偶扣除額</span>' +
    '<span class="ded-ctrl"><b>553 萬</b><input type="checkbox" id="tx-spouse"></span>' +
    '</label>' +
    '<div class="ded-row">' +
    '<span class="ded-name">直系血親卑親屬<span class="ded-note">每人 56 萬</span></span>' +
    '<span class="stepper">' +
    '<button type="button" data-step="children" data-delta="-1" aria-label="減少直系血親卑親屬人數">−</button>' +
    '<b id="tx-childrenVal" aria-live="polite">0</b><span class="st-unit">人</span>' +
    '<button type="button" data-step="children" data-delta="1" aria-label="增加直系血親卑親屬人數">＋</button>' +
    '</span>' +
    '</div>' +
    '<div class="ded-row">' +
    '<span class="ded-name">父母<span class="ded-note">每人 138 萬</span></span>' +
    '<span class="stepper">' +
    '<button type="button" data-step="parents" data-delta="-1" aria-label="減少父母人數">−</button>' +
    '<b id="tx-parentsVal" aria-live="polite">0</b><span class="st-unit">人</span>' +
    '<button type="button" data-step="parents" data-delta="1" aria-label="增加父母人數">＋</button>' +
    '</span>' +
    '</div>' +
    '<label class="ded-row ded-check">' +
    '<span class="ded-name">喪葬費扣除額</span>' +
    '<span class="ded-ctrl"><b>138 萬</b><input type="checkbox" id="tx-funeral" checked></span>' +
    '</label>' +
    '</section>';

  var HTML_INS =
    '<section class="fcard">' +
    '<header class="fc-head">' +
    '<div><h3 class="fc-title">03 · 人壽保險預留金額</h3>' +
    '<p class="fc-hint">指定受益人之身故保險金</p></div>' +
    '<span class="fc-badge" id="tx-insBadge">300 萬</span>' +
    '</header>' +
    '<div class="money-row">' +
    '<input type="range" class="rng" id="tx-ins" min="0" max="20000" step="100" value="300" ' +
    'aria-label="人壽保險預留金額，單位萬元">' +
    '<div class="money-box"><input type="number" class="money-num" id="tx-insNum" min="0" ' +
    'max="20000" step="100" value="300" inputmode="numeric" aria-label="人壽保險預留金額，單位萬元">' +
    '<span class="money-unit">萬元</span></div>' +
    '</div>' +
    '<div class="chips" data-quick="insurance">' +
    '<button type="button" class="chip" data-value="0">不預留</button>' +
    '<button type="button" class="chip" data-value="500">500 萬</button>' +
    '<button type="button" class="chip" data-value="1000">1,000 萬</button>' +
    '<button type="button" class="chip" data-value="2000">2,000 萬</button>' +
    '</div>' +
    '<div class="premium-row">' +
    '<label for="tx-premium">預估年繳保費</label>' +
    '<div class="money-box money-box-sm"><input type="number" class="money-num" id="tx-premium" ' +
    'min="0" max="500" step="1" value="15" inputmode="numeric" aria-label="預估年繳保費，單位萬元">' +
    '<span class="money-unit">萬元</span></div>' +
    '</div>' +
    '<div class="ins-flags">' +
    '<label class="ded-row ded-check">' +
    '<span class="ded-name">受益人已指定<span class="ded-note">姓名、順位、比例</span></span>' +
    '<span class="ded-ctrl"><input type="checkbox" id="tx-beneficiary" checked></span>' +
    '</label>' +
    '<label class="ded-row ded-check">' +
    '<span class="ded-name">受益人≠要保人<span class="ded-note">死亡給付才計入最低稅負</span></span>' +
    '<span class="ded-ctrl"><input type="checkbox" id="tx-amt" checked></span>' +
    '</label>' +
    '</div>' +
    '<div class="cover ins-quota">' +
    '<div class="cover-head"><span>3,740 萬死亡給付額度</span><b id="tx-amtQuota">—</b></div>' +
    '<div class="cover-track"><i id="tx-amtQuotaBar"></i></div>' +
    '<p class="cover-note" id="tx-amtNote">—</p>' +
    '</div>' +
    '<button type="button" class="btn-ghost" id="tx-fillGap">以合計稅負補足稅源 →</button>' +
    '</section>' +
    '<p class="calc-note">※ 年繳保費僅供槓桿示意，實際保費依年齡、性別、體況與商品費率而定。</p>';

  var HTML_RESULT =
    '<section class="rcard">' +
    '<div class="rc-head">' +
    '<span class="rc-kicker">預估遺產稅</span>' +
    '<div class="rc-tax" aria-live="polite" aria-atomic="true"><span id="tx-taxVal">0</span><em>元</em></div>' +
    '<div class="rc-tax-sub">約 <b id="tx-taxWan">—</b> 萬元 · 有效稅率 <b id="tx-effRate">—</b></div>' +
    '</div>' +
    '<div class="rc-rows">' +
    '<div class="rc-row"><span>計入遺產總額</span><b id="tx-rAssets">—</b></div>' +
    '<div class="rc-row"><span>免稅額 ＋ 扣除額</span><b id="tx-rDed">—</b></div>' +
    '<div class="rc-row"><span>課稅遺產淨額</span><b class="hl" id="tx-rNet">—</b></div>' +
    '<div class="rc-row"><span>遺產稅</span><b id="tx-rEstate">—</b></div>' +
    '<div class="rc-row"><span>＋ 基本稅額（估算）</span><b id="tx-rAmt">—</b></div>' +
    '<div class="rc-row total"><span>＝ 合計稅負（稅源需求）</span>' +
    '<b class="hl" id="tx-rTotal">—</b></div>' +
    '</div>' +
    '<div class="tier">' +
    '<div class="tier-head"><span>級距分佈</span><span class="tier-note">10% / 15% / 20%</span></div>' +
    '<div class="tier-bar" id="tx-tierBar"><i></i><i></i><i></i></div>' +
    '<div class="tier-legend" id="tx-tierLegend"></div>' +
    '</div>' +
    '<div class="cover">' +
    '<div class="cover-head"><span>預留稅源覆蓋率</span><b id="tx-coverVal">—</b></div>' +
    '<div class="cover-track"><i id="tx-coverBar"></i></div>' +
    '<p class="cover-note" id="tx-coverNote">—</p>' +
    '</div>' +
    '<div class="gap-box" id="tx-gapBox"></div>' +
    '<div class="lever ins-tax">' +
    '<div class="lever-title">保險稅務檢視</div>' +
    '<div class="lever-grid">' +
    '<div class="lever-item"><span class="lv-l">計入遺產總額</span>' +
    '<span class="lv-v ok" id="tx-insEstate">—</span></div>' +
    '<div class="lever-item"><span class="lv-l">超過 3,740 萬計入基本所得額</span>' +
    '<span class="lv-v" id="tx-amtOver">—</span></div>' +
    '<div class="lever-item"><span class="lv-l">基本稅額（估算，20%）</span>' +
    '<span class="lv-v" id="tx-amtTax">—</span></div>' +
    '<div class="lever-item"><span class="lv-l">指定受益人少繳遺產稅</span>' +
    '<span class="lv-v ok" id="tx-estateSaving">—</span></div>' +
    '</div>' +
    '<p class="lever-formula" id="tx-amtFormula">—</p>' +
    '<p class="lever-note">身故給付每一申報戶全年 3,740 萬內免計入基本所得額；超過部分先扣 750 萬基本所得額免稅額，' +
    '再按 20% 計算，且僅就高於一般所得稅額的差額補繳。750 萬為全戶共用，若還有薪資、租金等其他所得，' +
    '實際金額會更高。受益人與要保人同一人時不適用 3,740 萬額度；滿期金、生存金、解約金全額計入。</p>' +
    '</div>' +
    '<div class="lever">' +
    '<div class="lever-title">槓桿效益分析</div>' +
    '<div class="lever-grid">' +
    '<div class="lever-item"><span class="lv-l">保額 ÷ 年繳保費</span>' +
    '<span class="lv-v" id="tx-leverage">—</span></div>' +
    '<div class="lever-item"><span class="lv-l">變賣不動產成本（6%）</span>' +
    '<span class="lv-v" id="tx-saleCost">—</span></div>' +
    '<div class="lever-item"><span class="lv-l">保險預留 vs 變賣成本</span>' +
    '<span class="lv-v" id="tx-leverDiff">—</span></div>' +
    '</div>' +
    '<p class="lever-note">以「年繳保費」對照「不出售不動產就能繳稅」所需付出的處分成本；' +
    '差距越大，預留稅源的效益越明顯。</p>' +
    '</div>' +
    '<div class="lever cmp-lever">' +
    '<div class="lever-title">同樣一筆錢，兩種結果</div>' +
    '<div class="cmp-grid">' +
    '<div class="cmp-col"><span class="cmp-tag">留在現金</span>' +
    '<b id="tx-cmpCash">—</b>' +
    '<span class="cmp-sub">全數計入遺產總額</span></div>' +
    '<div class="cmp-col is-good"><span class="cmp-tag">指定受益人壽險</span>' +
    '<b id="tx-cmpIns">—</b>' +
    '<span class="cmp-sub" id="tx-cmpInsSub">—</span></div>' +
    '</div>' +
    '<p class="cmp-diff" id="tx-cmpDiff">—</p>' +
    '<p class="lever-note">以同一筆金額比較（未計保費成本）。身故保險金給付指定受益人時不計入遺產' +
    '（保險法 §112），這是保險與現金最大的差別；超過 3,740 萬的部分才可能產生基本稅額。' +
    '未指定受益人時，保險金回到遺產課稅，節稅效果等於 0。</p>' +
    '</div>' +
    '<p class="rc-foot">※ 本試算依現行遺產稅率與定額扣除額估算，不含農地、公共設施保留地、' +
    '債務、實物抵繳等個案調整，實際稅額以國稅局核定為準。</p>' +
    '</section>';

  function buildHTML() {
    return (
      '<div class="calc">' +
      '<div class="calc-col calc-inputs">' + HTML_ASSETS + HTML_DED + HTML_INS + '</div>' +
      '<div class="calc-col calc-output">' + HTML_RESULT + '</div>' +
      '</div>'
    );
  }

  /* ---------- 狀態存取 ---------- */
  function loadState() {
    var s = {};
    Object.keys(DEFAULTS).forEach(function (k) {
      s[k] = DEFAULTS[k];
    });
    try {
      var raw = global.localStorage ? global.localStorage.getItem(STORE_KEY) : null;
      if (raw) {
        var saved = JSON.parse(raw);
        Object.keys(DEFAULTS).forEach(function (k) {
          if (saved[k] !== undefined && saved[k] !== null) s[k] = saved[k];
        });
      }
    } catch (e) {
      /* 壞資料或隱私模式 → 用預設值 */
    }
    s.assets = clamp(toNumber(s.assets, DEFAULTS.assets), 0, MAX.assets * 10000);
    s.insurance = clamp(toNumber(s.insurance, DEFAULTS.insurance), 0, MAX.insurance * 10000);
    s.premium = clamp(toNumber(s.premium, DEFAULTS.premium), 0, MAX.premium * 10000);
    s.realEstateRatio = clamp(toNumber(s.realEstateRatio, DEFAULTS.realEstateRatio), 0, 100);
    s.children = clamp(Math.round(toNumber(s.children, 0)), 0, 10);
    s.parents = clamp(Math.round(toNumber(s.parents, 0)), 0, 2);
    s.spouse = !!s.spouse;
    s.funeral = !!s.funeral;
    s.beneficiaryNamed = s.beneficiaryNamed !== false;
    s.amtApplies = s.amtApplies !== false;
    return s;
  }

  function saveState(state) {
    try {
      if (global.localStorage) global.localStorage.setItem(STORE_KEY, JSON.stringify(state));
    } catch (e) {
      /* 忽略：無痕模式或儲存空間已滿 */
    }
  }

  function wanLabel(amount) {
    var w = amount / 10000;
    if (w >= 10000) {
      return (w / 10000).toLocaleString('zh-TW', { maximumFractionDigits: 2 }) + ' 億';
    }
    return w.toLocaleString('zh-TW', { maximumFractionDigits: 0 }) + ' 萬';
  }

  function paintRange(input) {
    if (!input) return;
    var min = Number(input.min) || 0;
    var max = Number(input.max) || 100;
    var v = Number(input.value) || 0;
    var p = max > min ? ((v - min) / (max - min)) * 100 : 0;
    input.style.setProperty('--fill', clamp(p, 0, 100).toFixed(2) + '%');
  }

  /* ---------- 掛載 ---------- */
  function mount(container, options) {
    if (!container) return null;

    container.innerHTML = buildHTML();
    container.classList.add('calc-mount');

    var householdFrom = !!(options && options.householdFrom);
    container.classList.toggle('household-locked', householdFrom);

    if (householdFrom) {
      var dedCard = container.querySelectorAll('.fcard')[1];
      if (dedCard) {
        var synced = document.createElement('p');
        synced.className = 'calc-sync-note';
        synced.textContent = '※ 配偶、子女、父母人數由上方「01 指定分配」同步；如需調整請回上一步。';
        dedCard.appendChild(synced);
      }
    }

    var q = function (id) {
      return container.querySelector('#' + id);
    };
    var el = {
      assets: q('tx-assets'),
      assetsNum: q('tx-assetsNum'),
      assetsBadge: q('tx-assetsBadge'),
      reRatio: q('tx-reRatio'),
      reRatioVal: q('tx-reRatioVal'),
      spouse: q('tx-spouse'),
      childrenVal: q('tx-childrenVal'),
      parentsVal: q('tx-parentsVal'),
      funeral: q('tx-funeral'),
      dedBadge: q('tx-dedBadge'),
      ins: q('tx-ins'),
      insNum: q('tx-insNum'),
      insBadge: q('tx-insBadge'),
      premium: q('tx-premium'),
      beneficiary: q('tx-beneficiary'),
      amt: q('tx-amt'),
      amtQuota: q('tx-amtQuota'),
      amtQuotaBar: q('tx-amtQuotaBar'),
      amtNote: q('tx-amtNote'),
      insEstate: q('tx-insEstate'),
      amtOver: q('tx-amtOver'),
      amtTax: q('tx-amtTax'),
      estateSaving: q('tx-estateSaving'),
      taxVal: q('tx-taxVal'),
      taxWan: q('tx-taxWan'),
      effRate: q('tx-effRate'),
      rAssets: q('tx-rAssets'),
      rDed: q('tx-rDed'),
      rNet: q('tx-rNet'),
      rEstate: q('tx-rEstate'),
      tierBar: q('tx-tierBar'),
      tierLegend: q('tx-tierLegend'),
      coverVal: q('tx-coverVal'),
      coverBar: q('tx-coverBar'),
      coverNote: q('tx-coverNote'),
      gapBox: q('tx-gapBox'),
      leverage: q('tx-leverage'),
      saleCost: q('tx-saleCost'),
      leverDiff: q('tx-leverDiff'),
      rAmt: q('tx-rAmt'),
      rTotal: q('tx-rTotal'),
      amtFormula: q('tx-amtFormula'),
      cmpCash: q('tx-cmpCash'),
      cmpIns: q('tx-cmpIns'),
      cmpInsSub: q('tx-cmpInsSub'),
      cmpDiff: q('tx-cmpDiff'),
      fillGap: q('tx-fillGap')
    };

    var state = loadState();
    var result = calculate(state);
    if (householdFrom) el.spouse.disabled = true;
    var shownTax = 0;
    var rafId = 0;
    var reduceMotion = false;
    try {
      reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch (e) {
      reduceMotion = false;
    }

    function tweenTax(target) {
      if (rafId) cancelAnimationFrame(rafId);
      var from = shownTax;
      var to = Math.max(0, target);
      if (reduceMotion || Math.abs(to - from) < 1) {
        shownTax = to;
        el.taxVal.textContent = fmt(to);
        return;
      }
      var start = 0;
      var duration = 420;
      function step(ts) {
        if (!start) start = ts;
        var p = Math.min(1, (ts - start) / duration);
        var eased = 1 - Math.pow(1 - p, 3);
        var v = from + (to - from) * eased;
        el.taxVal.textContent = fmt(v);
        if (p < 1) {
          rafId = requestAnimationFrame(step);
        } else {
          rafId = 0;
          shownTax = to;
          el.taxVal.textContent = fmt(to);
        }
      }
      rafId = requestAnimationFrame(step);
    }

    function renderCoverage() {
      var cov = result.coverage;
      var width = clamp(cov * 100, 0, 100);
      el.coverBar.style.width = width + '%';
      el.coverBar.className = '';
      el.coverVal.textContent = pct(cov);
      if (result.totalTax <= 0) {
        el.coverBar.classList.add('ok');
        el.coverVal.classList.remove('bad', 'warn');
        el.coverVal.classList.add('ok');
        el.coverNote.textContent = '目前試算沒有遺產稅與基本稅額，仍建議保留基本現金流與稅源。';
        return;
      }
      var level = cov >= 1 ? 'ok' : cov >= 0.5 ? 'warn' : 'bad';
      el.coverBar.classList.add(level);
      el.coverVal.classList.remove('ok', 'warn', 'bad');
      el.coverVal.classList.add(level);
      if (level === 'ok') {
        el.coverNote.textContent =
          '保險金足以支應遺產稅與基本稅額，尚有 ' + fmtWan(result.surplus) + ' 萬元可留給家人運用。';
      } else if (level === 'warn') {
        el.coverNote.textContent =
          '還差 ' + fmtWan(result.gap) + ' 萬元現金，建議提高保額或搭配現金信託。';
      } else {
        el.coverNote.textContent =
          '缺口 ' + fmtWan(result.gap) + ' 萬元，繼承人可能需要變賣資產，風險偏高。';
      }
    }

    function taxBreakdown() {
      var txt = '遺產稅 ' + fmtWan(result.tax) + ' 萬';
      if (result.amtTax > 0) txt += ' ＋ 基本稅額 ' + fmtWan(result.amtTax) + ' 萬';
      return txt;
    }

    function renderGap() {
      if (result.totalTax <= 0) {
        el.gapBox.className = 'gap-box ok';
        el.gapBox.innerHTML =
          '<b>目前試算無遺產稅與基本稅額</b><span>資產未超過免稅額與扣除額，且身故給付在 3,740 萬額度內；' +
          '仍建議每年檢視一次。</span>';
      } else if (result.gap > 0) {
        el.gapBox.className = 'gap-box bad';
        el.gapBox.innerHTML =
          '<b>稅源缺口 ' + fmt(result.gap) + ' 元</b>' +
          '<span>約 ' + fmtWan(result.gap) + ' 萬元（' + taxBreakdown() +
          '），建議以壽險補足，避免繼承人賤賣不動產。</span>';
      } else {
        el.gapBox.className = 'gap-box ok';
        el.gapBox.innerHTML =
          '<b>稅源已足額，尚有 ' + fmt(result.surplus) + ' 元餘裕</b>' +
          '<span>合計稅負 ' + taxBreakdown() + '；仍建議每年同步檢視保單、受益人與資產配置。</span>';
      }
    }

    function renderAmt() {
      if (!el.amtQuota) return;
      var q = result.amtQuotaRate;
      el.amtQuota.className = '';
      el.amtQuotaBar.className = '';
      el.amtQuotaBar.style.width = '0%';

      if (result.insurance <= 0) {
        el.amtQuota.textContent = '—';
        el.amtNote.textContent = '尚未預留身故給付；先設定保額，再檢視 3,740 萬額度。';
        return;
      }
      if (!result.inputs.amtApplies) {
        el.amtQuota.textContent = '不適用';
        el.amtNote.textContent = result.inputs.beneficiaryNamed
          ? '受益人與要保人同一人時，死亡給付不計入基本所得額，3,740 萬額度不適用。'
          : '尚未指定受益人，死亡給付計入遺產，3,740 萬額度不適用。';
        return;
      }

      var level = q > 1.2 ? 'bad' : q > 1 ? 'warn' : 'ok';
      el.amtQuota.textContent = pct(q);
      el.amtQuota.classList.add(level);
      el.amtQuotaBar.style.width = clamp(q * 100, 0, 100) + '%';
      el.amtQuotaBar.classList.add(level);

      if (result.amtIncluded > 0) {
        el.amtNote.textContent =
          '超過額度 ' +
          fmtWan(result.amtIncluded) +
          ' 萬計入基本所得額；' +
          (result.amtTax > 0
            ? '基本稅額約 ' + fmtWan(result.amtTax) + ' 萬（已扣 750 萬）。'
            : '未超過 750 萬免稅額，基本稅額為 0。');
      } else {
        el.amtNote.textContent =
          '死亡給付在 3,740 萬額度內；連同 750 萬免稅額（全戶共用），保額 4,490 萬以內的死亡給付通常不會產生基本稅額。';
      }
    }

    function renderInsTax() {
      el.insEstate.textContent =
        result.insuranceInEstate > 0
          ? fmtWan(result.insuranceInEstate) + ' 萬'
          : result.inputs.beneficiaryNamed
            ? '0 元（指定受益人）'
            : '0 元';
      el.insEstate.className = 'lv-v ' + (result.insuranceInEstate > 0 ? 'bad' : 'ok');

      el.amtOver.textContent = !result.inputs.amtApplies
        ? '不適用'
        : result.amtIncluded > 0
          ? fmtWan(result.amtIncluded) + ' 萬'
          : '0 元';
      el.amtTax.textContent = result.amtTax > 0 ? fmtWan(result.amtTax) + ' 萬' : '0 元';
      el.estateSaving.textContent =
        result.estateTaxSaving > 0 ? '少 ' + fmtWan(result.estateTaxSaving) + ' 萬' : '—';
      el.estateSaving.className =
        'lv-v ' + (result.estateTaxSaving > 0 ? 'ok' : '');

      if (el.amtFormula) {
        if (!result.inputs.amtApplies) {
          el.amtFormula.textContent = result.inputs.beneficiaryNamed
            ? '受益人＝要保人 → 3,740 萬額度不適用，死亡給付不計入基本所得額。'
            : '未指定受益人 → 死亡給付計入遺產，3,740 萬額度不適用。';
        } else if (result.amtIncluded <= 0) {
          el.amtFormula.textContent =
            '身故給付 ' + fmtWan(result.insurance) + ' 萬 ＜ 3,740 萬 → 基本所得額增加 0 元。';
        } else if (result.amtBase <= 0) {
          el.amtFormula.textContent =
            '超額 ' + fmtWan(result.amtIncluded) + ' 萬 − 750 萬 ＜ 0 → 基本稅額 0 元。';
        } else {
          el.amtFormula.textContent =
            '（' + fmtWan(result.insurance) + ' − 3,740 − 750）萬 × 20% ＝ ' +
            fmtWan(result.amtTax) + ' 萬';
        }
      }
    }

    function refresh(persist) {
      result = calculate(state);

      if (document.activeElement !== el.assetsNum) el.assetsNum.value = toWan(state.assets);
      if (document.activeElement !== el.insNum) el.insNum.value = toWan(state.insurance);
      if (document.activeElement !== el.premium) el.premium.value = toWan(state.premium);
      el.assets.value = toWan(state.assets);
      el.ins.value = toWan(state.insurance);
      el.reRatio.value = state.realEstateRatio;
      el.spouse.checked = state.spouse;
      el.funeral.checked = state.funeral;
      el.beneficiary.checked = state.beneficiaryNamed;
      el.amt.checked = result.inputs.amtApplies;
      el.amt.disabled = !state.beneficiaryNamed;
      el.childrenVal.textContent = state.children;
      el.parentsVal.textContent = state.parents;
      el.reRatioVal.textContent = state.realEstateRatio + '%';

      paintRange(el.assets);
      paintRange(el.ins);
      paintRange(el.reRatio);

      el.assetsBadge.textContent = wanLabel(state.assets);
      el.dedBadge.textContent = wanLabel(result.exempt + result.deduction);
      el.insBadge.textContent = wanLabel(state.insurance);

      tweenTax(result.tax);
      el.taxWan.textContent = fmtWan(result.tax);
      el.effRate.textContent = result.net > 0 ? pct(result.effectiveRate) : '—';
      el.rAssets.textContent = fmt(result.estateAssets) + ' 元';
      el.rDed.textContent = fmt(result.exempt + result.deduction) + ' 元';
      el.rNet.textContent = fmt(result.net) + ' 元';
      el.rEstate.textContent = fmt(result.tax) + ' 元';
      el.rAmt.textContent = fmt(result.amtTax) + ' 元';
      el.rTotal.textContent = fmt(result.totalTax) + ' 元';

      /* 級距分佈長條：以各級距稅額占比呈現 */
      var barTotal = result.tax;
      el.tierBar.classList.toggle('is-empty', barTotal <= 0);
      Array.prototype.forEach.call(el.tierBar.children, function (bar, i) {
        var part = result.tiers[i];
        var share = barTotal > 0 ? part.tax / barTotal : 0;
        bar.style.flexGrow = share > 0 ? share : 0;
        bar.style.opacity = share > 0 ? 1 : 0;
      });
      el.tierLegend.innerHTML = result.tiers
        .map(function (p, i) {
          var txt =
            p.base > 0
              ? fmtWan(p.base, 0) + ' 萬 × ' + p.label + ' = ' + fmtWan(p.tax, 1) + ' 萬'
              : '未觸及';
          return (
            '<span class="tl-item"><i class="tl-dot d' + i + '"></i>' + p.label + ' · ' + txt + '</span>'
          );
        })
        .join('');

      renderCoverage();
      renderGap();
      renderAmt();
      renderInsTax();

      el.leverage.textContent =
        result.leverage > 0 ? result.leverage.toFixed(1).replace(/\.0$/, '') + ' 倍' : '—';
      el.saleCost.textContent = fmtWan(result.saleCost) + ' 萬';

      if (result.premium <= 0) {
        el.leverDiff.textContent = '—';
        el.leverDiff.className = 'lv-v';
      } else if (result.leverageSaving > 0) {
        el.leverDiff.textContent = '少付 ' + fmtWan(result.leverageSaving) + ' 萬';
        el.leverDiff.className = 'lv-v ok';
      } else {
        el.leverDiff.textContent = '多付 ' + fmtWan(-result.leverageSaving) + ' 萬';
        el.leverDiff.className = 'lv-v bad';
      }

      /* 同樣一筆錢：現金 vs 指定受益人壽險 */
      if (el.cmpCash) {
        var cmp = result.compare;
        if (cmp.amount <= 0) {
          el.cmpCash.textContent = '—';
          el.cmpIns.textContent = '—';
          el.cmpInsSub.textContent = '先設定保額';
          el.cmpDiff.textContent = '先設定保額，才能看出兩種安排的差異。';
        } else {
          el.cmpCash.textContent = fmtWan(cmp.cashTax) + ' 萬';
          el.cmpIns.textContent = fmtWan(cmp.insuredTax) + ' 萬';
          el.cmpInsSub.textContent =
            '遺產稅 ' + fmtWan(result.tax) + ' 萬 ＋ 基本稅額 ' + fmtWan(result.amtTax) + ' 萬';
          el.cmpDiff.textContent =
            cmp.diff > 0
              ? '同樣 ' + fmtWan(cmp.amount) + ' 萬，指定受益人後少繳 ' + fmtWan(cmp.diff) + ' 萬'
              : '目前安排沒有節稅效果，請確認是否已指定受益人、且受益人≠要保人。';
        }
      }

      if (el.fillGap) {
        el.fillGap.disabled = !state.beneficiaryNamed;
        el.fillGap.textContent = state.beneficiaryNamed
          ? '以合計稅負補足稅源 →'
          : '請先指定受益人，保額才不會反過來被課遺產稅';
      }

      if (persist !== false) saveState(state);

      try {
        document.dispatchEvent(new CustomEvent('estate:tax-change', { detail: result }));
      } catch (e) {
        /* 舊瀏覽器不支援 CustomEvent 建構子 → 略過廣播 */
      }
    }

    /* ---------- 事件綁定 ---------- */
    function bindMoney(rangeEl, numEl, key, maxWan) {
      function apply(rawWan) {
        var wan = clamp(toNumber(rawWan, 0), 0, maxWan);
        state[key] = Math.round(wan * 10000);
        rangeEl.value = Math.round(wan);
        paintRange(rangeEl);
        refresh();
      }
      rangeEl.addEventListener('input', function () {
        apply(Number(rangeEl.value));
        if (document.activeElement !== numEl) numEl.value = rangeEl.value;
      });
      numEl.addEventListener('input', function () {
        apply(numEl.value === '' ? 0 : Number(numEl.value));
      });
      numEl.addEventListener('blur', function () {
        numEl.value = toWan(state[key]);
      });
    }

    bindMoney(el.assets, el.assetsNum, 'assets', MAX.assets);
    bindMoney(el.ins, el.insNum, 'insurance', MAX.insurance);

    el.premium.addEventListener('input', function () {
      var v = el.premium.value === '' ? 0 : Number(el.premium.value);
      state.premium = Math.round(clamp(toNumber(v, 0), 0, MAX.premium) * 10000);
      refresh();
    });
    el.premium.addEventListener('blur', function () {
      el.premium.value = toWan(state.premium);
    });

    el.reRatio.addEventListener('input', function () {
      state.realEstateRatio = clamp(Number(el.reRatio.value) || 0, 0, 100);
      refresh();
    });

    el.spouse.addEventListener('change', function () {
      state.spouse = el.spouse.checked;
      refresh();
    });
    el.funeral.addEventListener('change', function () {
      state.funeral = el.funeral.checked;
      refresh();
    });

    el.beneficiary.addEventListener('change', function () {
      state.beneficiaryNamed = el.beneficiary.checked;
      refresh();
    });
    el.amt.addEventListener('change', function () {
      state.amtApplies = el.amt.checked;
      refresh();
    });

    Array.prototype.forEach.call(container.querySelectorAll('[data-step]'), function (btn) {
      btn.addEventListener('click', function () {
        var key = btn.getAttribute('data-step');
        var delta = Number(btn.getAttribute('data-delta')) || 0;
        var max = key === 'children' ? 10 : 2;
        state[key] = clamp((Number(state[key]) || 0) + delta, 0, max);
        refresh();
      });
    });

    Array.prototype.forEach.call(container.querySelectorAll('[data-quick]'), function (group) {
      group.addEventListener('click', function (e) {
        var btn = e.target && e.target.closest ? e.target.closest('.chip') : null;
        if (!btn || !group.contains(btn)) return;
        var key = group.getAttribute('data-quick') === 'assets' ? 'assets' : 'insurance';
        state[key] = (Number(btn.getAttribute('data-value')) || 0) * 10000;
        refresh();
      });
    });

    /* 一鍵補足：保險金本身可能觸發基本稅額，需迭代到「保額 = 合計稅負」的定點 */
    q('tx-fillGap').addEventListener('click', function () {
      if (!state.beneficiaryNamed) return;
      var probe = {};
      var next = state.insurance;
      for (var i = 0; i < 8; i++) {
        Object.keys(state).forEach(function (k) {
          probe[k] = state[k];
        });
        probe.insurance = next;
        var need = Math.ceil(calculate(probe).totalTax / 10000) * 10000;
        if (need === next) break;
        next = clamp(need, 0, MAX.insurance * 10000);
      }
      state.insurance = next;
      refresh();
    });

    /* 首次繪製 */
    refresh();

    var api = {
      el: container,
      getState: function () {
        return JSON.parse(JSON.stringify(state));
      },
      getResult: function () {
        return result;
      },
      setState: function (patch) {
        Object.keys(patch || {}).forEach(function (k) {
          if (patch[k] !== undefined) state[k] = patch[k];
        });
        refresh();
      },
      setHeirs: function (patch) {
        if (!patch) return;
        if (patch.spouse !== undefined) state.spouse = !!patch.spouse;
        if (patch.children !== undefined) {
          state.children = clamp(Math.round(toNumber(patch.children, 0)), 0, 10);
        }
        if (patch.parents !== undefined) {
          state.parents = clamp(Math.round(toNumber(patch.parents, 0)), 0, 2);
        }
        refresh();
      },
      refresh: function () {
        refresh();
      },
      constants: CONST
    };
    container.__estateTaxCalc = api;
    return api;
  }

  var api = { mount: mount, calculate: calculate, constants: CONST, defaults: DEFAULTS, max: MAX };
  if (typeof window !== 'undefined') window.EstateTaxCalculator = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : this);
