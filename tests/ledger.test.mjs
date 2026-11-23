// Tests for the gold log (Ledger.lua): which action a money change belongs to,
// and what reaches the trade record. Run: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const ITEMS = `
  ITEMS[2589] = { name = "Linen Cloth", sell = 13 }
  ITEMS[2318] = { name = "Light Leather", sell = 15 }
  ITEMS[2319] = { name = "Medium Leather", sell = 25 }
  ITEMS[5000] = { name = "Quest Thing", sell = 0 }
`;
const vm = () => {
  const v = luaVM();
  v.run(ITEMS);
  return v;
};

// A sale mail for `count` of an item: money = bid - cut + deposit.
const saleMail = (item, count, bid, cut, deposit) =>
  `{ sender = "Auction House", subject = "Auction successful: ${item}", money = ${bid - cut + deposit},
     invoice = { item = "${item}", bid = ${bid}, cut = ${cut}, deposit = ${deposit}, count = ${count} } }`;

test("harness: selling one stack to a vendor is logged and recorded", () => {
  const { run, log, trade } = vm();
  run(`FIRE("MERCHANT_SHOW")
       BAGS[0] = { [1] = { id = 2318, count = 20 } }
       C_Container.UseContainerItem(0, 1)
       GAIN(300)`);
  assert.deepEqual(log(), ["vendor_sell 300 2318 x20"]);
  assert.deepEqual(trade(), ["Vendored 2318 20 300"]);
});

test("harness: one AH sale mail is logged as a sale, the deposit apart", () => {
  const { run, log, trade } = vm();
  run(`INBOX[1] = ${saleMail("Linen Cloth", 20, 1000, 50, 30)}
       TakeInboxMoney(1)
       SERVER_TAKE_MONEY(1)`);
  assert.deepEqual(log(), ["ah_sale 950 x20", "ah_deposit_back 30"]);
  assert.deepEqual(trade(), ["Sale 2589 20 950"]);
});
