/*!
 * components/heir-allocator.js
 * 法定繼承人「指定分配」互動模組：應繼分（民法 §1144）／特留分（民法 §1223）
 * 原生 JS、零依賴；掛載後提供 window.EstateHeirs。
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.EstateHeirs = api;
})(typeof window !== 'undefined' ? window : null, function () {
  'use strict';

  var STORE_KEY = 'estate_planning_heirs_v1';

  var HEIRS = [
    { id: 'spouse', label: '配偶', max: 1, unit: '人' },
    { id: 'children', label: '子女', max: 10, unit: '人' },
    { id: 'parents', label: '父母', max: 2, unit: '人' },
    { id: 'siblings', label: '兄弟姊妹', max: 10, unit: '人' },
    { id: 'grandparents', label: '祖父母', max: 4, unit: '人' }
  ];

  var DEFAULTS = { spouse: 1, children: 2, parents: 0, siblings: 0, grandparents: 0 };
  var BASE_DEFAULT = 60000000;

  var LAW = {
    share: '民法第1144條',
    reserved: '民法第1223條',
    base: '民法第1224條',
    amendment:
      '民法第1223條已於 115/8/17 修正公布、116/2/17 施行；施行後兄弟姊妹不再有特留分，本表依現行有效條文試算。'
  };

  var PRESETS = [
    { id: 'spouse2', label: '配偶＋2 子女', counts: { spouse: 1, children: 2 } },
    { id: 'spouseParents', label: '配偶＋父母', counts: { spouse: 1, parents: 2 } },
    { id: 'singleParents', label: '單身＋父母', counts: { parents: 2 } },
    { id: 'spouseOnly', label: '配偶單獨', counts: { spouse: 1 } },
    { id: 'spouseSibling', label: '配偶＋手足', counts: { spouse: 1, siblings: 2 } },
    { id: 'clear', label: '清除', counts: {} }
  ];

  /* ---------- 小工具 ---------- */
  function clamp(n, lo, hi) {
    return Math.max(lo, Math.min(hi, n));
  }

  function gcd(a, b) {
    a = Math.abs(a);
    b = Math.abs(b);
    while (b) {
      var t = a % b;
      a = b;
      b = t;
    }
    return a || 1;
  }

  function fraction(num, den) {
    if (!den || !num) return '0';
    var g = gcd(num, den);
    num = Math.round(num / g);
    den = Math.round(den / g);
    return den === 1 ? '全部' : num + '/' + den;
  }

  function pct(rate, digits) {
    var d = digits == null ? 2 : digits;
    var f = Math.pow(10, d);
    var v = Math.round(rate * 100 * f) / f;
    return String(v).replace(/\.0+$/, '') + '%';
  }

  function fmtWan(amount) {
    var w = Number(amount) / 10000;
    if (!isFinite(w)) return '—';
    var d = Math.abs(w - Math.round(w)) < 0.05 ? 0 : 1;
    return (
      w.toLocaleString('zh-TW', { minimumFractionDigits: 0, maximumFractionDigits: d }) + ' 萬'
    );
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"]/g, function (m) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m];
    });
  }

  function normalize(counts) {
    var out = {};
    HEIRS.forEach(function (h) {
      var n = Math.round(Number(counts && counts[h.id]));
      out[h.id] = isFinite(n) ? clamp(n, 0, h.max) : 0;
    });
    return out;
  }

  function findHeir(id) {
    var hit = null;
    HEIRS.some(function (h) {
      if (h.id === id) {
        hit = h;
        return true;
      }
      return false;
    });
    return hit;
  }

  /* ---------- 應繼分／特留分 ---------- */
  function calculate(counts, base) {
    var c = normalize(counts);
    var amount = Math.max(0, Number(base) || 0);
    var rows = [];
    var reservedTotal = 0;

    function add(key, label, group, num, den, rateNum, rateDen, note) {
      var share = den > 0 ? num / den : 0;
      var reserved = share * (rateNum / rateDen);
      reservedTotal += reserved;
      rows.push({
        key: key,
        label: label,
        group: group,
        sharePct: share,
        shareText: fraction(num, den),
        shareAmount: amount * share,
        reservedPct: reserved,
        reservedText: fraction(num * rateNum, den * rateDen),
        reservedAmount: amount * reserved,
        note: note || ''
      });
    }

    var sp = c.spouse;
    var ch = c.children;
    var pa = c.parents;
    var si = c.siblings;
    var gr = c.grandparents;
    var i;

    if (sp && ch) {
      add('spouse', '配偶', 'spouse', 1, ch + 1, 1, 2);
      for (i = 1; i <= ch; i++) add('child' + i, '子女 ' + i, 'children', 1, ch + 1, 1, 2);
    } else if (sp && pa) {
      add('spouse', '配偶', 'spouse', 1, 2, 1, 2);
      for (i = 1; i <= pa; i++) {
        add(
          'parent' + i,
          pa === 1 ? '父或母' : i === 1 ? '父' : '母',
          'parents',
          1,
          pa * 2,
          1,
          2
        );
      }
    } else if (sp && si) {
      add('spouse', '配偶', 'spouse', 1, 2, 1, 2);
      for (i = 1; i <= si; i++) {
        add(
          'sibling' + i,
          '兄弟姊妹 ' + i,
          'siblings',
          1,
          si * 2,
          1,
          3,
          i === 1 ? '116/2/17 起取消特留分' : ''
        );
      }
    } else if (sp && gr) {
      add('spouse', '配偶', 'spouse', 2, 3, 1, 2);
      for (i = 1; i <= gr; i++) {
        add('grand' + i, '祖父母 ' + i, 'grandparents', 1, gr * 3, 1, 3);
      }
    } else if (sp) {
      add('spouse', '配偶', 'spouse', 1, 1, 1, 2);
    } else if (ch) {
      for (i = 1; i <= ch; i++) add('child' + i, '子女 ' + i, 'children', 1, ch, 1, 2);
    } else if (pa) {
      for (i = 1; i <= pa; i++) {
        add(
          'parent' + i,
          pa === 1 ? '父或母' : i === 1 ? '父' : '母',
          'parents',
          1,
          pa,
          1,
          2
        );
      }
    } else if (si) {
      for (i = 1; i <= si; i++) {
        add(
          'sibling' + i,
          '兄弟姊妹 ' + i,
          'siblings',
          1,
          si,
          1,
          3,
          i === 1 ? '116/2/17 起取消特留分' : ''
        );
      }
    } else if (gr) {
      for (i = 1; i <= gr; i++) add('grand' + i, '祖父母 ' + i, 'grandparents', 1, gr, 1, 3);
    }

    var reservedAmount = amount * reservedTotal;
    return {
      counts: c,
      base: amount,
      rows: rows,
      hasHeirs: rows.length > 0,
      hasSiblings: si > 0,
      totals: {
        heirsCount: sp + ch + pa + si + gr,
        shareRate: rows.length ? 1 : 0,
        reservedRate: reservedTotal,
        reservedAmount: reservedAmount,
        freeAmount: Math.max(0, amount - reservedAmount)
      },
      law: LAW
    };
  }

  /* ---------- 畫面 ---------- */
  function buildHTML() {
    var presetBtns = PRESETS.map(function (p) {
      return (
        '<button type="button" class="chip" data-preset="' +
        p.id +
        '">' +
        escapeHTML(p.label) +
        '</button>'
      );
    }).join('');

    var controls = HEIRS.map(function (h) {
      return (
        '<div class="heir-ctrl">' +
        '<span class="heir-name">' +
        escapeHTML(h.label) +
        '<em>上限 ' +
        h.max +
        ' ' +
        h.unit +
        '</em></span>' +
        '<span class="stepper">' +
        '<button type="button" data-heir="' +
        h.id +
        '" data-delta="-1" aria-label="減少' +
        escapeHTML(h.label) +
        '">−</button>' +
        '<b id="heir-' +
        h.id +
        'Val" aria-live="polite">0</b>' +
        '<button type="button" data-heir="' +
        h.id +
        '" data-delta="1" aria-label="增加' +
        escapeHTML(h.label) +
        '">＋</button>' +
        '</span>' +
        '</div>'
      );
    }).join('');

    return (
      '<div class="heir">' +
      '<div class="heir-head">' +
      '<div>' +
      '<h4 class="heir-title">法定繼承人與分配試算</h4>' +
      '<p class="heir-sub">加減人數，即時看每位繼承人的應繼分與特留分（' +
      LAW.share +
      '、' +
      LAW.reserved +
      '）。</p>' +
      '</div>' +
      '<span class="heir-base">遺產總額 <b id="heirBase">—</b><em>已指定受益人者不含身故給付</em></span>' +
      '</div>' +
      '<div class="heir-presets" aria-label="快速情境">' +
      presetBtns +
      '</div>' +
      '<div class="heir-controls">' +
      controls +
      '</div>' +
      '<div class="heir-table-wrap">' +
      '<table class="heir-table">' +
      '<caption class="heir-caption">各繼承人應繼分與特留分</caption>' +
      '<thead><tr><th scope="col">繼承人</th><th scope="col">應繼分</th><th scope="col">特留分</th></tr></thead>' +
      '<tbody id="heirRows"></tbody>' +
      '<tfoot><tr class="heir-total">' +
      '<th scope="row">合計</th>' +
      '<td><b id="heirTotalShares">0%</b><span id="heirTotalAmount">—</span></td>' +
      '<td><b id="heirTotalReserved">0%</b><span id="heirTotalReservedAmount">—</span></td>' +
      '</tr></tfoot>' +
      '</table>' +
      '</div>' +
      '<div class="heir-free">' +
      '<div class="hf-l"><span>可自由處分</span><em>遺囑／信託／保險</em></div>' +
      '<b id="heirFree">—</b>' +
      '<small id="heirFreePct">—</small>' +
      '</div>' +
      '<p class="heir-warn" id="heirWarn" hidden>目前沒有法定繼承人，遺產依法歸屬國庫，特留分為 0。</p>' +
      '<p class="heir-amend" id="heirAmend" hidden>' +
      escapeHTML(LAW.amendment) +
      '</p>' +
      '<p class="heir-note">※ 依 ' +
      LAW.base +
      '，特留分以應繼財產扣除債務後計算；本表未計入債務、稅費、代位繼承、拋棄繼承、歸扣與胎兒。指定受益人之保險金不列入遺產，故不進分配表。</p>' +
      '</div>'
    );
  }

  /* ---------- 存取 ---------- */
  function loadCounts() {
    var out = {};
    HEIRS.forEach(function (h) {
      out[h.id] = DEFAULTS[h.id];
    });
    try {
      var raw = localStorage.getItem(STORE_KEY);
      if (!raw) return out;
      var saved = JSON.parse(raw);
      HEIRS.forEach(function (h) {
        if (saved && saved[h.id] != null) {
          var n = Math.round(Number(saved[h.id]));
          if (isFinite(n)) out[h.id] = clamp(n, 0, h.max);
        }
      });
    } catch (e) {
      /* 忽略壞資料，回到預設 */
    }
    return out;
  }

  function saveCounts(counts) {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(normalize(counts)));
    } catch (e) {
      /* 無痕模式或額度不足時忽略 */
    }
  }

  /* ---------- 掛載 ---------- */
  function mount(container, options) {
    if (!container) return null;

    var opts = options || {};
    var base = opts.base != null ? Math.max(0, Number(opts.base) || 0) : BASE_DEFAULT;
    var counts = loadCounts();
    var result = calculate(counts, base);

    container.innerHTML = buildHTML();
    container.classList.add('heir-mount');

    var el = {
      base: container.querySelector('#heirBase'),
      rows: container.querySelector('#heirRows'),
      totalShares: container.querySelector('#heirTotalShares'),
      totalAmount: container.querySelector('#heirTotalAmount'),
      totalReserved: container.querySelector('#heirTotalReserved'),
      totalReservedAmount: container.querySelector('#heirTotalReservedAmount'),
      free: container.querySelector('#heirFree'),
      freePct: container.querySelector('#heirFreePct'),
      warn: container.querySelector('#heirWarn'),
      amend: container.querySelector('#heirAmend'),
      vals: {},
      minus: {},
      plus: {}
    };

    HEIRS.forEach(function (h) {
      el.vals[h.id] = container.querySelector('#heir-' + h.id + 'Val');
      el.minus[h.id] = container.querySelector(
        'button[data-heir="' + h.id + '"][data-delta="-1"]'
      );
      el.plus[h.id] = container.querySelector(
        'button[data-heir="' + h.id + '"][data-delta="1"]'
      );
    });

    function render() {
      result = calculate(counts, base);
      var t = result.totals;

      el.base.textContent = fmtWan(base);

      HEIRS.forEach(function (h) {
        el.vals[h.id].textContent = counts[h.id];
        el.minus[h.id].disabled = counts[h.id] <= 0;
        el.plus[h.id].disabled = counts[h.id] >= h.max;
      });

      el.rows.innerHTML = result.rows.length
        ? result.rows
            .map(function (r) {
              return (
                '<tr>' +
                '<th scope="row">' +
                escapeHTML(r.label) +
                (r.note ? '<em class="hr-tag">' + escapeHTML(r.note) + '</em>' : '') +
                '</th>' +
                '<td><b>' +
                r.shareText +
                '</b><span>' +
                fmtWan(r.shareAmount) +
                '</span></td>' +
                '<td><b>' +
                r.reservedText +
                '</b><span>' +
                fmtWan(r.reservedAmount) +
                '</span></td>' +
                '</tr>'
              );
            })
            .join('')
        : '<tr><td colspan="3" class="hr-empty">目前沒有法定繼承人，遺產依法歸屬國庫（民法 §1185）。</td></tr>';

      el.totalShares.textContent = pct(t.shareRate, 0);
      el.totalAmount.textContent = fmtWan(base);
      el.totalReserved.textContent = pct(t.reservedRate);
      el.totalReservedAmount.textContent = fmtWan(t.reservedAmount);
      el.free.textContent = fmtWan(t.freeAmount);
      el.freePct.textContent = base > 0 ? '占遺產 ' + pct(t.freeAmount / base, 1) : '—';
      el.warn.hidden = result.hasHeirs;
      el.amend.hidden = !result.hasSiblings;
    }

    function emit() {
      try {
        document.dispatchEvent(new CustomEvent('estate:heirs-change', { detail: result }));
      } catch (e) {
        /* 舊瀏覽器不支援建構子時略過 */
      }
    }

    function commit() {
      saveCounts(counts);
      render();
      emit();
    }

    function change(id, delta) {
      var h = findHeir(id);
      if (!h) return;
      counts[id] = clamp((counts[id] || 0) + delta, 0, h.max);
      commit();
    }

    function applyPreset(id) {
      var preset = null;
      PRESETS.some(function (p) {
        if (p.id === id) {
          preset = p;
          return true;
        }
        return false;
      });
      if (!preset) return;
      HEIRS.forEach(function (h) {
        counts[h.id] = preset.counts[h.id] || 0;
      });
      commit();
    }

    container.addEventListener('click', function (ev) {
      var target = ev.target;
      if (!target || !target.closest) return;
      var heirBtn = target.closest('button[data-heir]');
      if (heirBtn && container.contains(heirBtn)) {
        change(heirBtn.getAttribute('data-heir'), Number(heirBtn.getAttribute('data-delta')) || 0);
        return;
      }
      var presetBtn = target.closest('button[data-preset]');
      if (presetBtn && container.contains(presetBtn)) {
        applyPreset(presetBtn.getAttribute('data-preset'));
      }
    });

    render();

    return {
      el: container,
      getResult: function () {
        return result;
      },
      getCounts: function () {
        return normalize(counts);
      },
      setBase: function (value) {
        base = Math.max(0, Number(value) || 0);
        render();
      },
      setCounts: function (patch) {
        if (!patch) return;
        HEIRS.forEach(function (h) {
          if (patch[h.id] != null) {
            var n = Math.round(Number(patch[h.id]));
            counts[h.id] = isFinite(n) ? clamp(n, 0, h.max) : 0;
          }
        });
        commit();
      },
      reset: function () {
        HEIRS.forEach(function (h) {
          counts[h.id] = DEFAULTS[h.id];
        });
        commit();
      }
    };
  }

  return {
    HEIRS: HEIRS,
    PRESETS: PRESETS,
    LAW: LAW,
    DEFAULTS: DEFAULTS,
    STORE_KEY: STORE_KEY,
    BASE_DEFAULT: BASE_DEFAULT,
    calculate: calculate,
    normalize: normalize,
    mount: mount,
    fmtWan: fmtWan
  };
});
