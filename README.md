# Loot Ledger

A gold ledger, pickpocket and gathering tracker, and auction house advisor for **WoW: Forever**, with auction house prices that update automatically every hour.

- **Gold log:** every copper in and out, labelled (mob loot, pickpocket, vendor, quests, repairs, AH sales and fees, mail, flights…). View it by session, today, 7 days, 30 days or all time.
- **Gathering:** pickpocket, skinning, mining and herbalism: how many, what dropped, what it's worth at AH prices, gold per hour.
- **Inventory advice:** everything you own on all characters (bags, bank, mail), each marked **Sell now / List / Hold / Vendor**.
- **Market view:** Alt+click any item for its price chart (30 days / 12 weeks / 12 months), trend, and weekly pattern, e.g. *cheapest Tuesday, most expensive Saturday: buy Tuesday, sell Saturday*. Built for a young economy: "normal" means the last few days, and patterns are measured against the trend and only shown when they're real.
- **Vendor guard:** sold something to a vendor that's worth more on the AH? A popup offers to buy it back.

Region: **EU** (US planned). Rule set: **Normal**.

## Install

Loot Ledger is two folders that go into `World of Warcraft\_forever_\Interface\AddOns\`:

| Folder | What it is |
|---|---|
| `LootLedger` | the addon |
| `LootLedger_Prices` | auction house prices, refreshed every hour |

Both are in the zip of every [release](../../releases/latest).

**Keep it updated automatically (recommended):** use an addon manager that can follow a GitHub repository (for example WowUp: *Get Addons → Install from URL* → paste this repository's URL). It picks up the hourly releases. Make sure the manager points at your `_forever_` folder.

**Or on Windows without an addon manager:** download [`scripts/update.ps1`](scripts/update.ps1) and run it before playing:

```powershell
powershell -ExecutionPolicy Bypass -File update.ps1
```

It finds your WoW: Forever folder, downloads the latest release and installs both folders.

**Or by hand:** download the zip from the [latest release](../../releases/latest) and unzip it into your AddOns folder.

Prices load when the game starts (or on `/reload`).

## Use

| Command | |
|---|---|
| `/ll` | open the window (Overview, Gold log, Inventory, Gathering, Market) |
| Alt+click an item | its price history and advice |
| `/ll sell` | what to sell on the AH right now |
| `/ll house` | which auction house your prices come from |
| `/ll house auto` | detect it automatically (default) |
| `/ll box` | show/hide the small "today" box |

**Your auction house is detected automatically** the first time you open the AH on a character (a few quick searches, about 10 seconds). Until then Loot Ledger uses the biggest house of your faction.

## How prices work

WoW addons can't go online, so prices are shipped as an addon:

1. Every hour a GitHub Action reads every WoW: Forever auction house of the region from Blizzard's API (`dynamic-forever-eu`, `/data/wow/ruleset/{id}/auctions/{house}` and `/commodities`).
2. Per item and house it computes the market price (cheapest 15% of units), lowest price, quantity listed, and history: daily for 120 days, monthly beyond that.
3. It analyses the history (recent baseline, trend per day, weekday pattern with a significance test) and publishes a release with fresh `LootLedger_Prices`.

The feed is in [`poller/`](poller); `node --test poller/analysis.test.mjs poller/history.test.mjs` runs its tests.

## Privacy

Loot Ledger sends nothing anywhere. Your gold log and inventory stay in WoW's saved variables on your PC.

## Credits

- Auction data: Blizzard Entertainment's World of Warcraft API.
- Region-wide sales per day: [Saddlebag Exchange](https://saddlebagexchange.com).

Loot Ledger is a fan project, not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft is a trademark of Blizzard Entertainment.

## License

[MIT](LICENSE)
