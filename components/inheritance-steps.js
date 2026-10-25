/*!
 * components/inheritance-steps.js
 * 資產傳承三步驟 — 教學卡片模組（原生 JS、零依賴）
 * ---------------------------------------------------------------------------
 * 用法：
 *   <div id="stepsMount"></div>
 *   <script src="./components/inheritance-steps.js"></script>
 *   <script>EstateSteps.mount(document.getElementById('stepsMount'));</script>
 *
 * 設計：一次只展開一張（accordion），標題列是 <button>，鍵盤／螢幕閱讀器可直接操作。
 */
(function (global) {
  'use strict';

  /* ---------- 內嵌 SVG（不引入圖標庫，離線也能用） ---------- */
  var ICON = {
    assign:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<circle cx="12" cy="12" r="8.2"></circle><circle cx="12" cy="12" r="3.4"></circle>' +
      '<path d="M12 1.8v2.6M12 19.6v2.6M1.8 12h2.6M19.6 12h2.6"></path></svg>',
    tax:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<path d="M5.2 18.8 18.8 5.2"></path>' +
      '<circle cx="7.6" cy="7.6" r="2.6"></circle><circle cx="16.4" cy="16.4" r="2.6"></circle>' +
      '<path d="M3.4 10.2v-4a2.8 2.8 0 0 1 2.8-2.8h4"></path></svg>',
    source:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<path d="M12 2.8 19 5.8v5.5c0 4.4-2.9 8.1-7 9.8-4.1-1.7-7-5.4-7-9.8V5.8l7-3z"></path>' +
      '<path d="M9 12.1l2.2 2.2 4.1-4.5"></path></svg>'
  };

  var CHEV =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M6 9l6 6 6-6"></path></svg>';

  /* ---------- 內容 ---------- */
  var STEPS = [
    {
      no: '01',
      icon: ICON.assign,
      title: '指定分配',
      lead: '先確定「給誰、給多少」',
      desc:
        '傳承的第一順位不是節稅，而是「意願能不能被執行」。先把人與金額寫清楚，再挑工具；' +
        '沒有指定，法律就會替您決定——而且是平均分配。下方可直接加減家庭成員，' +
        '即時試算每個人的應繼分與特留分。',
      slot: 'heir',
      points: [
        {
          t: '遺囑',
          d: '自書、公證、代筆、錄音、口授五種；公證遺囑最不易被爭執，並可指定遺囑執行人。'
        },
        {
          t: '保險受益人',
          d: '填寫姓名與身分證字號，寫明順位與比例；不要只寫「法定繼承人」。'
        },
        {
          t: '信託',
          d: '他益信託可約定分期給付、限定教育醫療用途，避免一次拿到大筆現金。'
        },
        {
          t: '特留分',
          d: '配偶、直系血親卑親屬、父母為應繼分 1/2；兄弟姊妹、祖父母 1/3。' +
            '兄弟姊妹部分自 116/2/17 起取消，指定分配仍不得侵害。'
        }
      ],
      tools: ['遺囑', '保險受益人指定', '他益信託', '意定監護'],
      warn: '口頭交代、只寫「給兒子」、要保人與被保險人不同人卻未經同意，都是日後爭產的起點。'
    },
    {
      no: '02',
      icon: ICON.tax,
      title: '降低稅額',
      lead: '再思考「如何省錢」',
      desc:
        '稅不是不能規劃，而是要在「來得及」的時候做。逐年贈與、資產架構與保險給付的定位，' +
        '決定了最後要繳多少稅。',
      points: [
        {
          t: '年度贈與免稅額',
          d: '每人每年 244 萬，夫妻合計 488 萬；跨年度分段贈與是最穩定的做法。'
        },
        {
          t: '婚嫁贈與',
          d: '子女婚嫁前後各 100 萬（父母合計 200 萬），可與年度免稅額並用。'
        },
        {
          t: '保險給付定位',
          d: '指定受益人的身故保險金原則上不計入遺產（保險法 §112）；' +
            '所得稅另看最低稅負，死亡給付每戶超過 3,740 萬的部分才計入基本所得額。'
        },
        {
          t: '最低稅負',
          d: '死亡給付每戶超過 3,740 萬的部分才計入基本所得額，且再超過 750 萬後才計算所得稅；' +
            '滿期金、生存金、解約金則全額計入。'
        },
        {
          t: '課稅基礎',
          d: '不動產按公告現值、股票按死亡日收盤價計稅，提早調整結構可降低課稅基礎。'
        }
      ],
      tools: ['逐年贈與', '婚嫁贈與', '保單架構調整', '公告現值檢視'],
      warn: '死亡前兩年內贈與會被併入遺產總額；密集移轉反而容易觸發查核。'
    },
    {
      no: '03',
      icon: ICON.source,
      title: '補足稅源',
      lead: '最後準備「現金繳稅」',
      desc:
        '遺產稅必須「先繳稅、後繼承」，且原則上以現金繳納。資產再多、現金不足，' +
        '繼承人就得賤賣不動產，或被迫實物抵繳。',
      points: [
        {
          t: '算出缺口',
          d: '先用下方試算器算出預估稅額，再盤點繼承人手上可立即動用的現金。'
        },
        {
          t: '壽險槓桿',
          d: '以相對小的保費預留足額現金；保險金即時給付，不必等遺產分割程序。'
        },
        {
          t: '受益人安排',
          d: '指定受益人後，身故保險金不計入遺產（保險法 §112），是最直接的免稅安排；' +
            '建議指定給主要納稅義務人或繼承人，避免稅源又被平均分配。'
        },
        {
          t: '實物抵繳',
          d: '現金真的不足才使用；不動產抵繳的認定價值與變現價值常有落差。'
        }
      ],
      tools: ['終身壽險', '增額壽險', '保單受益人', '稅源專戶'],
      warn:
        '保單未指定受益人、要保人與被保險人不同人，或高齡／重病時躉繳鉅額保費，' +
        '都可能被併入遺產課稅，槓桿效果全失。'
    }
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function stepHTML(step, idx) {
    var panelId = 'estate-step-panel-' + (idx + 1);
    var btnId = 'estate-step-btn-' + (idx + 1);
    var points = step.points
      .map(function (p) {
        return (
          '<li class="step-point"><span class="sp-t">' + esc(p.t) + '</span>' +
          '<span class="sp-d">' + esc(p.d) + '</span></li>'
        );
      })
      .join('');
    var tools = step.tools
      .map(function (t) {
        return '<span class="step-tool">' + esc(t) + '</span>';
      })
      .join('');

    return (
      '<article class="step" data-index="' + idx + '">' +
      '<button class="step-head" type="button" id="' + btnId + '" aria-expanded="false" ' +
      'aria-controls="' + panelId + '">' +
      '<span class="step-no">' + esc(step.no) + '</span>' +
      '<span class="step-ico">' + step.icon + '</span>' +
      '<span class="step-main">' +
      '<span class="step-title">' + esc(step.title) + '</span>' +
      '<span class="step-lead">' + esc(step.lead) + '</span>' +
      '</span>' +
      '<span class="step-chev">' + CHEV + '</span>' +
      '</button>' +
      '<div class="step-panel" id="' + panelId + '" role="region" aria-labelledby="' + btnId + '">' +
      '<div class="step-panel-inner">' +
      '<p class="step-desc">' + esc(step.desc) + '</p>' +
      (step.slot ? '<div class="step-slot" data-slot="' + esc(step.slot) + '"></div>' : '') +
      '<ul class="step-points">' + points + '</ul>' +
      '<div class="step-tools"><span class="st-label">搭配工具</span>' + tools + '</div>' +
      '<p class="step-warn"><span aria-hidden="true">⚠</span> ' + esc(step.warn) + '</p>' +
      '</div></div>' +
      '</article>'
    );
  }

  function buildHTML() {
    var cards = STEPS.map(stepHTML).join(
      '<div class="step-link" aria-hidden="true"><span></span></div>'
    );
    return (
      '<div class="steps">' + cards + '</div>' +
      '<p class="steps-order"><b>順序不能顛倒：</b>先分配（給對人）、再節稅（省對錢）、' +
      '最後補現金（繳得起）。反過來做，常常是稅沒省到、錢也給錯人。</p>'
    );
  }

  function mount(container, options) {
    if (!container) return null;
    var startOpen = options && typeof options.openIndex === 'number' ? options.openIndex : 0;

    container.innerHTML = buildHTML();
    container.classList.add('steps-mount');

    var steps = Array.prototype.slice.call(container.querySelectorAll('.step'));
    var slots = {};
    Array.prototype.forEach.call(container.querySelectorAll('[data-slot]'), function (node) {
      slots[node.getAttribute('data-slot')] = node;
    });

    function setOpen(index) {
      steps.forEach(function (el, i) {
        var isOpen = i === index;
        var btn = el.querySelector('.step-head');
        el.classList.toggle('open', isOpen);
        btn.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
      });
    }

    steps.forEach(function (el, i) {
      var btn = el.querySelector('.step-head');
      btn.addEventListener('click', function () {
        setOpen(el.classList.contains('open') ? -1 : i);
      });
    });

    setOpen(startOpen);

    return { el: container, open: setOpen, total: steps.length, slots: slots };
  }

  var api = { mount: mount, STEPS: STEPS, icons: ICON };
  if (typeof window !== 'undefined') window.EstateSteps = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : this);
