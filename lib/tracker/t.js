/*!
 * Tastatur — cookieless web analytics.  https://tastatur.dev
 * AGPL-3.0. Served as-is; no build step. What you are reading is what runs.
 *
 * This script sets no cookie and reads none; writes nothing to localStorage
 * or sessionStorage; generates no device or browser identifier; and reads
 * nothing used for fingerprinting (canvas, WebGL, fonts, audio, plugins).
 * Everything it sends is listed in `payload()` below, and that is the whole
 * list — if you are auditing this file, that function is the only place data
 * leaves the page.
 */
(function () {
  'use strict';

  var script = document.currentScript;
  if (!script) return;

  var siteToken = script.getAttribute('data-site');
  if (!siteToken) return;

  // Derived from this script's own URL, so proxying the script through your
  // own domain proxies the events with it.
  var endpoint = script.getAttribute('data-api') ||
                 script.src.replace(/\/[^/]+$/, '/api/event');

  var trackHash = script.hasAttribute('data-hash');
  var autoPageviews = script.getAttribute('data-auto') !== 'false';

  // Do Not Track / Global Privacy Control are honoured BY DEFAULT. We store
  // nothing on the device, so a request header is the only opt-out a visitor
  // has. What `data-ignore-dnt` forfeits is covered in the docs under Opt-out.
  function optedOut() {
    if (script.hasAttribute('data-ignore-dnt')) return false;
    var dnt = navigator.doNotTrack || window.doNotTrack || navigator.msDoNotTrack;
    if (dnt === '1' || dnt === 'yes') return true;
    if (navigator.globalPrivacyControl === true) return true;
    return false;
  }

  // Local development and preview deploys would otherwise pollute real stats.
  // file:// and about: are included because a page saved to disk still runs.
  function excludedHost() {
    var h = location.hostname;
    if (location.protocol === 'file:' || location.protocol === 'about:') return true;
    if (script.hasAttribute('data-exclude')) return true;
    return h === 'localhost' || h === '127.0.0.1' || h === '::1' ||
           h === '0.0.0.0' || /\.local$/.test(h) || /^192\.168\./.test(h);
  }

  var disabled = optedOut() || excludedHost();

  // Only utm_* survives. The rest of the query string is dropped before the
  // URL ever leaves the page: query strings routinely carry email addresses,
  // reset tokens and session ids, and none of that should reach an analytics
  // server — ours included.
  var UTM = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];

  function currentUrl() {
    var params = [];
    try {
      var search = new URLSearchParams(location.search);
      for (var i = 0; i < UTM.length; i++) {
        var v = search.get(UTM[i]);
        if (v) params.push(UTM[i] + '=' + encodeURIComponent(v));
      }
    } catch (e) { /* URLSearchParams missing: send no params at all */ }

    return location.protocol + '//' + location.host + location.pathname +
           (params.length ? '?' + params.join('&') : '') +
           (trackHash ? location.hash : '');
  }

  // sendBeacon is the only transport that survives the page being closed,
  // which is exactly when the last pageview of a visit fires.
  function send(body) {
    var json = JSON.stringify(body);

    if (navigator.sendBeacon) {
      // text/plain keeps this a CORS simple request: no preflight per pageview.
      var blob = new Blob([json], { type: 'text/plain;charset=UTF-8' });
      if (navigator.sendBeacon(endpoint, blob)) return;
    }

    if (window.fetch) {
      fetch(endpoint, {
        method: 'POST',
        body: json,
        keepalive: true,
        credentials: 'omit',
        mode: 'cors',
        headers: { 'Content-Type': 'text/plain;charset=UTF-8' }
      })['catch'](function () {});
      return;
    }

    try {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', endpoint, true);
      xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
      xhr.send(json);
    } catch (e) { /* nothing further to try; losing a pageview is acceptable */ }
  }

  // THIS IS THE COMPLETE LIST of what is transmitted.
  function payload(name, options) {
    var body = {
      s: siteToken,
      u: currentUrl(),
      n: name || 'pageview',
      r: document.referrer || null,
      w: window.innerWidth || 0
    };
    if (options && options.props) body.p = options.props;
    if (options && options.revenue) {
      body.v = options.revenue.amount;
      body.c = options.revenue.currency;
    }
    return body;
  }

  // Where this visitor came from, for the host app to store in its OWN user
  // record and hand back via POST /api/v1/identify. Reflects THIS page load
  // only — call it on the landing page, not at the end of a signup funnel.
  // Values stay raw, and no medium is invented when utm_medium is absent, so
  // the server classifies this and the anonymous pageview onto one report row.
  // Full mechanism: docs/architecture/revenue.md.
  function attribution() {
    var out = { landing_path: location.pathname, first_seen_at: new Date().toISOString() };

    try {
      var search = new URLSearchParams(location.search);
      for (var i = 0; i < UTM.length; i++) {
        var v = search.get(UTM[i]);
        // 'utm_source' -> 'source', matching the identify endpoint's field names.
        if (v) out[UTM[i].slice(4)] = v;
      }
    } catch (e) { /* URLSearchParams missing: UTM tags are simply absent */ }

    var host = referrerHost();
    if (host) out.referrer_host = host;

    return out;
  }

  // The same values shaped for Stripe Checkout metadata: keys prefixed so they
  // cannot collide with yours, values clipped to Stripe's 500-character limit
  // (a longer one fails the whole session). Pass a saved attribution object to
  // use a first touch captured earlier instead of this page load.
  var META_PREFIX = 'tst_';
  var META_MAX = 500;

  function checkoutMetadata(saved) {
    var data = saved || attribution();
    var out = {};

    for (var key in data) {
      if (!Object.prototype.hasOwnProperty.call(data, key)) continue;
      var value = data[key];
      if (value === null || value === undefined || value === '') continue;
      out[META_PREFIX + key] = String(value).slice(0, META_MAX);
    }

    return out;
  }

  // Referrer hostname, or null for direct traffic and self-referrals, which
  // are dropped exactly as the server drops them: a link between two pages of
  // one site is not a traffic source.
  function referrerHost() {
    if (!document.referrer) return null;

    try {
      var h = new URL(document.referrer).hostname.replace(/^www\./, '');
      var self = location.hostname.replace(/^www\./, '');
      if (h === self || h.slice(-(self.length + 1)) === '.' + self) return null;
      return h;
    } catch (e) {
      return null;
    }
  }

  // --- Public API ----------------------------------------------------------
  //   tastatur('pageview')
  //   tastatur('event', 'Signup', { props: { plan: 'pro' } })
  //   tastatur('event', 'Purchase', { revenue: { amount: 4900, currency: 'EUR' } })
  //   tastatur.attribution()       -> { source, medium, campaign, landing_path, ... }
  //   tastatur.checkoutMetadata()  -> { tst_source: '...', ... } for Stripe
  function tastatur(action, name, options) {
    if (disabled) return;
    if (action === 'pageview') return send(payload('pageview', name));
    if (action === 'event') return send(payload(name, options));
  }

  // Deliberately NOT behind the `disabled` gate: these send nothing anywhere
  // and only hand the page its own query string and referrer back. Gating them
  // would break the customer's signup form for every DNT visitor while
  // honouring nothing.
  tastatur.attribution = attribution;
  tastatur.checkoutMetadata = checkoutMetadata;

  // Drain anything queued by the stub before this script finished loading.
  var queued = window.tastatur && window.tastatur.q;
  window.tastatur = tastatur;
  if (queued) for (var i = 0; i < queued.length; i++) tastatur.apply(null, queued[i]);

  if (disabled || !autoPageviews) return;

  // Deduplicated against the last URL sent, or frameworks that call
  // replaceState during hydration would double-count every initial pageview.
  var lastUrl = null;

  function pageview() {
    var url = currentUrl();
    if (url === lastUrl) return;
    lastUrl = url;
    send(payload('pageview'));
  }

  // Patch the history API so client-side routing is counted; the originals
  // are always called, so nothing downstream sees a difference.
  function patch(method) {
    var original = history[method];
    if (!original) return;
    history[method] = function () {
      var result = original.apply(this, arguments);
      pageview();
      return result;
    };
  }
  patch('pushState');
  patch('replaceState');

  window.addEventListener('popstate', pageview);
  if (trackHash) window.addEventListener('hashchange', pageview);

  // A page restored from the back/forward cache does not re-run this script,
  // so its second view would otherwise go uncounted.
  window.addEventListener('pageshow', function (e) { if (e.persisted) pageview(); });

  pageview();
})();
