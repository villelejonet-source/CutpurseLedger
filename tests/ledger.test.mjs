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

const expired = (item, id, count) => `{ sender = "Auction House", subject = "Auction expired: ${item}", items = { [1] = { id = ${id}, count = ${count} } } }`;

test("B1: two expired mails for the same item, opened in a row, are two returns", () => {
  const { run, trade } = vm();
  run(`INBOX[1] = ${expired("Linen Cloth", 2589, 20)}
       INBOX[2] = ${expired("Linen Cloth", 2589, 20)}
       AutoLootMailItem(1); SERVER_TAKE_ITEM(1, 1)   -- first mail emptied and removed; the second moves up
       ADVANCE(1)
       AutoLootMailItem(1); SERVER_TAKE_ITEM(1, 1)`);
  assert.deepEqual(trade(), ["Returned 2589 20", "Returned 2589 20"]);
});

test("B1: with full bags, clicking the same mail again later records nothing until the items really arrive", () => {
  const { run, trade } = vm();
  run(`INBOX[1] = ${expired("Linen Cloth", 2589, 20)}
       TakeInboxItem(1, 1); FIRE("MAIL_INBOX_UPDATE")   -- bags full: nothing moves
       ADVANCE(6)
       TakeInboxItem(1, 1); FIRE("MAIL_INBOX_UPDATE")`);
  assert.deepEqual(trade(), []);
  run(`ADVANCE(6)
       TakeInboxItem(1, 1); SERVER_TAKE_ITEM(1, 1)`);
  assert.deepEqual(trade(), ["Returned 2589 20"]);
});

test("B1: a return waiting for its mail is dropped when the mailbox closes or after a few seconds", () => {
  const { run, trade } = vm();
  run(`INBOX[1] = ${expired("Linen Cloth", 2589, 20)}
       TakeInboxItem(1, 1); FIRE("MAIL_CLOSED"); SERVER_TAKE_ITEM(1, 1)
       INBOX[1] = ${expired("Light Leather", 2318, 5)}
       TakeInboxItem(1, 1); ADVANCE(10); SERVER_TAKE_ITEM(1, 1)`);
  assert.deepEqual(trade(), []);
});

test("B1: another mail leaving doesn't count a waiting click", () => {
  const { run, trade } = vm();
  run(`INBOX[1] = { sender = "Bob", subject = "hi", money = 500 }
       INBOX[2] = ${expired("Linen Cloth", 2589, 20)}
       TakeInboxItem(2, 1)          -- bags full, nothing moves
       TakeInboxMoney(1); SERVER_TAKE_MONEY(1)`);
  assert.deepEqual(trade(), []);
});
