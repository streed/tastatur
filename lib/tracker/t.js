/*!
 * Tastatur — cookieless web analytics.  https://tastatur.dev
 * AGPL-3.0. This file is served as-is; there is no build step and no bundler.
 *
 * WHAT THIS SCRIPT DOES NOT DO, and will not be changed to do:
 *   - it sets no cookie, and reads none
 *   - it writes nothing to localStorage or sessionStorage
 *   - it generates no device or browser identifier
 *   - it does not read canvas, WebGL, fonts, audio, plugins, battery,
 *     hardware concurrency, or anything else used for fingerprinting
 *
 * Everything it sends is listed in `payload()` below, and that is the whole
 * list. If you are auditing this file, that function is the only place data
 * leaves the page.
 */
(function () {
  'use strict';

  var script = document.currentScript;
  if (!script) return;

  var siteToken = script.getAttribute('data-site');
  if (!siteToken) return;

  // The endpoint is derived from this script's own URL rather than baked in at
  // build time, so proxying the script through your own domain automatically
  // proxies the events with it — nothing to reconfigure.
  var endpoint = script.getAttribute('data-api') ||
                 script.src.replace(/\/[^/]+$/, '/api/event');

  var trackHash = script.hasAttribute('data-hash');
  var autoPageviews = script.getAttribute('data-auto') !== 'false';

  // --- Opt-outs ------------------------------------------------------------
  // Honouring Do Not Track / Global Privacy Control is how an individual opts
  // out of Tastatur. We cannot offer a per-person opt-out flag the usual way,
  // because storing one would mean writing to localStorage — the exact thing
  // this script promises not to do.
  // Both are honoured BY DEFAULT. A working opt-out is a condition of the
  // consent exemption we rely on (CNIL's audience-measurement criteria, and the
  // UK DUAA statistical-purposes exception), and since we store nothing on the
  // device, a request header is the only durable objection signal available to
  // us. `data-ignore-dnt` turns it off for operators who have their own basis —
  // it is documented as likely forfeiting that exemption argument.
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

  // --- URL handling --------------------------------------------------------
  // Only utm_* survives. Everything else in a query string is dropped before
  // the URL ever leaves the page: query strings routinely carry email
  // addresses, password-reset tokens and session ids, and none of that should
  // reach an analytics server — ours included.
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

  // --- Transport -----------------------------------------------------------
  // sendBeacon is the only transport that reliably survives the page being
  // closed or navigated away from, which is exactly when the last pageview of
  // a visit fires. The others are fallbacks for browsers that lack it.
  function send(body) {
    var json = JSON.stringify(body);

    if (navigator.sendBeacon) {
      // Content-Type text/plain keeps this a CORS "simple request", so the
      // browser does not fire a preflight OPTIONS before every pageview.
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

  // --- Public API ----------------------------------------------------------
  //   tastatur('pageview')
  //   tastatur('event', 'Signup', { props: { plan: 'pro' } })
  //   tastatur('event', 'Purchase', { revenue: { amount: 4900, currency: 'EUR' } })
  function tastatur(action, name, options) {
    if (disabled) return;
    if (action === 'pageview') return send(payload('pageview', name));
    if (action === 'event') return send(payload(name, options));
  }

  // Drain anything queued by the stub before this script finished loading.
  var queued = window.tastatur && window.tastatur.q;
  window.tastatur = tastatur;
  if (queued) for (var i = 0; i < queued.length; i++) tastatur.apply(null, queued[i]);

  if (disabled || !autoPageviews) return;

  // --- Automatic pageviews -------------------------------------------------
  // Deduplicated against the last URL sent. Without this, frameworks that call
  // replaceState during hydration would double-count the initial pageview on
  // every single page load.
  var lastUrl = null;

  function pageview() {
    var url = currentUrl();
    if (url === lastUrl) return;
    lastUrl = url;
    send(payload('pageview'));
  }

  // Patch the history API so client-side routing is picked up. The original
  // functions are always called, so nothing downstream sees a difference.
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

  // A page restored from the browser's back/forward cache does not re-run this
  // script, so its second view would otherwise go uncounted.
  window.addEventListener('pageshow', function (e) { if (e.persisted) pageview(); });

  pageview();
})();
