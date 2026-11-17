# Live chart serves a scriptless page on loopback and renews no lease

## Decision

`chart` is an observer operation (Lab only; the target runs no new code).
It reads a session through the ordinary read APIs under its own reader
(`chart-` and 8 hex characters, or `--reader`), so the page discloses exactly
what those reads disclose under the session's effective profile, and no other
reader's cursor or view moves.

**The page.**

- It is one HTML document with inline SVG and one inline style block. It has
  no script, font, image, link or URL.
- Every string is HTML-escaped. A Content-Security-Policy meta tag allows no
  script and only that style block, by its SHA-256.
- The live form refreshes with `<meta http-equiv="refresh">`, so it needs no
  script either.

**The static artifact** (`chart`, `--out PATH`):

- A new file only. The page goes into a temp file that the call creates
  exclusively in the destination's directory, set to mode 0600 before
  anything is written, then hard-linked to the path. A path that exists, a
  symlink included, is refused (`invalid_options`, `--out`, `exists`) and
  never followed or replaced.
- Without `--out`, the file goes under the system temp directory. Its name
  carries 64 random bits.
- It prints `insider.live-chart/v1`:
  - `path`, `session_id`, `reader` and `headline`;
  - `series` and `not_recorded`;
  - counts of `marks`, `anomalies` and `events`;
  - `complete`, and `incomplete` as `{reason, detail}` notes.
- Reasons are `max_entries` (the chart keeps the newest 20,000 events),
  `no_progress`, `digest_incomplete` and `evicted`. The page shows the same
  notes, and greys the stretch it could not read.

**The live server** (`chart --serve`):

- The observer process serves the page with OTP's `:gen_tcp`. There is no new
  dependency, and nothing runs in the target.
- It listens on 127.0.0.1 only, on a random port by default (`--port`).
- The page is served only at a 256-bit random token path; any other path
  gets 404.
- A request whose `Host` is not `127.0.0.1:PORT` or `localhost:PORT` gets 421,
  which defeats DNS rebinding. Any method but GET gets 405.
- It serves one connection at a time, with bounded request line, header
  count, header bytes and time.
- Responses carry the CSP plus `frame-ancestors 'none'`, `no-store`,
  `nosniff` and `no-referrer`, and no CORS headers.
- **No lease renewal.** From its first read on, it uses only reads that
  renew nothing: `status`, `marks`, `events_since/3` with the new read
  option `"renew" => false`, and a subscription.
- **Profile changes.** When `status` reports a profile other than the one
  the chart holds, it drops everything it holds and reads the window again
  under the new profile before drawing the next page.
- **Stopping.** It stops at `--for` (default 30 minutes), on SIGTERM, when
  the target goes down, or when the session ends. After the session ends,
  the final page stays up for 5 seconds, or for what is left of `--for` if
  that is shorter.

## Why

A programmer paired with an agent had nothing to look at; the agent's
digests and events are text for the agent. A page the programmer opens on
their own machine is the smallest useful surface. Computing it in the
observer from read-API data keeps the disclosure rules in one place and the
target unchanged.

The idea is credited to [Orion](https://github.com/LivewareProblems/Orion)
(Thomas Depierre), a distributed dynamic profiler for the BEAM that charts a
traced function's latency live. Insider does not depend on Orion or copy its
code: Orion is a LiveView page mounted in the host's router and aims at
production, while Insider stays outside the target and in development.

- **No script.** A page without script cannot be turned into an exfiltration
  or command channel, even through an escaping mistake. The CSP enforces it.
- **The server's limits.** The server is a new listening socket on the
  developer's machine, so it must not be reachable from elsewhere, by
  another origin, or by a guessed URL. Those risks are what the loopback
  bind, the token, the Host check, the GET-only rule and the absence of CORS
  answer.
- **Renewing no lease.** A watcher that renewed the lease would keep a
  session alive for as long as a browser tab stayed open. So the live form
  renews nothing, and says so on the page. The static form is one read
  command, and renews once like any other.
- **Hard link, not rename.** A rename would replace an existing file. A hard
  link fails on any existing name, a symlink included, without following it.

## Consequences

- `"renew"` is a new, additive read option of `events_since/3` (default
  `true`). Like any read option, it is listed in the welcome options table.
- A live chart attached to a session near its expiry does not extend it. The
  page shows the lease that is left.
- When the profile narrows, the page can show the old profile's data for up
  to one refresh (about a second) before the chart reads the window again.
- A filesystem without hard links cannot take a static chart. The error
  names the reason.
- `insider.live-chart/v1` and the served page's headers are a contract; a
  change to either needs a new decision.
