var __StripeExtExports = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // .build/manifest.js
  var manifest_exports = {};
  __export(manifest_exports, {
    BUILD_TIME: () => BUILD_TIME,
    default: () => manifest_default
  });
  var BUILD_TIME = "2026-07-31 10:04:35.162276848 -0700 PDT m=+2.469633920";
  var manifest_default = {
    "$schema": "https://stripe.com/stripe-app.schema.json",
    "allowed_redirect_uris": [
      "https://tastatur.dev/stripe/connect/callback",
      "https://localhost:3443/stripe/connect/callback"
    ],
    "distribution_type": "public",
    "icon": "./icon_32.png",
    "id": "dev.tastatur.revenue",
    "name": "Tastatur",
    "permissions": [
      {
        "permission": "customer_read",
        "purpose": "Match your Stripe customers to their signup so revenue can be attributed to the marketing channel that produced them."
      },
      {
        "permission": "checkout_session_read",
        "purpose": "Read the attribution metadata your checkout attaches, which is how a payment is tied back to a first visit."
      },
      {
        "permission": "subscription_read",
        "purpose": "Follow subscription starts, changes and cancellations to compute MRR per acquisition channel."
      },
      {
        "permission": "invoice_read",
        "purpose": "Record paid and failed invoices as the revenue behind each channel."
      },
      {
        "permission": "charge_read",
        "purpose": "Record refunds so attributed revenue goes down when money is returned."
      },
      {
        "permission": "dispute_read",
        "purpose": "Record chargebacks so attributed revenue reflects disputed payments."
      },
      {
        "permission": "event_read",
        "purpose": "Receive webhook events for the objects above as they change, instead of polling your account."
      }
    ],
    "sandbox_install_compatible": true,
    "stripe_api_access_type": "oauth",
    "version": "0.0.1"
  };
  return __toCommonJS(manifest_exports);
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsibWFuaWZlc3QuanMiXSwKICAic291cmNlc0NvbnRlbnQiOiBbIi8vIEFVVE9HRU5FUkFURUQgLSBETyBOT1QgTU9ESUZZXG5cbi8vIFRpbWVzdGFtcCBjaGFuZ2VzIG9uIGV2ZXJ5IGV4cG9ydCwgZW5zdXJpbmcgdGhlIGRldiBzZXJ2ZXIgZGV0ZWN0cyBhIHJlYnVpbGRcbmV4cG9ydCBjb25zdCBCVUlMRF9USU1FID0gJzIwMjYtMDctMzEgMTA6MDQ6MzUuMTYyMjc2ODQ4IC0wNzAwIFBEVCBtPSsyLjQ2OTYzMzkyMCc7XG5cbi8vIEFwcCBtYW5pZmVzdCBcdTIwMTQgY29uc3VtZWQgYnkgdGhlIERhc2hib2FyZCB0byBjb25maWd1cmUgdGhlIGFwcFxuZXhwb3J0IGRlZmF1bHQge1xuICBcIiRzY2hlbWFcIjogXCJodHRwczovL3N0cmlwZS5jb20vc3RyaXBlLWFwcC5zY2hlbWEuanNvblwiLFxuICBcImFsbG93ZWRfcmVkaXJlY3RfdXJpc1wiOiBbXG4gICAgXCJodHRwczovL3Rhc3RhdHVyLmRldi9zdHJpcGUvY29ubmVjdC9jYWxsYmFja1wiLFxuICAgIFwiaHR0cHM6Ly9sb2NhbGhvc3Q6MzQ0My9zdHJpcGUvY29ubmVjdC9jYWxsYmFja1wiXG4gIF0sXG4gIFwiZGlzdHJpYnV0aW9uX3R5cGVcIjogXCJwdWJsaWNcIixcbiAgXCJpY29uXCI6IFwiLi9pY29uXzMyLnBuZ1wiLFxuICBcImlkXCI6IFwiZGV2LnRhc3RhdHVyLnJldmVudWVcIixcbiAgXCJuYW1lXCI6IFwiVGFzdGF0dXJcIixcbiAgXCJwZXJtaXNzaW9uc1wiOiBbXG4gICAge1xuICAgICAgXCJwZXJtaXNzaW9uXCI6IFwiY3VzdG9tZXJfcmVhZFwiLFxuICAgICAgXCJwdXJwb3NlXCI6IFwiTWF0Y2ggeW91ciBTdHJpcGUgY3VzdG9tZXJzIHRvIHRoZWlyIHNpZ251cCBzbyByZXZlbnVlIGNhbiBiZSBhdHRyaWJ1dGVkIHRvIHRoZSBtYXJrZXRpbmcgY2hhbm5lbCB0aGF0IHByb2R1Y2VkIHRoZW0uXCJcbiAgICB9LFxuICAgIHtcbiAgICAgIFwicGVybWlzc2lvblwiOiBcImNoZWNrb3V0X3Nlc3Npb25fcmVhZFwiLFxuICAgICAgXCJwdXJwb3NlXCI6IFwiUmVhZCB0aGUgYXR0cmlidXRpb24gbWV0YWRhdGEgeW91ciBjaGVja291dCBhdHRhY2hlcywgd2hpY2ggaXMgaG93IGEgcGF5bWVudCBpcyB0aWVkIGJhY2sgdG8gYSBmaXJzdCB2aXNpdC5cIlxuICAgIH0sXG4gICAge1xuICAgICAgXCJwZXJtaXNzaW9uXCI6IFwic3Vic2NyaXB0aW9uX3JlYWRcIixcbiAgICAgIFwicHVycG9zZVwiOiBcIkZvbGxvdyBzdWJzY3JpcHRpb24gc3RhcnRzLCBjaGFuZ2VzIGFuZCBjYW5jZWxsYXRpb25zIHRvIGNvbXB1dGUgTVJSIHBlciBhY3F1aXNpdGlvbiBjaGFubmVsLlwiXG4gICAgfSxcbiAgICB7XG4gICAgICBcInBlcm1pc3Npb25cIjogXCJpbnZvaWNlX3JlYWRcIixcbiAgICAgIFwicHVycG9zZVwiOiBcIlJlY29yZCBwYWlkIGFuZCBmYWlsZWQgaW52b2ljZXMgYXMgdGhlIHJldmVudWUgYmVoaW5kIGVhY2ggY2hhbm5lbC5cIlxuICAgIH0sXG4gICAge1xuICAgICAgXCJwZXJtaXNzaW9uXCI6IFwiY2hhcmdlX3JlYWRcIixcbiAgICAgIFwicHVycG9zZVwiOiBcIlJlY29yZCByZWZ1bmRzIHNvIGF0dHJpYnV0ZWQgcmV2ZW51ZSBnb2VzIGRvd24gd2hlbiBtb25leSBpcyByZXR1cm5lZC5cIlxuICAgIH0sXG4gICAge1xuICAgICAgXCJwZXJtaXNzaW9uXCI6IFwiZGlzcHV0ZV9yZWFkXCIsXG4gICAgICBcInB1cnBvc2VcIjogXCJSZWNvcmQgY2hhcmdlYmFja3Mgc28gYXR0cmlidXRlZCByZXZlbnVlIHJlZmxlY3RzIGRpc3B1dGVkIHBheW1lbnRzLlwiXG4gICAgfSxcbiAgICB7XG4gICAgICBcInBlcm1pc3Npb25cIjogXCJldmVudF9yZWFkXCIsXG4gICAgICBcInB1cnBvc2VcIjogXCJSZWNlaXZlIHdlYmhvb2sgZXZlbnRzIGZvciB0aGUgb2JqZWN0cyBhYm92ZSBhcyB0aGV5IGNoYW5nZSwgaW5zdGVhZCBvZiBwb2xsaW5nIHlvdXIgYWNjb3VudC5cIlxuICAgIH1cbiAgXSxcbiAgXCJzYW5kYm94X2luc3RhbGxfY29tcGF0aWJsZVwiOiB0cnVlLFxuICBcInN0cmlwZV9hcGlfYWNjZXNzX3R5cGVcIjogXCJvYXV0aFwiLFxuICBcInZlcnNpb25cIjogXCIwLjAuMVwiXG59O1xuIl0sCiAgIm1hcHBpbmdzIjogIjs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7QUFBQTtBQUFBO0FBQUE7QUFBQTtBQUFBO0FBR08sTUFBTSxhQUFhO0FBRzFCLE1BQU8sbUJBQVE7QUFBQSxJQUNiLFdBQVc7QUFBQSxJQUNYLHlCQUF5QjtBQUFBLE1BQ3ZCO0FBQUEsTUFDQTtBQUFBLElBQ0Y7QUFBQSxJQUNBLHFCQUFxQjtBQUFBLElBQ3JCLFFBQVE7QUFBQSxJQUNSLE1BQU07QUFBQSxJQUNOLFFBQVE7QUFBQSxJQUNSLGVBQWU7QUFBQSxNQUNiO0FBQUEsUUFDRSxjQUFjO0FBQUEsUUFDZCxXQUFXO0FBQUEsTUFDYjtBQUFBLE1BQ0E7QUFBQSxRQUNFLGNBQWM7QUFBQSxRQUNkLFdBQVc7QUFBQSxNQUNiO0FBQUEsTUFDQTtBQUFBLFFBQ0UsY0FBYztBQUFBLFFBQ2QsV0FBVztBQUFBLE1BQ2I7QUFBQSxNQUNBO0FBQUEsUUFDRSxjQUFjO0FBQUEsUUFDZCxXQUFXO0FBQUEsTUFDYjtBQUFBLE1BQ0E7QUFBQSxRQUNFLGNBQWM7QUFBQSxRQUNkLFdBQVc7QUFBQSxNQUNiO0FBQUEsTUFDQTtBQUFBLFFBQ0UsY0FBYztBQUFBLFFBQ2QsV0FBVztBQUFBLE1BQ2I7QUFBQSxNQUNBO0FBQUEsUUFDRSxjQUFjO0FBQUEsUUFDZCxXQUFXO0FBQUEsTUFDYjtBQUFBLElBQ0Y7QUFBQSxJQUNBLDhCQUE4QjtBQUFBLElBQzlCLDBCQUEwQjtBQUFBLElBQzFCLFdBQVc7QUFBQSxFQUNiOyIsCiAgIm5hbWVzIjogW10KfQo=
