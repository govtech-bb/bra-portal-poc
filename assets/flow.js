/* Conditional flow routing for the Personal Income Tax return.
 *
 * The gateway page (file-return-income-types.html) records which income
 * types the user picked. Every subsequent page asks this script "what's
 * next?" and "what's previous?" and only routes through pages whose
 * `requires` is satisfied. Always-on pages have no `requires`.
 *
 * Selections live in localStorage under 'alpha-bra-income-types' as a
 * JSON array of values matching the checkbox `value` attributes on the
 * gateway page (employment, pension, business, residential-rent,
 * investments-bb, investments-foreign, agriculture, cultural,
 * foreign-currency, pension-refund).
 */
(function () {
  'use strict';

  // Order of pages in the flow. `requires` is the income-type value(s)
  // from the gateway. Omit `requires` for pages that are always shown.
  var FLOW = [
    { page: 'file-return.html' },
    { page: 'file-return-about.html' },
    { page: 'file-return-income-types.html' },
    { page: 'file-return-employment.html',       requires: 'employment' },
    { page: 'file-return-pension.html',          requires: ['pension', 'pension-refund'] },
    { page: 'file-return-investments.html',      requires: ['investments-bb', 'investments-foreign'] },
    { page: 'file-return-business.html',         requires: 'business' },
    { page: 'file-return-agriculture.html',      requires: 'agriculture' },
    { page: 'file-return-cultural.html',         requires: 'cultural' },
    { page: 'file-return-energy.html' },               // everyone can claim
    { page: 'file-return-rental.html',           requires: 'residential-rent' },
    { page: 'file-return-foreign-currency.html', requires: 'foreign-currency' },
    { page: 'file-return-allowances.html' },
    { page: 'file-return-refund-method.html' },
    { page: 'file-return-documents.html' },
    { page: 'file-return-check.html' },
    { page: 'file-return-confirmation.html' }
  ];

  var STORAGE_KEY = 'alpha-bra-income-types';

  function readTypes() {
    try {
      var raw = localStorage.getItem(STORAGE_KEY);
      return new Set(raw ? JSON.parse(raw) : []);
    } catch (e) {
      return new Set();
    }
  }

  function writeTypes(arr) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(arr)); }
    catch (e) { /* private mode — ignore */ }
  }

  function isApplicable(entry, types) {
    if (!entry.requires) return true;
    var req = [].concat(entry.requires);
    for (var i = 0; i < req.length; i++) {
      if (types.has(req[i])) return true;
    }
    return false;
  }

  function findIndex(page) {
    for (var i = 0; i < FLOW.length; i++) {
      if (FLOW[i].page === page) return i;
    }
    return -1;
  }

  function nextPage(current, types) {
    for (var i = findIndex(current) + 1; i < FLOW.length; i++) {
      if (isApplicable(FLOW[i], types)) return FLOW[i].page;
    }
    return null;
  }

  function prevPage(current, types) {
    for (var i = findIndex(current) - 1; i >= 0; i--) {
      if (isApplicable(FLOW[i], types)) return FLOW[i].page;
    }
    return null;
  }

  function currentPage() {
    var parts = location.pathname.split('/');
    return parts[parts.length - 1] || 'index.html';
  }

  function init() {
    var here = currentPage();
    var types = readTypes();

    // The gateway captures the user's selections at submit time and then
    // routes to whichever conditional page comes first.
    if (here === 'file-return-income-types.html') {
      var gateForm = document.querySelector('form');
      if (gateForm) {
        gateForm.addEventListener('submit', function () {
          var checked = [].slice.call(
            document.querySelectorAll('input[name="income-type"]:checked')
          ).map(function (el) { return el.value; });
          writeTypes(checked);
          var nxt = nextPage(here, new Set(checked));
          if (nxt) gateForm.action = nxt;
        });
      }
      return;
    }

    // Every other page: rewrite the form action and the back link.
    var form = document.querySelector('form.form-page');
    if (form) {
      var nxt = nextPage(here, types);
      if (nxt) form.action = nxt;
    }

    var back = document.querySelector('a.back-link');
    if (back) {
      var prev = prevPage(here, types);
      if (prev) back.setAttribute('href', prev);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
