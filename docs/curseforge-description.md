# Cutpurse Ledger

**Know where your gold comes from, what your stuff is worth, and what to sell, for WoW: Forever.** Auction house prices for every EU Forever auction house come with it and update on their own.

## What it does

- **Gold log:** every copper in and out, labelled by where it came from: mob loot, pickpocketing, vendor, quests, repairs, AH sales, deposits and purchases, mail, flights and more. See it for this session, today, 7 days, 30 days or all time.
- **Net worth:** gold on all your characters plus what their bags, bank and mail would sell for right now. Each character is priced at its own auction house. Type `/cl worth` or check the Home tab.
- **What to sell:** everything you own on all characters, marked **Sell now**, **List**, **Hold** or **Vendor**, with the reason. It tells a dip (wait) from a crash where buyers have gone (sell).
- **Gathering:** pickpocketing, skinning, mining and herbalism: how much, what dropped, gold per hour, and what it's worth at the price *you* actually sell for once you have sales.
- **Market view:** Alt+click any item for its price chart (30 days, 12 weeks, 12 months), its trend, and its weekly pattern, for example *cheapest on Tuesday, most expensive on Saturday*.
- **Trending:** what's selling fast, getting pricier, drying up or cooling off on your auction house, based on what was really bought hour by hour. Needs a few days of data on a new house.
- **AH scan:** at the auction house, click **Cutpurse scan** (or type `/cl scan`) for prices as listed right now.
- **Quest items:** with Questie installed, items that quests ask for are tagged, and Trending can show only those.
- **Vendor guard:** sold something to a vendor that's worth more on the AH? It offers to buy it back.

## Prices

Prices are a separate addon, **Cutpurse Ledger Prices (EU)**. The CurseForge app installs it for you.

- Turn on **auto-update** for both addons in the CurseForge app to keep prices fresh. New prices come out every 6 hours.
- Prices load when you log in or type `/reload`.
- Your auction house is detected the first time you open the AH on each character, which takes about 10 seconds. Until then the addon uses the biggest house of your faction.

Want prices every hour instead? The GitHub page has hourly releases and a small Windows updater.

## Commands

| | |
|---|---|
| `/cl` | open the window |
| Alt+click an item | its price history and advice |
| `/cl sell` | what to sell on the AH right now |
| `/cl trending` | what's selling fast |
| `/cl worth` | net worth, all characters |
| `/cl scan` | scan the AH you're at |
| `/cl house` | which auction house your prices come from |
| `/cl box` | show or hide the small "today" box |

`/cutpurse` works too.

## Good to know

- **EU only** for now (Normal rule set). US is planned.
- **Your data stays on your PC.** The addon sends nothing anywhere: your gold log and inventory are in WoW's saved variables.
- Source code, hourly releases and issues: https://github.com/villelejonet-source/CutpurseLedger

Auction data from Blizzard Entertainment's World of Warcraft API. Region-wide sales per day from Saddlebag Exchange. Cutpurse Ledger is a fan project, not affiliated with or endorsed by Blizzard Entertainment.
