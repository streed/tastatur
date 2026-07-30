# Security policy

## Reporting a vulnerability

Please report privately, not in a public issue.

- **GitHub Security Advisories** — [open a private advisory](https://github.com/streed/tastatur/security/advisories/new).
  This is the preferred route: it gives us a private space to work in with you and
  produces a CVE and a published advisory at the end.
- **Email** — <security@reedster.llc>, if you would rather not use GitHub.

You will get an acknowledgement within **3 working days**. If you do not, assume
the message went astray and chase it, because that is a failure on our side rather
than a signal to give up.

Tastatur is maintained by [Reedster LLC](https://reedster.llc). It is a small
project and there is no bug bounty. What we can offer is a prompt reply, credit in
the advisory and changelog if you want it, and a straight answer about severity and
timing.

### What to include

Whatever you have. A rough report beats a polished one that never gets sent. If you
can, the useful parts are the affected version or commit, what an attacker gains,
and the smallest sequence of steps that shows it.

Please don't test against the hosted service at a scale that degrades it for other
people. `docker compose up` gives you a full local instance in a couple of minutes,
which is a better place to work anyway.

## Supported versions

Pre-1.0. The `main` branch is the supported version, and fixes go there. Once there
are tagged releases this section will say something more useful.

## What we consider a vulnerability

Ordinary web application security applies, and in a privacy tool three categories
carry more weight than they would elsewhere. Each of these maps to a specific
promise on the `/privacy` page.

**Anything that persists a visitor's IP address or user-agent string.** Not just to
the database — a log line, a temporary file, an exception payload sent to an error
tracker, or a debug parameter all count. The claim is that neither is ever written
anywhere, and that claim is either true or it is false.

**Anything that makes a destroyed salt recoverable.** The unlinkability claim rests
on yesterday's salt being gone. A salt reaching a disk, a backup, a replica, or a
key-derivation function that can regenerate it defeats the entire design, even if no
other bug is present. Details in [docs/privacy/identity.md](docs/privacy/identity.md).

**Anything that defeats the k-anonymity threshold.** Including indirectly: a
breakdown, filter combination, funnel, or export that lets someone reconstruct a
suppressed row by arithmetic. Complementary suppression exists because hiding one
small row protects nothing when its value is the reported total minus the visible
rows, and there may well be routes past it that we have not thought of.

Cross-tenant data access, authentication and authorisation bypass, and the ability
to write events into a site you do not own are all in scope too, on the usual terms.

## What is out of scope

- Missing rate limits on endpoints that are not the ingest path, unless you can
  show real impact.
- Vulnerabilities in a self-hosted instance's own infrastructure — your reverse
  proxy, your database, your network. We will happily fix our documentation if it
  led you somewhere unsafe.
- Reports from automated scanners with no demonstrated impact.
- Anything requiring a modified client, since the tracker runs on the visitor's
  machine and is assumed to be under their control. Note the difference from
  **writing events into someone else's site**, which is in scope: see
  [docs/architecture/ingest.md](docs/architecture/ingest.md) for the hostname
  checks that exist for exactly that reason.
- The absence of a cookie consent banner. That is the point of the product, and
  [docs/privacy/claims.md](docs/privacy/claims.md) sets out the reasoning along
  with what we will and will not claim about it.

## Disclosure

Report privately, we fix it, then it gets published — advisory, changelog entry,
and credit unless you would rather stay anonymous. We are not going to ask you to
sit on a finding indefinitely. If a fix is taking us a long time, we would rather
agree a date with you than let it drift.

If a vulnerability affects self-hosted instances, the advisory will say plainly what
operators need to do, because they cannot rely on us deploying a fix for them.
