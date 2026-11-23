// Test helper: a stand-in for Blizzard's API, loaded with
//   node --import ./poller/fake-bnet.mjs poller/ah.mjs
// FAKE_BNET is the path of a JSON file:
//   { houses: [{ id, name }],
//     data: { "<house>": { auctions: [...], commodities: [...], lm, clm, status, throws } },
//     tokenFailures: n,    // first n token requests throw a network error
//     saddlebag: [...] }   // Saddlebag Exchange's answer (default: HTTP 500)
// Every request is appended to <FAKE_BNET>.log (one line: url and whether it had a signal).
import { readFileSync, appendFileSync } from "node:fs";

const file = process.env.FAKE_BNET;
const spec = JSON.parse(readFileSync(file, "utf8"));
let tokenCalls = 0;

const json = (body, headers = {}, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

globalThis.fetch = async (input, init = {}) => {
  const url = new URL(String(input));
  appendFileSync(file + ".log", `${url.host}${url.pathname} signal=${!!init.signal}\n`);
  if (url.host === "oauth.battle.net") {
    if (tokenCalls++ < (spec.tokenFailures ?? 0)) throw new TypeError("fetch failed");
    return json({ access_token: "t" });
  }
  if (url.host.includes("saddlebag")) return spec.saddlebag ? json(spec.saddlebag) : json({}, {}, 500);
  const m = url.pathname.match(/\/auctions\/(\d+)(\/commodities)?$/);
  if (!m) return json({ auctions: spec.houses.map((h) => ({ id: h.id, name: h.name })) });
  const d = spec.data[m[1]] ?? {};
  if (d.throws) throw new TypeError("fetch failed");
  if (d.status) return json({}, {}, d.status);
  return m[2]
    ? json({ auctions: d.commodities ?? [] }, d.clm ? { "last-modified": d.clm } : {})
    : json({ auctions: d.auctions ?? [] }, d.lm ? { "last-modified": d.lm } : {});
};
