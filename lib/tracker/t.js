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

  // --- Attribution ---------------------------------------------------------
  // Where this visitor came from, for the host app to store in its OWN user
  // record and hand back via POST /api/v1/identify. We store nothing on the
  // device, so the durable copy lives in the customer's database — that
  // indirection is the whole cross-day attribution mechanism.
  //
  // Reflects THIS page load only; there is no first-touch cookie to read. Call
  // it on the landing page, not at the end of a signup funnel, or the funnel
  // reads as the source. Values are raw rather than grouped, and no medium is
  // invented when utm_medium is absent — both so the server can classify this
  // and the anonymous pageview identically onto one report row.
  // See docs/architecture/revenue.md.
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

  // The same values, shaped for Stripe Checkout metadata: keys prefixed so they
  // cannot collide with your own, values stringified and clipped to Stripe's
  // 500-character limit (a longer one fails the whole session).
  //
  //   metadata: tastatur.checkoutMetadata()
  //
  // Stripe stores these and hands them back on every event about the resulting
  // subscription, so attribution survives a closed tab, a rotated identifier, or
  // a payment completed days later on another device. Pass a saved attribution
  // object to use a first touch captured earlier instead of this page load.
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

  // The referring page's hostname, or null for direct traffic and self-referrals.
  // Self-referrals are dropped exactly as Ingest::Referrer drops them: a link
  // between two pages of the site is not a traffic source, and counting it as one
  // attributes every customer to the site's own domain.
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

  // NOT behind the `disabled` gate. DNT and GPC are objections to being measured
  // by US; this sends nothing anywhere and only hands the page its own query
  // string and referrer back. Gating it would break the customer's signup form
  // for every DNT visitor while honouring nothing.
  tastatur.attribution = attribution;
  tastatur.checkoutMetadata = checkoutMetadata;

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
